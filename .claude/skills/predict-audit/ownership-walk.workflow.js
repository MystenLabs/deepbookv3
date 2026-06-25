// ⛔ DO NOT launch without EXPLICIT user confirmation (see the SKILL.md gate) — present the run plan + cost
//    and wait for an explicit "yes" first.
// Predict ownership walk — recursive per-module ownership/boundary/policy conformance audit.
//
// Shape: Map (barrier) -> Check (per-module fan-out) -> Verify. The barrier is REAL: a conformance verdict
// for a function depends on knowing what the modules it composes are SUPPOSED to own, so the full
// responsibility map must exist before any check runs. Checks R1-R7 from references/ownership-rules.md.
//
// args = {
//   units?:  string[],   // subset of MAP_UNIT keys to walk (default: all) — use to scope cost
//   groundTruth?: string,
//   maxViolations?: number, // cap per check unit (default 10)
//   dryRounds?: number,     // stop after this many no-new-violation rounds (default 2)
//   maxRounds?: number,     // hard round cap (default 3)
//   verifyCap?: number,     // max violations sent to the verifier (default 60)
// }
// COST IS BOUNDED BY CONSTRUCTION: agents <= units (map) + maxRounds*checkUnits (check) + verifyCap (verify),
// so a run cannot hit the 1000-agent cap. The `budget` global (a "+NNNm" turn directive) is only an optional
// early-stop and often does NOT propagate into a background workflow — never rely on it. Verify is
// SEVERITY-GATED: 'cleanup'-tier violations are reported RAW (unverified, no subagent); 'high'/'correctness'
// get one verifier each.
// Subagents are READ-ONLY on source; no sui build/test or localnet (watchdog) — reason from source + grep + git.

export const meta = {
  name: 'predict-ownership-walk',
  description: 'Recursive per-module ownership/boundary/policy conformance audit of Predict (map -> check -> verify) against references/ownership-rules.md R1-R7',
  phases: [
    { title: 'Map', detail: 'build the responsibility map per subsystem (BARRIER — checks need the whole map)' },
    { title: 'Check', detail: 'per-module fan-out: walk every function vs R1-R7 + the map' },
    { title: 'Verify', detail: 'severity-gated: refute each high/correctness violation vs the map + DECISION_JOURNAL; cleanup-tier reported raw' },
  ],
}

const SKILL = '.claude/skills/predict-audit'
let A = args
if (typeof A === 'string') { try { A = JSON.parse(A) } catch (e) { A = {} } }
if (!A || typeof A !== 'object') A = {}
const groundTruth = A.groundTruth || '(none provided)'
const maxViolations = A.maxViolations || 10

// Map units = subsystem clusters. Each map agent builds the responsibility-map entries for its modules.
const MAP_UNITS = [
  { key: 'predict-core', pkg: 'predict', paths: 'sources/expiry_market.move sources/expiry_cash.move sources/order.move sources/ewma.move sources/builder_code.move sources/predict_account.move sources/constants.move' },
  { key: 'predict-strike', pkg: 'predict', paths: 'sources/strike_exposure' },
  { key: 'predict-plp', pkg: 'predict', paths: 'sources/plp' },
  { key: 'predict-pricing', pkg: 'predict', paths: 'sources/pricing' },
  { key: 'predict-registry', pkg: 'predict', paths: 'sources/registry' },
  { key: 'predict-config', pkg: 'predict', paths: 'sources/config' },
  { key: 'predict-capabilities', pkg: 'predict', paths: 'sources/capabilities' },
  { key: 'predict-events', pkg: 'predict', paths: 'sources/events' },
  { key: 'propbook', pkg: 'propbook', paths: 'sources' },
  { key: 'account', pkg: 'account', paths: 'sources' },
  { key: 'block_scholes_oracle', pkg: 'block_scholes_oracle', paths: 'sources' },
]
const wantUnits = Array.isArray(A.units) ? A.units : null
const UNITS = wantUnits && wantUnits.length ? MAP_UNITS.filter(u => wantUnits.indexOf(u.key) >= 0) : MAP_UNITS
const unknownUnits = wantUnits ? wantUnits.filter(k => !MAP_UNITS.some(u => u.key === k)) : []
log(`ownership-walk config — units: ${wantUnits ? wantUnits.join(',') : `ALL ${MAP_UNITS.length}`} | maxViolations/module: ${maxViolations} | groundTruth: ${String(groundTruth).slice(0, 60)}`
  + (unknownUnits.length ? ` | ⚠ UNKNOWN UNIT KEYS IGNORED: ${unknownUnits.join(',')} (valid: ${MAP_UNITS.map(u => u.key).join(',')})` : ''))
if (wantUnits && !UNITS.length) {
  log('⚠ unit filter matched nothing — aborting')
  return { error: 'no_units_matched', requested: wantUnits, valid_keys: MAP_UNITS.map(u => u.key) }
}

const PRELUDE = `You are an agent in the Predict OWNERSHIP WALK — a recursive conformance audit of the ownership/boundary/policy rules. FIRST read these and follow them exactly:
  1. ${SKILL}/primer.md           (protocol, current module map, scope, prior-awareness, report format)
  2. ${SKILL}/references/ownership-rules.md  (R1-R7 — the rule-set you enforce, with intentional exceptions)
Be prior-aware: ${SKILL}/../predict-design/DECISION_JOURNAL.md + AGENTS.md settled list + ROUNDING_POLICY.md — a candidate matching a settled/accepted decision is NOT a violation (tag settled_ref). Read-only on packages/*/sources/**; do NOT run sui build/test or localnet (watchdog); reason from source + grep + git. The .claude/predict-review module map is STALE — trust primer.md + the current tree.`

const MODULE_ENTRY = {
  type: 'object',
  properties: {
    module: { type: 'string', description: 'pkg::module, e.g. predict::expiry_market' },
    file: { type: 'string' },
    role: { type: 'string', enum: ['state-owner', 'composer', 'leaf', 'flow-entry', 'config', 'events', 'mixed'] },
    owns: { type: 'string', description: 'the facts/state/policy/guards it is the source of truth for' },
    must_not_own: { type: 'string', description: 'concerns that belong to a neighbor' },
    composes: { type: 'array', items: { type: 'string' }, description: 'module names it orchestrates/depends on for domain facts' },
    functions: { type: 'array', items: { type: 'string' }, description: 'every public/package/private function name' },
  },
  required: ['module', 'file', 'role', 'owns', 'must_not_own', 'composes', 'functions'],
}
const MAP_SCHEMA = {
  type: 'object',
  properties: { unit: { type: 'string' }, modules: { type: 'array', items: MODULE_ENTRY } },
  required: ['unit', 'modules'],
}

const VIOLATION = {
  type: 'object',
  properties: {
    rule_family: { type: 'string', enum: ['R1', 'R2', 'R3', 'R4', 'R5', 'R6', 'R7'] },
    node: { type: 'string', description: 'pkg::module::function:line' },
    claim: { type: 'string', description: 'what responsibility is misplaced' },
    expected_owner: { type: 'string' },
    actual_owner: { type: 'string' },
    data_flow: { type: 'string', description: 'the call chain / value path that proves it' },
    severity: { type: 'string', enum: ['high', 'correctness', 'cleanup'] },
    settled_ref: { type: 'string' },
    recommendation: { type: 'string' },
  },
  // Soft fields (expected_owner/actual_owner/data_flow/settled_ref) are optional: a slightly-incomplete
  // violation still validates instead of burning the 5-retry cap (which lost 2/8 units on the first smoke).
  required: ['rule_family', 'node', 'claim', 'severity', 'recommendation'],
}
const CHECK_SCHEMA = {
  type: 'object',
  properties: { module: { type: 'string' }, coverage: { type: 'string' }, violations: { type: 'array', items: VIOLATION } },
  required: ['module', 'coverage', 'violations'],
}
const VERDICT_SCHEMA = {
  type: 'object',
  properties: {
    verdict: { type: 'string', enum: ['confirmed', 'refuted', 'settled', 'uncertain'] },
    classification: { type: 'string', enum: ['fix-code', 'update-rule', 'design-decision', 'false-positive'] },
    adjusted_severity: { type: 'string', enum: ['high', 'correctness', 'cleanup'] },
    reasoning: { type: 'string' },
    evidence: { type: 'string' },
  },
  required: ['verdict', 'classification', 'adjusted_severity', 'reasoning', 'evidence'],
}

// ---------- Pass 1: MAP (barrier) ----------
phase('Map')
const mapResults = await parallel(UNITS.map(u => () => agent(
  `${PRELUDE}\n\n=== MAP PASS — unit "${u.key}" (${u.pkg}/${u.paths}) ===\n`
  + `Build the RESPONSIBILITY MAP for every module under those path(s) in packages/${u.pkg}/. For each module emit its entry: role (state-owner/composer/leaf/flow-entry/config/events/mixed — a module that declares Balance/liability fields is a state-owner; one that imports many domain objects to sequence them is a composer; a math/index/data-structure module is a leaf), owns (the facts/state/policy/guards it is the source of truth for — it owns the fields it declares + derivations purely within its domain), must_not_own (what belongs to a neighbor), composes (modules it orchestrates), and functions (EVERY function name — public/package/private; this drives the per-function check). This map is the SPEC the check pass measures against, so be precise about ownership boundaries.`,
  { schema: MAP_SCHEMA, phase: 'Map', label: `map:${u.key}` })))

const unmappedUnits = UNITS.filter((u, i) => !mapResults[i]).map(u => u.key)
if (unmappedUnits.length) log(`⚠ MAP failed for ${unmappedUnits.length} unit(s) — their modules are NOT walked this run (resume to fill): ${unmappedUnits.join(', ')}`)
const allModules = mapResults.filter(Boolean).flatMap(r => r.modules || [])
const mapByModule = {}
allModules.forEach(m => { mapByModule[m.module] = m })
log(`Responsibility map: ${allModules.length} modules across ${UNITS.length} units`)
if (!allModules.length) return { error: 'empty_map', units: UNITS.map(u => u.key) }

// God-module split: hold the module context, walk a bounded slice of functions per agent.
function checkUnitsFor(m) {
  const fns = m.functions || []
  const CHUNK = 9
  if (fns.length <= 20) return [{ module: m.module, file: m.file, entry: m, fnFocus: null, label: m.module }]
  const out = []
  for (let i = 0; i < fns.length; i += CHUNK) {
    out.push({ module: m.module, file: m.file, entry: m, fnFocus: fns.slice(i, i + CHUNK), label: `${m.module}#${out.length + 1}` })
  }
  return out
}
const CHECK_UNITS = allModules.flatMap(checkUnitsFor)

// ---------- Pass 2 + 3: CHECK -> VERIFY (pipelined; verify needs no cross-module barrier) ----------
phase('Check')
function composedContext(entry) {
  return (entry.composes || []).map(name => mapByModule[name]).filter(Boolean)
    .map(e => `  - ${e.module} [${e.role}] owns: ${e.owns}`).join('\n') || '  (none mapped in scope)'
}

// MAXIMAL MODE: loop-until-dry CHECK. Violations are sampled, so re-walk each module across rounds (each
// told what's already found FOR THAT MODULE so it hunts new ground), union new violations, until K dry
// rounds or the budget floor. Auto-retries flaky units (a failed unit is an empty round that re-runs).
const DRY_TARGET = A.dryRounds || 2
const MAX_ROUNDS = A.maxRounds || 3
const VERIFY_CAP = A.verifyCap || 60
const RESERVE = (budget && budget.total) ? Math.max(4_000_000, Math.floor(budget.total * 0.3)) : 4_000_000
function budgetLeft() { return budget && typeof budget.remaining === 'function' ? budget.remaining() : Infinity }
// strip line numbers from node so a same violation at a shifted line still dedups across rounds (else the
// loop never dries — see orchestrator nloc comment).
function vkey(v) { return `${v.module}|${v.rule_family}|${(v.node || '').toLowerCase().replace(/:[0-9][0-9,\- ]*/g, '').replace(/[^a-z0-9:_]/g, '')}|${(v.claim || '').toLowerCase().replace(/[^a-z0-9]+/g, '').slice(0, 40)}` }

function checkPrompt(cu, round, known) {
  return `${PRELUDE}\n\n=== CHECK PASS (round ${round}) — module ${cu.module} (${cu.file}) ===\n`
    + `This module's responsibility-map entry:\n  role: ${cu.entry.role}\n  owns: ${cu.entry.owns}\n  must_not_own: ${cu.entry.must_not_own}\n`
    + `Modules it composes (their owned facts — use to judge binding/derivation/producer-fact):\n${composedContext(cu.entry)}\n\n`
    + (known ? `ALREADY-FOUND violations in this module (do NOT re-report — hunt DIFFERENT, deeper, rarer ones, and functions not yet covered):\n${known}\n\n` : '')
    + `Walk ${cu.fnFocus ? `these functions: ${cu.fnFocus.join(', ')}` : 'EVERY function in the module'} and check R1-R7 (see ownership-rules.md) at each. A violation is a MISPLACED responsibility — a leaf owning app policy (R3), a producer returning a lossy-transformed value a consumer does math on (R1), a derivation re-implemented/threaded (R2), mutate-before-validate (R4), a leaf trusting its caller or a redundant caller guard (R5), a field mutated outside its declarer / raw fields threaded (R6), or a state/policy/fact with no clear owner — incl. write-only fields (R7). Check the intentional-exceptions list in ownership-rules.md and the settled decisions BEFORE flagging. Keep each violation CONCISE — claim ≤2 sentences, recommendation ≤1 sentence, data_flow ≤1 line (the VERIFIER reconstructs the full proof). A verbose multi-paragraph response risks truncating the structured output and losing the whole unit. Cap at your ${maxViolations} highest-confidence NEW violations.`
}
function verifyPromptV(v) {
  return `${PRELUDE}\n\nYou are the ADVERSARIAL VERIFIER for one ownership-walk violation. TEST it; do not agree by default — R1-R7 false-positive heavily on intentional architecture (the strike_payout_tree::payout_terms single evaluator, D033 deferred-carry, saturating_sub-as-deliberate-policy, documented post-mutation calcs). Read the cited code + the data_flow + the responsibility map. Verdict: confirmed (real misplaced responsibility) / refuted (the responsibility IS correctly placed, or the claim is wrong) / settled (matches a DECISION_JOURNAL/AGENTS decision — cite the D-id) / uncertain. Also classify: fix-code / update-rule (defensible → narrowest rule exception) / design-decision / false-positive.\n\nVIOLATION (module ${v.module}):\n${JSON.stringify(v, null, 2)}`
}

const seen = new Set()
const candidates = []
const coverageByModule = {}
let dry = 0, round = 0
while (dry < DRY_TARGET && round < MAX_ROUNDS && budgetLeft() > RESERVE) {
  round++
  const knownByModule = {}
  candidates.forEach(v => { (knownByModule[v.module] = knownByModule[v.module] || []).push(`- [${v.rule_family}] ${v.node}: ${(v.claim || '').slice(0, 120)}`) })
  const roundRes = await parallel(CHECK_UNITS.map(cu => () => agent(checkPrompt(cu, round, (knownByModule[cu.module] || []).join('\n')),
    { schema: CHECK_SCHEMA, effort: 'max', phase: 'Check', label: `check:${cu.label}:r${round}` })))
  let freshCount = 0
  roundRes.filter(Boolean).forEach(r => {
    if (r.coverage) coverageByModule[r.module] = r.coverage
    ;(r.violations || []).forEach(v => {
      const vv = { ...v, module: r.module }
      const k = vkey(vv)
      if (!seen.has(k)) { seen.add(k); candidates.push(vv); freshCount++ }
    })
  })
  log(`Check round ${round}: +${freshCount} new (total ${candidates.length}) | budget ${budgetLeft() === Infinity ? '∞' : Math.round(budgetLeft() / 1e6) + 'M'} left`)
  if (freshCount === 0) dry++; else dry = 0
}
log(`Check converged after ${round} rounds (${dry} dry): ${candidates.length} unique candidate violations`)

// SEVERITY-GATED + CAPPED: only 'high'/'correctness' violations get a verifier; 'cleanup'-tier violations are
// reported RAW (unverified). Capped at VERIFY_CAP by severity so the agent count stays bounded.
phase('Verify')
const sevRankV = { high: 3, correctness: 2, cleanup: 1 }
const verifyAll = candidates.filter(v => v.severity !== 'cleanup').sort((a, b) => (sevRankV[b.severity] || 0) - (sevRankV[a.severity] || 0))
const toVerify = verifyAll.slice(0, VERIFY_CAP)
const verifyOverflow = verifyAll.slice(VERIFY_CAP)   // beyond the cap -> reported unverified (logged, never silently dropped)
const unverifiedV = candidates.filter(v => v.severity === 'cleanup').concat(verifyOverflow)
if (verifyOverflow.length) log(`Verify cap ${VERIFY_CAP} hit: ${verifyOverflow.length} violation(s) reported UNVERIFIED — raise verifyCap to verify them all`)
const all = (await parallel(toVerify.map((v, vi) => () => agent(verifyPromptV(v),
  { schema: VERDICT_SCHEMA, effort: 'high', phase: 'Verify', label: `verify:${v.module}:${vi}` })
  .then(verdict => ({ ...v, verdict }))))).filter(Boolean)
const confirmed = all.filter(x => x.verdict && (x.verdict.verdict === 'confirmed' || x.verdict.verdict === 'uncertain'))
const settledOut = all.filter(x => x.verdict && x.verdict.verdict === 'settled')
const refutedOut = all.filter(x => x.verdict && x.verdict.verdict === 'refuted')

// Calibration: rules tripped repeatedly by intentional architecture are candidate rule-exceptions, not N findings.
const byRule = {}
all.forEach(x => { byRule[x.rule_family] = byRule[x.rule_family] || { confirmed: 0, defensible: 0 } })
confirmed.forEach(x => { byRule[x.rule_family].confirmed++ })
all.filter(x => x.verdict && (x.verdict.classification === 'update-rule' || x.verdict.classification === 'design-decision')).forEach(x => { byRule[x.rule_family].defensible++ })

log(`Modules: ${allModules.length} | check units: ${CHECK_UNITS.length} | rounds: ${round} | violations: ${all.length} | confirmed: ${confirmed.length} | settled: ${settledOut.length} | refuted: ${refutedOut.length}`)

return {
  summary: { modules: allModules.length, checkUnits: CHECK_UNITS.length, unmapped_units: unmappedUnits, rounds: round, violations: all.length, confirmed: confirmed.length, settled: settledOut.length, refuted: refutedOut.length, unverified: unverifiedV.length },
  responsibility_map: allModules.map(m => ({ module: m.module, role: m.role, owns: m.owns, composes: m.composes })),
  coverage: Object.keys(coverageByModule).map(m => ({ lane: m, coverage: coverageByModule[m] })),
  unverified: unverifiedV.map(x => ({ rule_family: x.rule_family, node: x.node, claim: x.claim, severity: x.severity, settled_ref: x.settled_ref, recommendation: x.recommendation, status: 'unverified' })),
  confirmed: confirmed.map(x => ({ rule_family: x.rule_family, node: x.node, claim: x.claim, expected_owner: x.expected_owner, actual_owner: x.actual_owner, severity: (x.verdict && x.verdict.adjusted_severity) || x.severity, status: (x.verdict && x.verdict.verdict) || 'confirmed', classification: x.verdict && x.verdict.classification, settled_ref: x.settled_ref, recommendation: x.recommendation, data_flow: x.data_flow, proof: x.verdict && x.verdict.evidence })),
  settled: settledOut.map(x => ({ rule_family: x.rule_family, node: x.node, claim: x.claim, settled_ref: (x.verdict && x.verdict.evidence) || x.settled_ref })),
  refuted: refutedOut.map(x => ({ rule_family: x.rule_family, node: x.node, claim: x.claim, why: x.verdict && x.verdict.reasoning })),
  calibration: byRule,
}
