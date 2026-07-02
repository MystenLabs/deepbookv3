// ⛔ DO NOT launch without EXPLICIT user confirmation (see the SKILL.md gate) — a run is bounded by
//    construction (≤ maxRounds×lenses + verifyCap×panel agents; a few million tokens at defaults) but still
//    expensive. Present the run plan + cost and wait for an explicit "yes" first.
// Predict smart-contract audit orchestrator — MAXIMAL MODE (budget-aware loop-until-dry).
//
// Findings are SAMPLED, not enumerated: re-running a lens surfaces different issues each pass. So this runs
// each lens across a few ROUNDS, unions new findings (deduped ACROSS lenses), and stops at the round cap or
// when every lens has CONVERGED. Lenses retire PER-LANE: a lens that produces no new finding for dryRounds
// consecutive rounds drops out, so later rounds only re-run lenses still surfacing issues (the sequence trim).
// Launch from the MAIN LOOP after ground-truth; the main loop synthesizes the report.
// Cost is BOUNDED BY CONSTRUCTION (see the agent-count note below) — deepen a run with maxRounds/verifyCap,
// not by removing the caps.
//
// args = {
//   groundTruth: string, scope: string,
//   lenses?:     string[],  // subset of lens keys (default: all 10)
//   profile?:    'security'|'cleanup', // named lens preset when `lenses` is absent: security drops the
//                            // cleanup-tier lenses (surface-area, architecture); cleanup keeps ONLY them
//   depth?:      'mini'|'low'|'standard'|'max', // preset for rounds/verifyCap/effort (see DEPTH below)
//   files?:      string[],  // DELTA SCOPE: changed files — lenses concentrate on them + direct callers/callees
//   priorAdjudications?: [  // cross-run memory: adjudicated findings from a PREVIOUS run's findings.json.
//     { title, location, status: 'refuted'|'settled'|'confirmed', note? }
//   ],                      // Re-found REFUTED/SETTLED matches are suppressed (not re-verified) and returned
//                           // under `prior_rediscovered`; CONFIRMED priors are NOT suppressed (a still-open
//                           // bug keeps flowing into kept[]). Pass ONLY entries whose cited files are
//                           // UNCHANGED since the adjudicating run (filter with git diff --name-only
//                           // <sha>..HEAD — see SKILL.md); a stale suppression can hide a bug that became real.
//   maxFindings?: number,   // cap NEW findings per lens per round (default: 12)
//   dryRounds?:  number,    // stop after this many consecutive no-new-finding rounds (default: 2)
//   maxRounds?:  number,    // hard round cap (default: 3)
//   verifyCap?:  number,    // max Medium+ candidates sent to the verify panel (default: 60)
// }
// COST IS BOUNDED BY CONSTRUCTION: total agents <= maxRounds*lenses (find) + verifyCap*3 (verify) + 1, so a
// run CANNOT hit the 1000-agent cap even when no token budget binds. The `budget` global (a "+NNNm" turn
// directive) is only an ADDITIONAL early-stop — it often does NOT propagate into a background workflow
// (budget.total comes through null), so never rely on it as the bound. Verify is SEVERITY-GATED + CROSS-MODEL:
// Info/Low + cleanup-only findings are reported RAW (unverified, no subagent); Medium gets one codex verifier;
// High/Critical get a MIXED panel (codex refute + codex repro + Claude settled) so every escalated finding
// clears two different models — a finder-model bias check. Needs the codex CLI; if codex is unavailable the
// codex verdicts return null and aggregate() degrades to the Claude verdict(s) (a lone Medium -> 'uncertain').
//
// Subagents are READ-ONLY on source; no sui build/test or localnet (watchdog) — Python sims only.

export const meta = {
  name: 'predict-audit-orchestrator',
  description: 'Maximal multi-lens audit of Predict (+ siblings): loop-until-dry find -> diverse adversarial verify -> structured findings',
  phases: [
    { title: 'Find', detail: 'loop-until-dry with per-lane retirement: each lens re-samples until it converges, then drops out; deduped ACROSS lenses' },
    { title: 'Verify', detail: 'severity-gated + CROSS-MODEL: High/Critical = mixed panel (codex refute+repro, Claude settled), Medium = 1 codex verifier, Info/Low/cleanup left unverified' },
    { title: 'Promote', detail: 'elevate high-signal observations buried in coverage into findings' },
  ],
}

const SKILL = '.claude/skills/predict-audit'
let A = args
if (typeof A === 'string') { try { A = JSON.parse(A) } catch (e) { A = {} } }
if (!A || typeof A !== 'object') A = {}
const groundTruth = A.groundTruth || '(no ground-truth provided — note this in coverage)'
const scope = A.scope || 'full protocol at current HEAD'
// DEPTH preset — ORTHOGONAL to breadth/scope: it tunes how hard each lens digs (rounds / verify / findings),
// NOT how many lenses run. So depth:'low' is still a FULL-breadth audit (all lenses) — just a single pass per
// lens. Precedence: an explicit cap arg wins over the depth preset, which wins over the hardcoded default.
// Tiers: mini = cleanup-triage pass (1 round, NO verify subagents — everything reported raw, the operator is
// the verifier; finder effort medium; pair with profile:'cleanup'); low = quick full-coverage pass;
// standard = the bounded default; max = reserve for high-budget runs.
const DEPTH = { mini: { maxRounds: 1, verifyCap: 0, effort: 'medium' }, low: { maxRounds: 1, verifyCap: 30 }, standard: {}, max: { maxRounds: 5, dryRounds: 3, verifyCap: 100, maxFindings: 16 } }
const depthName = DEPTH[A.depth] ? A.depth : 'standard'
const D = DEPTH[depthName]
const maxFindings = A.maxFindings || D.maxFindings || 12
const DRY_TARGET = A.dryRounds || D.dryRounds || 2
const MAX_ROUNDS = A.maxRounds || D.maxRounds || 3
// typeof-check, not ||: mini's verifyCap 0 is falsy and must not fall through to the default.
const VERIFY_CAP = [A.verifyCap, D.verifyCap, 60].find(v => typeof v === 'number')
const FIND_EFFORT = D.effort || 'max'
const RESERVE = (budget && budget.total) ? Math.max(5_000_000, Math.floor(budget.total * 0.3)) : 5_000_000 // reserve ~30% of the budget for verify + promote + synthesis
// One definition of the committed settled-decision sources, interpolated into every prompt that cites them
// (they were previously restated per-prompt and drifted on tracker moves).
const SETTLED_SOURCES = 'AGENTS.md "Settled design decisions" (incl. the D-id ledger), packages/predict/predeploy/rounding-policy.md, and packages/predict/predeploy/open-items.md'
// DELTA SCOPE: when the run targets a change set, lenses concentrate on these files + their blast radius.
const FILES = Array.isArray(A.files) && A.files.length ? A.files : null
// Cross-run memory: adjudications from a previous run. Keyed with the same fkey used for in-run dedup, so a
// re-found match is suppressed BEFORE it burns a verify panel; suppressed items return under prior_rediscovered.
const PRIOR = Array.isArray(A.priorAdjudications) ? A.priorAdjudications : []

const ALL_LANES = [
  { key: 'invariants', file: '01-invariants.md' },
  { key: 'adversarial', file: '02-adversarial-audit.md' },
  { key: 'oracle-numerical', file: '03-oracle-pricing-numerical.md' },
  { key: 'access-control', file: '04-access-control.md' },
  { key: 'surface-area', file: '05-surface-area.md' },
  { key: 'assertions', file: '06-assertions.md' },
  { key: 'lifecycle', file: '07-lifecycle.md' },
  { key: 'cross-package', file: '08-cross-package-trust.md' },
  { key: 'econ-sim', file: '09-economic-simulation.md' },
  { key: 'architecture', file: '10-architecture-maintainability.md' },
]
const want = Array.isArray(A.lenses) ? A.lenses : null
// profile:'security' = full bug-hunt breadth minus the cleanup-tier lenses (their findings are mostly the
// unverified Info tail). profile:'cleanup' = the inverse — ONLY the cleanup-tier lenses, for the mini
// triage pass (pair with depth:'mini'). An explicit `lenses` arg always wins over a profile.
const PROFILE_DROP = { security: ['surface-area', 'architecture'] }
const PROFILE_KEEP = { cleanup: ['surface-area', 'assertions', 'architecture'] }
const profileDrop = !want && PROFILE_DROP[A.profile] ? PROFILE_DROP[A.profile] : null
const profileKeep = !want && PROFILE_KEEP[A.profile] ? PROFILE_KEEP[A.profile] : null
const LANES = want && want.length ? ALL_LANES.filter(l => want.indexOf(l.key) >= 0)
  : profileKeep ? ALL_LANES.filter(l => profileKeep.indexOf(l.key) >= 0)
  : profileDrop ? ALL_LANES.filter(l => profileDrop.indexOf(l.key) < 0) : ALL_LANES
const unknownLenses = want ? want.filter(k => !ALL_LANES.some(l => l.key === k)) : []
function budgetLeft() { return budget && typeof budget.remaining === 'function' ? budget.remaining() : Infinity }
log(`audit config — scope: "${scope}" | depth: ${depthName}${(profileDrop || profileKeep) ? ` | profile: ${A.profile}` : ''} | lenses: ${want ? want.join(',') : (profileDrop || profileKeep) ? `${LANES.length} (${A.profile} profile)` : `ALL ${ALL_LANES.length}`} | maxFindings/lens/round: ${maxFindings} | dryRounds: ${DRY_TARGET} | maxRounds: ${MAX_ROUNDS} | verifyCap: ${VERIFY_CAP} | budget: ${budgetLeft() === Infinity ? 'unset (dry/round-bounded)' : Math.round(budgetLeft() / 1e6) + 'M'}`
  + (FILES ? ` | DELTA files: ${FILES.length}` : '')
  + (PRIOR.length ? ` | prior adjudications: ${PRIOR.length}` : '')
  + (unknownLenses.length ? ` | ⚠ UNKNOWN LENS KEYS IGNORED: ${unknownLenses.join(',')} (valid: ${ALL_LANES.map(l => l.key).join(',')})` : '')
  + ` | groundTruth: ${String(groundTruth).slice(0, 80)}`)
if (!A.groundTruth || String(A.groundTruth).length < 40) {
  log('⚠ groundTruth is missing or suspiciously short — confirm Step 1 (build/test in the MAIN loop) actually ran; a false "all green" poisons every lens')
}
if (want && !LANES.length) {
  log('⚠ lens filter matched nothing — aborting (check the lens keys)')
  return { error: 'no_lenses_matched', requested: want, valid_keys: ALL_LANES.map(l => l.key) }
}

const FINDINGS_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    lane: { type: 'string' },
    coverage: { type: 'string', description: 'what you examined and what you explicitly did NOT' },
    top3: { type: 'array', items: { type: 'string' } },
    findings: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        properties: {
          severity: { type: 'string', enum: ['Critical', 'High', 'Medium', 'Low', 'Info'] },
          title: { type: 'string' },
          location: { type: 'string', description: 'file.move:line(s)' },
          claim: { type: 'string' },
          scenario: { type: 'string' },
          impact: { type: 'string', enum: ['fund-loss', 'liveness-brick', 'griefing-dos', 'correctness', 'cleanup-only'] },
          confidence: { type: 'string', enum: ['high', 'medium', 'low'] },
          recommendation: { type: 'string' },
          settled_ref: { type: 'string', description: 'D-id if it matches a settled decision, else ""' },
          evidence: { type: 'string', description: 'test/sim/grep/git fact backing the claim (required for High/Critical)' },
        },
        required: ['severity', 'title', 'location', 'claim', 'scenario', 'impact', 'confidence', 'recommendation', 'settled_ref', 'evidence'],
      },
    },
  },
  required: ['lane', 'coverage', 'top3', 'findings'],
}

const VERDICT_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    verdict: { type: 'string', enum: ['confirmed', 'refuted', 'settled', 'uncertain'] },
    adjusted_severity: { type: 'string', enum: ['Critical', 'High', 'Medium', 'Low', 'Info'] },
    reasoning: { type: 'string' },
    evidence: { type: 'string', description: 'file:line, git, or sim fact supporting the verdict' },
  },
  required: ['verdict', 'adjusted_severity', 'reasoning', 'evidence'],
}

const priorBlock = PRIOR.length
  ? `\nADJUDICATED IN PREVIOUS RUNS — these were already confirmed/refuted/settled by a prior audit whose cited code is unchanged. Do NOT re-report them:\n${PRIOR.map(p => `- [${p.status}] ${p.title} @ ${p.location}${p.note ? ` — ${p.note}` : ''}`).join('\n')}\n`
  : ''
const focusBlock = FILES
  ? `\nDELTA SCOPE — this audit targets a change set. CONCENTRATE on these files and their direct callers/callees (grep both directions); treat the rest of the packages as context, and report findings wherever the change set's blast radius reaches:\n${FILES.map(f => `- ${f}`).join('\n')}\n`
  : ''

function finderPrompt(lane, round, known) {
  return `You are the "${lane.key}" lens of a deep, prior-aware smart-contract audit of DeepBook Predict and its split-out sibling packages (propbook, block_scholes_oracle, account). This is a MAXIMAL last-line-of-defense audit — be exhaustive.

FIRST read these two files and follow them exactly:
  1. ${SKILL}/primer.md          (protocol, current module map, scope, prior-awareness, empirical toolbox, report format)
  2. ${SKILL}/lenses/${lane.file}  (your lens: deliverables, focus areas, empirical mandate, output)
You may also cite ${SKILL}/references/*.md.

SCOPE: ${scope}
${focusBlock}GROUND TRUTH (do NOT re-run sui build/test or localnet; the watchdog kills subagents): ${groundTruth}

THIS IS FIND ROUND ${round} OF A LOOP-UNTIL-DRY AUDIT. The following candidates were ALREADY found by earlier rounds — do NOT re-report them. Hunt DIFFERENT, deeper, rarer issues, and explore functions/branches/edges not yet covered. Return ONLY findings not already in this list:
${known || '(none yet — first round)'}
${priorBlock}
DISCIPLINE (binding):
- Read-only on packages/*/sources/**. Verify every claim against the actual function body + call sites (grep), not its name.
- Be prior-aware: a candidate matching a settled decision or committed policy (${SETTLED_SOURCES}) gets settled_ref=<D-id-or-policy-ref> and severity Info.
- You MAY write and run Python sims in the scratchpad. You may NOT run sui build/test or localnet (hand those to the main loop as a recipe in evidence).
- Quality over noise, but in maximal mode err toward surfacing a code-grounded candidate (verify will refute the wrong ones). Cap at your ${maxFindings} highest-value NEW findings this round. High/Critical MUST have concrete evidence.

Emit ONLY via the StructuredOutput schema. settled_ref="" and evidence="" only when truly empty.`
}

function isHigh(sev) { return sev === 'Critical' || sev === 'High' }
const SEVRANK = { critical: 5, high: 4, medium: 3, low: 2, info: 1 }
function sevOf(s) { return SEVRANK[(s || '').toLowerCase()] || 0 }
// Verify is worth a subagent only for Medium+ findings that aren't pure cleanup. Info/Low + cleanup-only
// findings are reported RAW (unverified) — this is the gate that bounds the agent count (and was the cost
// blow-up: ~575 candidates x 3 verifiers hit the 1000-agent cap).
function shouldVerify(f) { return f.impact !== 'cleanup-only' && sevOf(f.severity) >= SEVRANK.medium }

// Verify panel is CROSS-MODEL for bias reduction: the refute + repro lenses run on codex (a DIFFERENT model
// than the Claude finder — scoped adversarial code checks are codex's strength and catch finder-model blind
// spots), while the settled-decision lens stays on Claude (it leans on Claude's familiarity with the design
// journal). agentType:null => the default Claude subagent. If codex is unavailable these agents return null
// and aggregate() falls back to whatever verdicts returned. (Spike: codex emits schema-valid VERDICT JSON and
// re-derives findings from its own git/grep evidence — see the codex-verify spike that validated this path.)
const CODEX = 'codex:codex-rescue'
const LENSES = [
  { tag: 'refute', agentType: CODEX, build: () => 'ADVERSARIAL LENS = REFUTE-BY-CORRECTNESS. Try to prove this finding FALSE from the actual code. Read the cited lines, grep all call sites, check whether the precondition can hold. If you cannot construct a concrete code-grounded triggering path, verdict "refuted". When the claim is an empirical/economic break, attempt a quick Python check. Cite file:line / sim evidence.' },
  { tag: 'settled', agentType: null, build: () => `ADVERSARIAL LENS = SETTLED-DECISION CHECK. Check ${SETTLED_SOURCES}. Is this an accepted/rejected design decision, committed policy, or already-tracked open item? If yes, verdict "settled" with the D-id or committed-doc reference in evidence. Otherwise pass through.` },
  { tag: 'repro', agentType: CODEX, build: () => 'ADVERSARIAL LENS = REPRODUCE. Trace the exact PTB-ordered sequence through the real mint/redeem/liquidate/settle/flush code (and write a Python sim if the break is economic). Does it actually reach the cited line with all preconditions co-occurring? If they cannot co-exist, verdict "refuted"; if it genuinely triggers, "confirmed". Cite the call chain / sim seed.' },
]

// Single-pass verifier for MEDIUM findings — does refute+settled+repro in one agent (High/Critical still get
// the full 3-lens LENSES panel above). Keeps Medium verified without paying 3 subagents each.
const COMBINED_VERIFY = { tag: 'verify', agentType: CODEX, build: () => `ADVERSARIAL VERIFY (single pass — do ALL THREE): (1) REFUTE — try to prove the finding FALSE from the actual code; read the cited lines + grep call sites; if no concrete triggering path exists, verdict "refuted". (2) SETTLED — check ${SETTLED_SOURCES}. If it matches an accepted/rejected decision, committed policy, or already-tracked open item, verdict "settled" with the D-id or committed-doc reference in evidence. (3) REPRODUCE — trace the PTB-ordered path through the real mint/redeem/liquidate/settle/flush code (Python sim if economic); if preconditions genuinely co-occur, "confirmed", else "refuted". Cite file:line / D-id / committed-doc ref / sim.` }

const VERIFY_PREAMBLE = `You are an ADVERSARIAL VERIFIER in a Predict smart-contract audit. A lens proposed the finding below; TEST it against the actual code + git + the settled-decision priors, do NOT agree by default. Read ${SKILL}/primer.md for the module map + prior-awareness. The .claude/predict-review/ files are STALE — trust the current tree. Do NOT run sui build/test or localnet; reason from source, grep, git, and Python. STAY SCOPED: read the cited files + their direct callers/feeds, not the whole repo; keep it tight (a quick scoped check, not an exploration). Verdicts: confirmed (real, reproducible) / refuted (wrong, preconditions can't co-occur, or already mitigated) / settled (matches a D-id, cite it) / uncertain. Provide file:line / git / sim evidence. adjusted_severity = your independent severity (Info if refuted/settled). OUTPUT: emit ONLY the structured verdict object (no markdown fences, no prose around it).`

function verifyPrompt(f, laneKey, lens) {
  return `${VERIFY_PREAMBLE}\n\nFINDING (lane "${laneKey}"):\n${JSON.stringify(f, null, 2)}\n\n${lens.build()}`
}

function aggregate(f, laneKey, verdicts) {
  const vs = verdicts.filter(Boolean)
  const settled = vs.find(v => v.verdict === 'settled')
  const refuted = vs.filter(v => v.verdict === 'refuted').length
  const confirmed = vs.filter(v => v.verdict === 'confirmed').length
  // A panel with ZERO live verdicts (all agents errored even after the retry) must be visibly distinct from
  // a genuinely contested finding: 'unverified-panel', never a quiet 'uncertain'.
  let status = 'uncertain'
  if (!vs.length) status = 'unverified-panel'
  else if (settled) status = 'settled'
  else if (refuted > confirmed) status = 'refuted'
  else if (confirmed > 0) status = 'confirmed'
  // severity = MAX of the finder's and the CONFIRMING verifiers' adjusted_severity — the panel exists to
  // re-rank, so a fund-loss bug the finder under-rated must not sink. Upgrades only; never downgrade a real one.
  const severity = [f.severity, ...vs.filter(v => v.verdict === 'confirmed').map(v => v.adjusted_severity)]
    .filter(Boolean).sort((a, b) => (SEVRANK[(b || '').toLowerCase()] || 0) - (SEVRANK[(a || '').toLowerCase()] || 0))[0] || f.severity
  // panel_severity = the panel's own independent ranking (max confirming adjusted_severity). The `severity`
  // field is upgrades-only by design; this records what the panel actually thought so curation can see a
  // finder High that was only confirmed as a Medium.
  const panelSeverity = vs.filter(v => v.verdict === 'confirmed').map(v => v.adjusted_severity)
    .filter(Boolean).sort((a, b) => (SEVRANK[(b || '').toLowerCase()] || 0) - (SEVRANK[(a || '').toLowerCase()] || 0))[0] || ''
  return {
    lane: laneKey, status,
    severity, title: f.title, location: f.location, claim: f.claim,
    scenario: f.scenario, impact: f.impact, confidence: f.confidence,
    recommendation: f.recommendation, settled_ref: settled ? (settled.evidence || f.settled_ref) : f.settled_ref,
    evidence: f.evidence,
    panel_severity: panelSeverity,
    // High/Critical are supposed to clear a multi-verdict panel; flag when attrition left fewer than 2.
    panel_degraded: isHigh(f.severity) && vs.length < 2,
    verifier_verdicts: vs.map(v => `${v.verdict}/${v.adjusted_severity}: ${v.reasoning} [${v.evidence}]`),
  }
}

// ---------- FIND: loop-until-dry with PER-LANE retirement (the sequence trim) ----------
phase('Find')
// Dedup key strips line numbers + normalizes the title, so a re-worded or line-shifted SAME finding still
// matches across rounds — otherwise "fresh" never goes to 0, the loop never dries, and it burns the whole
// budget on rewording churn instead of converging.
function nloc(s) { return (s || '').toLowerCase().replace(/:[0-9][0-9,\- ]*/g, '').replace(/[^a-z0-9/._;]/g, '') }
function ntitle(s) { return (s || '').toLowerCase().replace(/[^a-z0-9]+/g, '').slice(0, 50) }
// Dedup key is location+title with NO lane, so the SAME issue surfaced by N lenses collapses to ONE candidate
// (it used to include the lane, so e.g. one liveness bug found by 5 lenses became 5 candidates -> 15 verify
// agents). The lens that found it is kept as metadata in `lanes[]`.
function fkey(f) { return `${nloc(f.location).slice(0, 80)}|${ntitle(f.title)}` }
const byKey = new Map()
const candidates = []
const coverageByLane = {}
// Cross-run suppression: a found candidate matching a prior REFUTED/SETTLED adjudication is recorded (once)
// and NOT verified again (the "don't re-litigate" cases). A prior CONFIRMED finding is deliberately NOT
// suppressed — a still-open bug must keep flowing into this run's actionable kept[] and get cheaply
// re-verified (cheap insurance it wasn't silently fixed), not vanish because a past run saw it. The prior
// list is pre-filtered by the operator to unchanged-code entries (see the args comment).
const priorByKey = new Map()
PRIOR.filter(p => p.status === 'refuted' || p.status === 'settled')
  .forEach(p => { const k = fkey(p); if (!priorByKey.has(k)) priorByKey.set(k, p) })
const rediscoveredKeys = new Set()
const priorRediscovered = []
// PER-LANE retirement (sequence trim): each lens carries its own consecutive-dry counter. A lens that
// produces no NEW finding for DRY_TARGET rounds retires and is not re-run, so later rounds spend ONLY on
// lenses still surfacing issues — instead of re-running all of them every round until a single GLOBAL dry
// counter trips. dryRounds:1 => re-run only lenses that were fresh last round; maxRounds:1 => single pass.
// A lens whose agent ERRORED (null result) is NOT counted dry — it stays active and retries next round.
const dryByLane = {}
LANES.forEach(l => { dryByLane[l.key] = 0 })
let round = 0
while (round < MAX_ROUNDS && budgetLeft() > RESERVE) {
  const activeLanes = LANES.filter(l => dryByLane[l.key] < DRY_TARGET)
  if (!activeLanes.length) break   // every lens has converged (retired)
  round++
  // Per-lane known list (not the whole cross-lane union) so the prompt doesn't grow super-linearly and
  // trip StructuredOutput truncation on big runs. A merged candidate is suppressed for EVERY lane that found it.
  const knownByLane = {}
  candidates.forEach(f => (f.lanes || [f.lane]).forEach(ln => { (knownByLane[ln] = knownByLane[ln] || []).push(`- [${f.severity}] ${f.title} @ ${f.location}`) }))
  const roundRes = await parallel(activeLanes.map(lane => () => agent(finderPrompt(lane, round, (knownByLane[lane.key] || []).join('\n')),
    { schema: FINDINGS_SCHEMA, effort: FIND_EFFORT, phase: 'Find', label: `find:${lane.key}:r${round}` })))
  const freshByLane = {}
  // Index by the lane we DISPATCHED (activeLanes[i]), not the agent-returned r.lane: parallel() preserves
  // order, and the dispatched key is the stable identity (some lenses fill `lane` with their file name).
  roundRes.forEach((r, i) => {
    if (!r) return
    const laneKey = activeLanes[i].key
    coverageByLane[laneKey] = { coverage: r.coverage, top3: r.top3 || [] }
    ;(r.findings || []).forEach(f => {
      const k = fkey(f)
      const prior = priorByKey.get(k)
      if (prior) {  // already adjudicated by a previous run over unchanged code — suppress, don't re-verify
        if (!rediscoveredKeys.has(k)) { rediscoveredKeys.add(k); priorRediscovered.push({ title: f.title, location: f.location, lane: laneKey, severity: f.severity, prior_status: prior.status, prior_note: prior.note || '' }) }
        return
      }
      const ex = byKey.get(k)
      if (!ex) { const ff = { ...f, lane: laneKey, lanes: [laneKey] }; byKey.set(k, ff); candidates.push(ff); freshByLane[laneKey] = (freshByLane[laneKey] || 0) + 1 }
      else {  // same issue from another lens/round — merge: record the lens, keep the worst severity + real impact
        if (ex.lanes.indexOf(laneKey) < 0) ex.lanes.push(laneKey)
        if (sevOf(f.severity) > sevOf(ex.severity)) ex.severity = f.severity
        if (ex.impact === 'cleanup-only' && f.impact !== 'cleanup-only') ex.impact = f.impact
      }
    })
  })
  // Advance each active lens's dry counter (retire at DRY_TARGET); reset it for productive ones. A lens that
  // ERRORED (no result) is skipped — neither advanced nor reset — so it retries next round without retiring.
  activeLanes.forEach((l, i) => { if (!roundRes[i]) return; if ((freshByLane[l.key] || 0) === 0) dryByLane[l.key]++; else dryByLane[l.key] = 0 })
  const freshTotal = Object.values(freshByLane).reduce((a, b) => a + b, 0)
  const retired = LANES.filter(l => dryByLane[l.key] >= DRY_TARGET).length
  log(`Find round ${round}: ran ${activeLanes.length} lens(es), +${freshTotal} new (total ${candidates.length}) | ${retired}/${LANES.length} retired | budget ${budgetLeft() === Infinity ? '∞' : Math.round(budgetLeft() / 1e6) + 'M'} left`)
}
const retiredFinal = LANES.filter(l => dryByLane[l.key] >= DRY_TARGET).length
log(`Find converged after ${round} round(s): ${candidates.length} unique candidates (${retiredFinal}/${LANES.length} lenses retired)`
  + (priorRediscovered.length ? ` | ${priorRediscovered.length} prior-adjudicated rediscoveries suppressed` : ''))

// ---------- VERIFY: SEVERITY-GATED (bounds the agent count) ----------
// Only Medium+ non-cleanup findings are verified; Info/Low + cleanup-only are reported RAW (unverified).
// High/Critical get the full refute/settled/repro panel; Medium gets one combined verifier. The verify set
// is capped at VERIFY_CAP (by severity) so total agents stay well under the 1000-agent cap even with no budget.
phase('Verify')
const verifyAll = candidates.filter(shouldVerify).sort((a, b) => sevOf(b.severity) - sevOf(a.severity))
const toVerify = verifyAll.slice(0, VERIFY_CAP)
const verifyOverflow = verifyAll.slice(VERIFY_CAP)   // Medium+ beyond the cap -> reported unverified (logged, never silently dropped)
const unverified = candidates.filter(f => !shouldVerify(f)).concat(verifyOverflow)
if (verifyOverflow.length) log(`Verify cap ${VERIFY_CAP} hit: ${verifyOverflow.length} Medium+ candidate(s) reported UNVERIFIED — raise verifyCap to panel them all`)
// A null verdict (codex absent, StructuredOutput flake) is retried ONCE on the default Claude agent before
// being accepted as dead — infrastructure failure must not quietly demote a finding to 'uncertain'.
async function verdictAgent(prompt, lens, label) {
  const base = { schema: VERDICT_SCHEMA, effort: 'high', phase: 'Verify' }
  let v = await agent(prompt, { ...base, label, ...(lens.agentType ? { agentType: lens.agentType } : {}) })
  if (!v) v = await agent(prompt, { ...base, label: `${label}:retry` })
  return v
}
const verified = await parallel(toVerify.map((f, fi) => async () => {
  const panel = isHigh(f.severity) ? LENSES : [COMBINED_VERIFY]   // cross-model panel for High/Critical, 1 codex verifier for Medium
  const verdicts = await parallel(panel.map(lens => () =>
    verdictAgent(verifyPrompt(f, f.lane, lens), lens, `verify:${f.lane}:${fi}:${lens.tag}`)))
  return aggregate(f, f.lane, verdicts)
}))

const all = verified.filter(Boolean)
// kept = confirmed first, then uncertain, then panel-dead — three populations of very different reliability;
// the counts are split in the summary so curation never has to remember that.
const KEEPRANK = { confirmed: 0, uncertain: 1, 'unverified-panel': 2 }
const kept = all.filter(f => KEEPRANK[f.status] !== undefined)
kept.sort((a, b) => (KEEPRANK[a.status] - KEEPRANK[b.status]) || (sevOf(b.severity) - sevOf(a.severity)))
const settledOut = all.filter(f => f.status === 'settled')
const refutedOut = all.filter(f => f.status === 'refuted')
const keptConfirmed = kept.filter(f => f.status === 'confirmed').length
const keptUncertain = kept.filter(f => f.status === 'uncertain').length
const panelDead = kept.filter(f => f.status === 'unverified-panel').length
const lanes = Object.keys(coverageByLane).map(k => ({ lane: k, coverage: coverageByLane[k].coverage, top3: coverageByLane[k].top3 }))
log(`Verify: verified ${all.length} (kept ${kept.length} = ${keptConfirmed} confirmed + ${keptUncertain} uncertain + ${panelDead} panel-dead | settled ${settledOut.length} | refuted ${refutedOut.length}) | unverified ${unverified.length} (Info/Low/cleanup, raw)`)

// ---------- PROMOTE: elevate high-signal observations buried in coverage ----------
phase('Promote')
const PROMOTE_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: { findings: { type: 'array', items: FINDINGS_SCHEMA.properties.findings.items } },
  required: ['findings'],
}
const coverageBlob = lanes.map(l => `[${l.lane}]\n  coverage: ${l.coverage}\n  top3: ${(l.top3 || []).join(' | ')}`).join('\n\n')
const keptTitles = kept.map(f => `${f.severity} (${f.lane}): ${f.title}`).join('\n') || '(none)'
const promoteRes = await agent(
  `You are the completeness/promotion critic for a Predict smart-contract audit. Read ${SKILL}/primer.md for the module map, prior-awareness, and report format.\n\n`
  + `Below are every lens's COVERAGE notes + top-3, and the findings ALREADY captured. Lenses sometimes state a real issue inside coverage/aside text (a "VERIFIED-SOUND" note that hides a caveat, a sharp observation about a dropped gate, a missing-coverage admission) without promoting it to a finding. Identify any HIGH-SIGNAL observation in the coverage that is NOT already represented in the findings list, confirm it against the actual code (grep/read), and emit it as a proper finding. Do NOT duplicate existing findings, do NOT invent issues ungrounded in the coverage, and tag anything matching a settled decision with its D-id (settled_ref). Do not run sui build/test or localnet.\n\n`
  + `ALREADY-CAPTURED FINDINGS:\n${keptTitles}\n\nCOVERAGE NOTES:\n${coverageBlob}`,
  { schema: PROMOTE_SCHEMA, effort: 'high', phase: 'Promote', label: 'promote:coverage-critic' })
const promoted = (promoteRes && promoteRes.findings) || []
if (promoted.length) log(`Promoted ${promoted.length} buried observation(s) from coverage into findings`)

return {
  summary: {
    lenses: lanes.length, rounds: round, candidates: candidates.length, verified: all.length,
    kept: kept.length,
    kept_confirmed: keptConfirmed,
    kept_uncertain: keptUncertain,
    kept_panel_dead: panelDead,
    settled: settledOut.length, refuted: refutedOut.length, unverified: unverified.length, promoted: promoted.length,
    prior_rediscovered: priorRediscovered.length,
  },
  kept, settled: settledOut, refuted: refutedOut, promoted,
  unverified: unverified.map(f => ({ ...f, status: 'unverified' })),
  // Informational: candidates suppressed because a previous run already adjudicated them (unchanged code).
  prior_rediscovered: priorRediscovered,
  coverage: lanes.map(l => ({ lane: l.lane, coverage: l.coverage, top3: l.top3 })),
}
