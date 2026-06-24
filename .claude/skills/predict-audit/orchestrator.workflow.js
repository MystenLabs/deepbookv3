// Predict smart-contract audit orchestrator.
//
// Launch from the MAIN LOOP after running ground-truth (sui build/test all 4 packages + a sim smoke),
// passing the results in via `args`. This workflow does the parallel find -> adversarial-verify fan-out
// and returns structured findings; the MAIN LOOP synthesizes the final report (and runs any localnet PoC).
//
// args = {
//   groundTruth: string,   // build/test/sim summary from the main loop (e.g. "predict 223/223 green; ...")
//   scope:       string,   // what to audit ("full protocol at HEAD" | a git range "A..B" | a file list)
//   lenses?:     string[], // optional subset of lens keys to run (default: all 9) — use for a cheap dry run
//   maxFindings?: number,  // optional cap on findings returned per lens (default: 12)
// }
//
// Subagents are READ-ONLY on source and must NOT run `sui build/test` or localnet (watchdog) — only Python.

export const meta = {
  name: 'predict-audit-orchestrator',
  description: 'Parallel multi-lens smart-contract audit of Predict (+ propbook, block_scholes_oracle, account): find -> adversarially verify -> structured findings',
  phases: [
    { title: 'Find', detail: '10 prior-aware lenses fan out over the four packages' },
    { title: 'Verify', detail: 'refute / settled / repro panel per candidate finding' },
    { title: 'Promote', detail: 'elevate high-signal observations buried in coverage into findings' },
  ],
}

const SKILL = '.claude/skills/predict-audit'
// Normalize args: the Workflow runtime may deliver `args` as an object OR a JSON string.
let A = args
if (typeof A === 'string') { try { A = JSON.parse(A) } catch (e) { A = {} } }
if (!A || typeof A !== 'object') A = {}
const groundTruth = A.groundTruth || '(no ground-truth provided — note this in coverage)'
const scope = A.scope || 'full protocol at current HEAD'
const maxFindings = A.maxFindings || 12

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
// Echo the resolved config so /workflows shows whether scope/lenses actually applied (a silent
// full-fleet run is exactly what burned us once — never run the full fleet without saying so).
log(`audit config — scope: "${scope}" | lenses: ${want ? want.join(',') : `ALL ${ALL_LANES.length} (no filter)`} | maxFindings: ${maxFindings}`
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

function finderPrompt(lane) {
  return `You are the "${lane.key}" lens of a deep, prior-aware smart-contract audit of DeepBook Predict and its split-out sibling packages (propbook, block_scholes_oracle, account).

FIRST read these two files and follow them exactly:
  1. ${SKILL}/primer.md          (protocol, current module map, scope, prior-awareness, empirical toolbox, report format)
  2. ${SKILL}/lenses/${lane.file}  (your lens: deliverables, focus areas, empirical mandate, output)
You may also cite ${SKILL}/references/*.md (Move/Sui checklist, invariant classes, attack catalog).

SCOPE: ${scope}
GROUND TRUTH (from the main loop — do NOT re-run sui build/test or localnet; the watchdog kills subagents): ${groundTruth}

DISCIPLINE (binding):
- Read-only on packages/*/sources/**. Verify every claim against the actual function body + call sites (grep), not its name.
- Be prior-aware: a candidate matching a settled decision (DECISION_JOURNAL D000+, AGENTS settled list, ROUNDING_POLICY) gets settled_ref=<D-id> and severity Info — do not raise it as new.
- You MAY write and run Python sims in the scratchpad (fast, safe). You may NOT run sui build/test or localnet bash run.sh (hand those to the main loop as a recipe in evidence).
- Prefer a few verified findings over many speculative ones; rank uncertain items low-confidence. Cap at your ${maxFindings} highest-value findings. High/Critical findings MUST have concrete evidence.

Emit ONLY via the StructuredOutput schema. settled_ref="" and evidence="" only when truly empty.`
}

phase('Find')

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

const results = await pipeline(
  LANES,
  lane => agent(finderPrompt(lane), { schema: FINDINGS_SCHEMA, phase: 'Find', label: `find:${lane.key}` }),
  async (review, lane) => {
    if (!review) return { lane: lane.key, coverage: '(finder failed/skipped)', top3: [], findings: [] }
    const fs = review.findings || []
    const verified = await parallel(fs.map((f, fi) => async () => {
      const panel = isHigh(f.severity) ? LENSES : LENSES.slice(0, 2)
      const verdicts = await parallel(panel.map(lens => () =>
        agent(verifyPrompt(f, lane.key, lens), { schema: VERDICT_SCHEMA, effort: 'high', phase: 'Verify', label: `verify:${lane.key}:${fi}:${lens.tag}` })))
      return aggregate(f, lane.key, verdicts)
    }))
    return { lane: lane.key, coverage: review.coverage, top3: review.top3 || [], findings: verified.filter(Boolean) }
  },
)

const lanes = results.filter(Boolean)
const all = lanes.flatMap(l => l.findings)
const kept = all.filter(f => f.status === 'confirmed' || f.status === 'uncertain')
const settledOut = all.filter(f => f.status === 'settled')
const refutedOut = all.filter(f => f.status === 'refuted')

log(`Lenses: ${lanes.length} | candidates: ${all.length} | kept: ${kept.length} | settled: ${settledOut.length} | refuted: ${refutedOut.length}`)

// Promotion pass: lenses sometimes bury a real issue inside their Coverage/aside text without raising it
// as a finding. One critic scans all coverage + the captured findings and elevates anything high-signal.
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
  { schema: PROMOTE_SCHEMA, phase: 'Promote', label: 'promote:coverage-critic' })
const promoted = (promoteRes && promoteRes.findings) || []
if (promoted.length) log(`Promoted ${promoted.length} buried observation(s) from coverage into findings`)

return {
  summary: { lenses: lanes.length, candidates: all.length, kept: kept.length, settled: settledOut.length, refuted: refutedOut.length, promoted: promoted.length },
  kept, settled: settledOut, refuted: refutedOut, promoted,
  coverage: lanes.map(l => ({ lane: l.lane, coverage: l.coverage, top3: l.top3 })),
}
