// ⛔ DO NOT launch without EXPLICIT user confirmation (see the SKILL.md gate) — a full run is hundreds of
//    subagents / up to ~100M tokens. Present the run plan + cost and wait for an explicit "yes" first.
// Predict smart-contract audit orchestrator — MAXIMAL MODE (budget-aware loop-until-dry).
//
// Findings are SAMPLED, not enumerated: re-running a lens surfaces different issues each pass. So this runs
// each lens across ROUNDS, unions new findings, and keeps going until K consecutive rounds add nothing new
// OR the token-budget floor is hit — converting sampling variance into near-enumeration AND auto-retrying
// flaky (StructuredOutput-failed) units (a failed unit is just an empty round that re-runs). Launch from the
// MAIN LOOP after ground-truth; the main loop synthesizes the report. Cost is intentionally high (last line
// of defense); control it with scope + the budget, not by cutting coverage.
//
// args = {
//   groundTruth: string, scope: string,
//   lenses?:     string[],  // subset of lens keys (default: all 10)
//   maxFindings?: number,   // cap NEW findings per lens per round (default: 12)
//   dryRounds?:  number,    // stop after this many consecutive no-new-finding rounds (default: 3)
//   maxRounds?:  number,    // hard round cap (default: 20)
// }
// The `budget` global (set by a "+NNNm" turn directive, e.g. +100m) gates the loop: it stops when
// budget.remaining() drops below a reserve. With no budget set, dryRounds/maxRounds bound it.
//
// Subagents are READ-ONLY on source; no sui build/test or localnet (watchdog) — Python sims only.

export const meta = {
  name: 'predict-audit-orchestrator',
  description: 'Maximal multi-lens audit of Predict (+ siblings): loop-until-dry find -> diverse adversarial verify -> structured findings',
  phases: [
    { title: 'Find', detail: 'loop-until-dry: 10 lenses re-sample across rounds until no new findings or budget floor' },
    { title: 'Verify', detail: 'diverse refute/settled/repro panel per unique candidate' },
    { title: 'Promote', detail: 'elevate high-signal observations buried in coverage into findings' },
  ],
}

const SKILL = '.claude/skills/predict-audit'
let A = args
if (typeof A === 'string') { try { A = JSON.parse(A) } catch (e) { A = {} } }
if (!A || typeof A !== 'object') A = {}
const groundTruth = A.groundTruth || '(no ground-truth provided — note this in coverage)'
const scope = A.scope || 'full protocol at current HEAD'
const maxFindings = A.maxFindings || 12
const DRY_TARGET = A.dryRounds || 3
const MAX_ROUNDS = A.maxRounds || 20
const RESERVE = (budget && budget.total) ? Math.max(5_000_000, Math.floor(budget.total * 0.3)) : 5_000_000 // reserve ~30% of the budget for verify + promote + synthesis

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
const LANES = want && want.length ? ALL_LANES.filter(l => want.indexOf(l.key) >= 0) : ALL_LANES
const unknownLenses = want ? want.filter(k => !ALL_LANES.some(l => l.key === k)) : []
function budgetLeft() { return budget && typeof budget.remaining === 'function' ? budget.remaining() : Infinity }
log(`audit config — scope: "${scope}" | lenses: ${want ? want.join(',') : `ALL ${ALL_LANES.length}`} | maxFindings/lens/round: ${maxFindings} | dryRounds: ${DRY_TARGET} | maxRounds: ${MAX_ROUNDS} | budget: ${budgetLeft() === Infinity ? 'unset (dry/round-bounded)' : Math.round(budgetLeft() / 1e6) + 'M'}`
  + (unknownLenses.length ? ` | ⚠ UNKNOWN LENS KEYS IGNORED: ${unknownLenses.join(',')} (valid: ${ALL_LANES.map(l => l.key).join(',')})` : '')
  + ` | groundTruth: ${String(groundTruth).slice(0, 80)}`)
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

function finderPrompt(lane, round, known) {
  return `You are the "${lane.key}" lens of a deep, prior-aware smart-contract audit of DeepBook Predict and its split-out sibling packages (propbook, block_scholes_oracle, account). This is a MAXIMAL last-line-of-defense audit — be exhaustive.

FIRST read these two files and follow them exactly:
  1. ${SKILL}/primer.md          (protocol, current module map, scope, prior-awareness, empirical toolbox, report format)
  2. ${SKILL}/lenses/${lane.file}  (your lens: deliverables, focus areas, empirical mandate, output)
You may also cite ${SKILL}/references/*.md.

SCOPE: ${scope}
GROUND TRUTH (do NOT re-run sui build/test or localnet; the watchdog kills subagents): ${groundTruth}

THIS IS FIND ROUND ${round} OF A LOOP-UNTIL-DRY AUDIT. The following candidates were ALREADY found by earlier rounds — do NOT re-report them. Hunt DIFFERENT, deeper, rarer issues, and explore functions/branches/edges not yet covered. Return ONLY findings not already in this list:
${known || '(none yet — first round)'}

DISCIPLINE (binding):
- Read-only on packages/*/sources/**. Verify every claim against the actual function body + call sites (grep), not its name.
- Be prior-aware: a candidate matching a settled decision (DECISION_JOURNAL D000+, AGENTS settled list, ROUNDING_POLICY) gets settled_ref=<D-id> and severity Info.
- You MAY write and run Python sims in the scratchpad. You may NOT run sui build/test or localnet (hand those to the main loop as a recipe in evidence).
- Quality over noise, but in maximal mode err toward surfacing a code-grounded candidate (verify will refute the wrong ones). Cap at your ${maxFindings} highest-value NEW findings this round. High/Critical MUST have concrete evidence.

Emit ONLY via the StructuredOutput schema. settled_ref="" and evidence="" only when truly empty.`
}

function isHigh(sev) { return sev === 'Critical' || sev === 'High' }

const LENSES = [
  { tag: 'refute', build: () => 'ADVERSARIAL LENS = REFUTE-BY-CORRECTNESS. Try to prove this finding FALSE from the actual code. Read the cited lines, grep all call sites, check whether the precondition can hold. If you cannot construct a concrete code-grounded triggering path, verdict "refuted". When the claim is an empirical/economic break, attempt a quick Python check. Cite file:line / sim evidence.' },
  { tag: 'settled', build: () => 'ADVERSARIAL LENS = SETTLED-DECISION CHECK. Search .claude/predict-design/DECISION_JOURNAL.md, HISTORY.md, AGENTS.md settled list, ROUNDING_POLICY.md. Is this an accepted/rejected design decision or a documented ACCEPT? If yes, verdict "settled" with the D-id in evidence. Otherwise pass through.' },
  { tag: 'repro', build: () => 'ADVERSARIAL LENS = REPRODUCE. Trace the exact PTB-ordered sequence through the real mint/redeem/liquidate/settle/flush code (and write a Python sim if the break is economic). Does it actually reach the cited line with all preconditions co-occurring? If they cannot co-exist, verdict "refuted"; if it genuinely triggers, "confirmed". Cite the call chain / sim seed.' },
]

const VERIFY_PREAMBLE = `You are an ADVERSARIAL VERIFIER in a Predict smart-contract audit. A lens proposed the finding below; TEST it against the actual code + git + the settled-decision priors, do NOT agree by default. Read ${SKILL}/primer.md for the module map + prior-awareness. The .claude/predict-review/ files are STALE — trust the current tree. Do NOT run sui build/test or localnet; reason from source, grep, git, and Python. Verdicts: confirmed (real, reproducible) / refuted (wrong, preconditions can't co-occur, or already mitigated) / settled (matches a D-id, cite it) / uncertain. Provide file:line / git / sim evidence. adjusted_severity = your independent severity (Info if refuted/settled).`

function verifyPrompt(f, laneKey, lens) {
  return `${VERIFY_PREAMBLE}\n\nFINDING (lane "${laneKey}"):\n${JSON.stringify(f, null, 2)}\n\n${lens.build()}`
}

function aggregate(f, laneKey, verdicts) {
  const vs = verdicts.filter(Boolean)
  const settled = vs.find(v => v.verdict === 'settled')
  const refuted = vs.filter(v => v.verdict === 'refuted').length
  const confirmed = vs.filter(v => v.verdict === 'confirmed').length
  let status = 'uncertain'
  if (settled) status = 'settled'
  else if (refuted > confirmed) status = 'refuted'
  else if (confirmed > 0) status = 'confirmed'
  return {
    lane: laneKey, status,
    severity: f.severity, title: f.title, location: f.location, claim: f.claim,
    scenario: f.scenario, impact: f.impact, confidence: f.confidence,
    recommendation: f.recommendation, settled_ref: settled ? (settled.evidence || f.settled_ref) : f.settled_ref,
    evidence: f.evidence,
    verifier_verdicts: vs.map(v => `${v.verdict}/${v.adjusted_severity}: ${v.reasoning} [${v.evidence}]`),
  }
}

// ---------- FIND: budget-aware loop-until-dry ----------
phase('Find')
function fkey(f) { return `${f.lane}|${(f.location || '').toLowerCase()}|${(f.title || '').toLowerCase()}`.slice(0, 200) }
const seen = new Set()
const candidates = []
const coverageByLane = {}
let dry = 0, round = 0
while (dry < DRY_TARGET && round < MAX_ROUNDS && budgetLeft() > RESERVE) {
  round++
  const known = candidates.map(f => `- [${f.severity}] (${f.lane}) ${f.title} @ ${f.location}`).join('\n')
  const roundRes = await parallel(LANES.map(lane => () => agent(finderPrompt(lane, round, known),
    { schema: FINDINGS_SCHEMA, effort: 'max', phase: 'Find', label: `find:${lane.key}:r${round}` })))
  let freshCount = 0
  roundRes.filter(Boolean).forEach(r => {
    coverageByLane[r.lane] = { coverage: r.coverage, top3: r.top3 || [] }
    ;(r.findings || []).forEach(f => {
      const ff = { ...f, lane: r.lane }
      const k = fkey(ff)
      if (!seen.has(k)) { seen.add(k); candidates.push(ff); freshCount++ }
    })
  })
  log(`Find round ${round}: +${freshCount} new (total ${candidates.length}) | budget ${budgetLeft() === Infinity ? '∞' : Math.round(budgetLeft() / 1e6) + 'M'} left`)
  if (freshCount === 0) dry++; else dry = 0
}
log(`Find converged after ${round} rounds (${dry} dry): ${candidates.length} unique candidates`)

// ---------- VERIFY: every candidate gets the full diverse panel (maximal mode) ----------
phase('Verify')
const verified = await parallel(candidates.map((f, fi) => async () => {
  const verdicts = await parallel(LENSES.map(lens => () =>
    agent(verifyPrompt(f, f.lane, lens), { schema: VERDICT_SCHEMA, effort: 'high', phase: 'Verify', label: `verify:${f.lane}:${fi}:${lens.tag}` })))
  return aggregate(f, f.lane, verdicts)
}))

const all = verified.filter(Boolean)
const kept = all.filter(f => f.status === 'confirmed' || f.status === 'uncertain')
const settledOut = all.filter(f => f.status === 'settled')
const refutedOut = all.filter(f => f.status === 'refuted')
const lanes = Object.keys(coverageByLane).map(k => ({ lane: k, coverage: coverageByLane[k].coverage, top3: coverageByLane[k].top3 }))
log(`Verify: candidates ${all.length} | kept ${kept.length} | settled ${settledOut.length} | refuted ${refutedOut.length}`)

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
  summary: { lenses: lanes.length, rounds: round, candidates: all.length, kept: kept.length, settled: settledOut.length, refuted: refutedOut.length, promoted: promoted.length },
  kept, settled: settledOut, refuted: refutedOut, promoted,
  coverage: lanes.map(l => ({ lane: l.lane, coverage: l.coverage, top3: l.top3 })),
}
