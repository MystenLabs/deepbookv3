// ⛔ DO NOT launch without EXPLICIT user confirmation (see the SKILL.md gate) — present the run plan + cost
//    and wait for an explicit "yes" first.
// Predict rule sweep — per-RULE conformance sweep for the MECHANICAL/local repo rules.
// Refreshed successor to the old root rule-auditor.md. Each agent owns ONE rule family and sweeps every
// relevant module for that rule only (broad-shallow — correct for rules that mean the same thing everywhere).
//
// The CONTEXTUAL ownership families (old rule-auditor Agents 6 "Flow Validation Ownership", 8 "Validate
// Before Mutate", and the leaf-self-consistency half of 9) are NOT here — they need deep per-module context
// and live in ownership-walk.workflow.js (R1-R7). Do not duplicate them.
//
// args = { rules?: string[] (subset of family keys), maxFindings?: number, groundTruth?: string }
// Subagents READ-ONLY; no sui build/test or localnet (watchdog) — the main loop runs the compiler in the
// parent-reconciliation pass (rule-auditor's build/test step).

export const meta = {
  name: 'predict-rule-sweep',
  description: 'Per-rule sweep of the mechanical/local repo rules across the Predict packages (refreshed rule-auditor): sweep -> verify/classify',
  phases: [
    { title: 'Sweep', detail: 'one agent per rule family sweeps every relevant module for that rule' },
    { title: 'Verify', detail: 'refute / classify each violation (fix-code / update-rule / design-decision / false-positive)' },
  ],
}

const SKILL = '.claude/skills/predict-audit'
let A = args
if (typeof A === 'string') { try { A = JSON.parse(A) } catch (e) { A = {} } }
if (!A || typeof A !== 'object') A = {}
const groundTruth = A.groundTruth || '(none provided)'
const maxFindings = A.maxFindings || 12

const ALL = 'all four packages (predict + propbook + account + block_scholes_oracle) sources, and tests where the rule names tests'

// Mechanical/local rule families (refreshed to the post-split module map; contextual 6/8/9 moved to the walk).
const RULE_FAMILIES = [
  { key: 'config-runtime-reads', scope: 'packages/predict/sources',
    rule: 'Admin-tunable values live in config structs; runtime/app logic reads the CURRENT value from the config object, never the `default_*` in config_constants. `min_*`/`max_*` bounds may be read directly ONLY when serving as an upgrade-required hard cap/floor. Do not add config fields/getters for bounds.',
    focus: 'Every `config_constants::*` use OUTSIDE config construction, setters, bounds checks, and tests. A `default_*` read in runtime logic is a violation; a bound read is a violation only when it accidentally bypasses an admin-tunable current value (non-finding when it is the intended upgrade-required envelope).' },
  { key: 'config-api-shape', scope: 'packages/predict/sources',
    rule: 'Public admin entrypoints live on the module owning the mutated state: `protocol_config` for global config, object modules for per-object admin state, `registry` for version/pause-cap/lifecycle-cap/uniqueness/multi-object creation. Embedded config-struct setters/constructors/bounds/template wiring stay `public(package)`. Global-template setters (affect future but not existing objects) include `template` in the name.',
    focus: 'config/ modules, protocol_config, registry, registry/market_manager. (The old `market_oracle`/`MarketOracleCap` per-market config path was removed in the oracle extraction — do not look for it.)' },
  { key: 'public-api-exposure', scope: ALL,
    rule: 'Public visibility is an API commitment, not secrecy. Expose `public` getters/functions only for values needed by external Move composition, PTB construction, or clear user-facing protocol state. Keep internal protocol composition `public(package)`.',
    focus: 'Every `public fun` and public struct. Flag public surface that only serves internal package composition with no external/PTB/user-facing consumer.' },
  { key: 'object-identity-keys', scope: 'packages/predict/sources',
    rule: 'Raw key constructors taking arbitrary object IDs stay package-only; public constructors are exposed through the object that anchors the key (immutable refs where possible). Do not store generic `config_id`/`object_id` fields in config structs or events when object identity already suffices.',
    focus: 'range_codec keys, predict_account `PositionKey`, registry lookup helpers, market_manager `MarketKey`, events, and any object-ID-based constructor.' },
  { key: 'create-and-share-naming', scope: ALL,
    rule: 'A function that creates AND shares a shared object is named `create_and_share*`.',
    focus: 'Every `transfer::share_object`/`public_share` call and any entrypoint that creates+shares (predict markets/managers/vaults; propbook `registry::create_and_share_pyth_feed`/`create_and_share_block_scholes_{spot,forward,svi}_feed`).' },
  { key: 'protocol-config-gates', scope: 'packages/predict/sources',
    rule: 'Public flow functions call the applicable ProtocolConfig gate. Trading pause blocks NEW risk creation (`assert_trading_allowed`); exits, settlement cleanup, and valuation are blocked ONLY by the valuation lock (`assert_not_valuation_in_progress` / valuation-lock lifecycle) unless semantics intentionally change.',
    focus: 'Produce a flow-gate matrix for every external public/entry flow: function | category (risk-creation / exit-cleanup / valuation / oracle-settlement / admin / read-only) | expected gate | actual gate (including gates delegated through callees) | verdict. Risk creation = mint, create_expiry_market, grow allocation. Exit/cleanup = redeem, shrink allocation, compaction. Record delegated gates before flagging a wrapper.' },
  { key: 'arithmetic-guard-noise', scope: ALL,
    rule: "Do not add explicit overflow/underflow/numeric-cast asserts solely to replace Move's primitive VM aborts (those are free atomic checks). KEEP named assertions for semantic domain bounds, division-by-zero with a meaningful named zero error, solvency/accounting invariants, authorization, lifecycle, gas-bounded iteration, and option/vector/balance assumptions.",
    focus: 'Math/pricing (fixed_math use, predict pricing), strike_payout_tree, expiry_cash, plp allocation math, propbook oracle normalization. Flag ONLY asserts that duplicate a VM overflow/cast abort. The leaf-self-consistency / redundant-caller-guard half of this rule is the ownership walk (R5) — do NOT report it here.' },
  { key: 'test-coverage-rules', scope: ALL,
    rule: "Every source `const E*` error code has >=1 `expected_failure` test naming that abort code (with a trailing guard abort using a DISTINCT code like `abort 999`). Every non-failure test asserts an output value or state change. Every test calls the function it claims to test. Prefer `assert_eq!`, import constants instead of duplicating, avoid magic numbers.",
    focus: 'All tests/ + every source error constant. Cross-check each `E*` against an `expected_failure`. NOTE: many predict flow tests are `.move.disabled` — flag uncovered `E*` but record the disabled-suite context so it is not mistaken for a regression.' },
  { key: 'timestamp-semantics', scope: 'packages/predict/sources and packages/propbook/sources',
    rule: "Timestamp fields have clear semantics; do not bump a 'last price update' field on unrelated updates (an SVI-param change must not bump a spot timestamp). Distinguish on-chain landing time (`*_timestamp_ms` = `clock.timestamp_ms()`) from source-data time (`*_published_at_us` or similar) in field/getter/event names.",
    focus: 'propbook `pyth_feed` + the 3 BS feeds + oracle_lane, predict pricing freshness checks, events, getter names. (The old in-package `pyth_source`/`market_oracle` were extracted to propbook — check the current feeds.)' },
  { key: 'events-hygiene', scope: ALL,
    rule: "Avoid 'created' events unless a concrete indexer/off-chain discovery need exists. Events are emitted by the module owning the lifecycle/action, AFTER the state transition completes, with semantic field names (`expiry_market_id`, `pool_vault_id`, `pyth_feed_id` — not generic `owner_id`/`object_id`/`config_id`). Embedded helper modules do not emit parent-scoped events.",
    focus: 'Every event struct + `event::emit` across predict events/, propbook events, account_events. Flag created-events without an indexer need, generic id fields, helper modules emitting parent-scoped events, and events emitted before their postcondition.' },
  { key: 'dead-field-liveness', scope: ALL,
    rule: 'Every declared struct field should have BOTH a writer AND a reader on a LIVE (non-test, non-.disabled) path. A WRITE-ONLY field (set/incremented but never read by live logic for a decision/payout/event) or a READ-ONLY mirror (read but never maintained) is an ownership/liveness defect. Canonical case: the rebate-reserve became write-only when its consumer (claim_trading_loss_rebate) was deleted in the rework, silently walling off ~50% of trading fees.',
    focus: 'Enumerate EVERY struct field across all four packages. For each, grep its writers and its readers on LIVE paths (exclude tests + .disabled). Flag (a) write-only fields, (b) read-only mirrors, (c) a field whose sole consumer was removed by the oracle/custody/async-LP rework. This is the exhaustive MECHANICAL complement to the ownership-walk R7 contextual catch — list the fields you cleared too, so coverage is provable.' },
]

const wantRules = Array.isArray(A.rules) ? A.rules : null
const FAMILIES = wantRules && wantRules.length ? RULE_FAMILIES.filter(r => wantRules.indexOf(r.key) >= 0) : RULE_FAMILIES
const unknown = wantRules ? wantRules.filter(k => !RULE_FAMILIES.some(r => r.key === k)) : []
log(`rule-sweep config — rules: ${wantRules ? wantRules.join(',') : `ALL ${RULE_FAMILIES.length}`} | maxFindings/rule: ${maxFindings} | groundTruth: ${String(groundTruth).slice(0, 60)}`
  + (unknown.length ? ` | ⚠ UNKNOWN RULE KEYS IGNORED: ${unknown.join(',')} (valid: ${RULE_FAMILIES.map(r => r.key).join(',')})` : ''))
if (wantRules && !FAMILIES.length) {
  log('⚠ rule filter matched nothing — aborting')
  return { error: 'no_rules_matched', requested: wantRules, valid_keys: RULE_FAMILIES.map(r => r.key) }
}

const PRELUDE = `You are an agent in the Predict RULE SWEEP — a per-rule conformance audit of the MECHANICAL repo rules. FIRST read:
  1. ${SKILL}/primer.md  (current module map, scope, prior-awareness, report format)
  2. the source rules: .claude/rules/move.md, .claude/rules/code-review.md, .claude/rules/unit-tests.md, and AGENTS.md "Settled design decisions".
Conflict order: most-specific Predict rule in AGENTS.md, then .claude/rules/*.md, then general guidance. Be prior-aware: a candidate matching a DECISION_JOURNAL/AGENTS settled decision is a non-finding (tag it). The .claude/predict-review map is STALE — trust primer.md + the current tree. Read-only on source; do NOT run sui build/test or localnet (the watchdog kills subagents — the main loop runs the compiler in reconciliation). Your job is ONE rule only; do not report other rules' violations or the ownership-walk's R1-R7.`

const FINDING = {
  type: 'object',
  properties: {
    location: { type: 'string', description: 'file.move:line(s)' },
    claim: { type: 'string', description: 'why this violates the rule (quote the rule text)' },
    severity: { type: 'string', enum: ['high', 'medium', 'low', 'cleanup'], description: 'high ONLY if it can strand funds / brick a flow / misprice an indexer (e.g. a write-only field); most hygiene is cleanup/low' },
    context: { type: 'string' },
    defensible: { type: 'string', enum: ['yes', 'no', 'unclear'] },
    classification: { type: 'string', enum: ['fix-code', 'update-rule', 'design-decision', 'false-positive'] },
    recommendation: { type: 'string', description: 'smallest code fix OR the narrowest rule exception to add' },
  },
  required: ['location', 'claim', 'classification', 'recommendation'],
}
const SWEEP_SCHEMA = {
  type: 'object',
  properties: { rule_family: { type: 'string' }, coverage: { type: 'string' }, findings: { type: 'array', items: FINDING } },
  required: ['rule_family', 'coverage', 'findings'],
}
const VERDICT_SCHEMA = {
  type: 'object',
  properties: {
    verdict: { type: 'string', enum: ['confirmed', 'refuted', 'settled'] },
    classification: { type: 'string', enum: ['fix-code', 'update-rule', 'design-decision', 'false-positive'] },
    reasoning: { type: 'string' },
    evidence: { type: 'string' },
  },
  required: ['verdict', 'classification', 'reasoning', 'evidence'],
}

// MAXIMAL MODE: loop-until-dry SWEEP. Re-sweep each rule family across rounds (each told what's already
// found for that family so it hunts new sites), union new findings, until K dry rounds or the budget floor.
const DRY_TARGET = A.dryRounds || 2
const MAX_ROUNDS = A.maxRounds || 10
const RESERVE = (budget && budget.total) ? Math.max(3_000_000, Math.floor(budget.total * 0.3)) : 3_000_000
function budgetLeft() { return budget && typeof budget.remaining === 'function' ? budget.remaining() : Infinity }
// strip line numbers so a same violation at a shifted line still dedups across rounds.
function fkey(f) { return `${f.rule_family}|${(f.location || '').toLowerCase().replace(/:[0-9][0-9,\- ]*/g, '').replace(/[^a-z0-9/._;]/g, '')}`.slice(0, 160) }
function sweepPrompt(rf, round, known) {
  return `${PRELUDE}\n\n=== RULE FAMILY: ${rf.key} (round ${round}) ===\nRULE: ${rf.rule}\nSCOPE: ${rf.scope}\nWHERE TO LOOK: ${rf.focus}\n\n`
    + (known ? `ALREADY-FOUND violations of this rule (do NOT re-report — find DIFFERENT ones, in modules/branches not yet covered):\n${known}\n\n` : '')
    + `Inspect every relevant module/function/branch/test for THIS rule across the scope. Report each violation with file:line, the rule text it breaks, a SEVERITY (high only if it can strand funds / brick a flow / misprice an indexer — e.g. a write-only field; most hygiene is cleanup/low), context, whether it is a defensible exception (yes/no/unclear), the recommended action (fix-code / update-rule / design-decision / false-positive), and the smallest fix or narrowest rule exception. Per the calibration principle, a defensible recurring pattern is an update-rule candidate, not many repeat findings. Keep each finding CONCISE — claim and recommendation ≤2 sentences each, context ≤1 line; a verbose response risks truncating the structured output. Cap at your ${maxFindings} highest-value NEW findings.`
}

phase('Sweep')
const seen = new Set()
const candidates = []
let dry = 0, round = 0
while (dry < DRY_TARGET && round < MAX_ROUNDS && budgetLeft() > RESERVE) {
  round++
  const knownByFamily = {}
  candidates.forEach(f => { (knownByFamily[f.rule_family] = knownByFamily[f.rule_family] || []).push(`- ${f.location}: ${(f.claim || '').slice(0, 120)}`) })
  const roundRes = await parallel(FAMILIES.map(rf => () => agent(sweepPrompt(rf, round, (knownByFamily[rf.key] || []).join('\n')),
    { schema: SWEEP_SCHEMA, effort: 'high', phase: 'Sweep', label: `sweep:${rf.key}:r${round}` })))
  let freshCount = 0
  roundRes.filter(Boolean).forEach(r => {
    ;(r.findings || []).forEach(f => {
      const ff = { ...f, rule_family: r.rule_family }
      const k = fkey(ff)
      if (!seen.has(k)) { seen.add(k); candidates.push(ff); freshCount++ }
    })
  })
  log(`Sweep round ${round}: +${freshCount} new (total ${candidates.length}) | budget ${budgetLeft() === Infinity ? '∞' : Math.round(budgetLeft() / 1e6) + 'M'} left`)
  if (freshCount === 0) dry++; else dry = 0
}
log(`Sweep converged after ${round} rounds (${dry} dry): ${candidates.length} unique candidate findings`)

phase('Verify')
const all = (await parallel(candidates.map((f, fi) => () => agent(
  `${PRELUDE}\n\nADVERSARIALLY VERIFY this single rule-sweep finding (rule family ${f.rule_family}). Read the cited code; decide: confirmed (real violation) / refuted (not a violation, or the claim is wrong) / settled (matches a DECISION_JOURNAL/AGENTS decision — cite it). Then classify: fix-code / update-rule (defensible → narrowest exception) / design-decision / false-positive. Be skeptical; mechanical rules have many intentional exceptions (getters retained by D003, public APIs needed for PTBs, disabled test suites).\n\nFINDING:\n${JSON.stringify(f, null, 2)}`,
  { schema: VERDICT_SCHEMA, effort: 'high', phase: 'Verify', label: `verify:${f.rule_family}:${fi}` })
  .then(verdict => ({ ...f, verdict }))))).filter(Boolean)
const confirmed = all.filter(x => x.verdict && x.verdict.verdict === 'confirmed')
const settledOut = all.filter(x => x.verdict && x.verdict.verdict === 'settled')
const refutedOut = all.filter(x => x.verdict && x.verdict.verdict === 'refuted')
log(`Rule families: ${FAMILIES.length} | rounds: ${round} | findings: ${all.length} | confirmed: ${confirmed.length} | settled: ${settledOut.length} | refuted: ${refutedOut.length}`)

function shape(x) {
  return { rule_family: x.rule_family, severity: x.severity || (x.classification === 'fix-code' ? 'medium' : 'low'), location: x.location, claim: x.claim, classification: (x.verdict && x.verdict.classification) || x.classification, recommendation: x.recommendation, evidence: x.verdict && x.verdict.evidence }
}
return {
  summary: { rule_families: FAMILIES.length, rounds: round, findings: all.length, confirmed: confirmed.length, settled: settledOut.length, refuted: refutedOut.length },
  confirmed: confirmed.map(shape),
  settled: settledOut.map(shape),
  refuted: refutedOut.map(x => ({ rule_family: x.rule_family, location: x.location, claim: x.claim, why: x.verdict && x.verdict.reasoning })),
}
