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
// args = { rules: string[] | 'all' (REQUIRED — subset of family keys, or the explicit string 'all' for every
//            family; there is NO whole-sweep default), maxFindings?: number, groundTruth?: string,
//          depth?: 'mini'|'low'|'standard'|'max' (preset for rounds/verifyCap/effort; explicit caps win;
//            mini = cleanup-triage: 1 round, NO verify subagents — findings reported raw, sweep effort medium),
//          files?: string[] (DELTA SCOPE: concentrate the sweep on these changed files + direct callers),
//          priorAdjudications?: [{title, location, status, note?}] (cross-run memory: seeded into the sweep
//            prompts as do-not-re-report; pass only entries whose cited files are unchanged — see SKILL.md.
//            Unlike the orchestrator there is no key-based suppression here, prompt seeding only),
//          dryRounds?: number (default 2), maxRounds?: number (default 3), verifyCap?: number (default 60) }
// COST IS BOUNDED BY CONSTRUCTION: agents <= maxRounds*families (sweep) + verifyCap (verify), so a run cannot
// hit the 1000-agent cap. The `budget` global (a "+NNNm" turn directive) is only an optional early-stop and
// often does NOT propagate into a background workflow — never rely on it. Verify is SEVERITY-GATED: low/cleanup
// hygiene findings are reported RAW (unverified, no subagent); high/medium (or fix-code) get one CROSS-MODEL
// verifier each (codex, retried once on Claude if it errors — same panel discipline as the orchestrator).
// Subagents READ-ONLY; no sui build/test or localnet (watchdog) — the main loop runs the compiler in the
// parent-reconciliation pass (rule-auditor's build/test step).

export const meta = {
  name: 'predict-rule-sweep',
  description: 'Per-rule sweep of the mechanical/local repo rules across the Predict packages (refreshed rule-auditor): sweep -> verify/classify',
  phases: [
    { title: 'Sweep', detail: 'one agent per rule family sweeps every relevant module for that rule' },
    { title: 'Verify', detail: 'severity-gated: refute/classify each high/medium finding; low/cleanup hygiene reported raw' },
  ],
}

const SKILL = '.claude/skills/predict-audit'
let A = args
if (typeof A === 'string') { try { A = JSON.parse(A) } catch (e) { A = {} } }
if (!A || typeof A !== 'object') A = {}
const groundTruth = A.groundTruth || '(none provided)'
// DEPTH preset — same tiers/precedence as the orchestrator (explicit cap args win over the preset).
const DEPTH = { mini: { maxRounds: 1, verifyCap: 0, effort: 'medium' }, low: { maxRounds: 1, verifyCap: 30 }, standard: {}, max: { maxRounds: 5, dryRounds: 3, verifyCap: 100, maxFindings: 16 } }
const depthName = DEPTH[A.depth] ? A.depth : 'standard'
const DP = DEPTH[depthName]
const maxFindings = A.maxFindings || DP.maxFindings || 12
const FILES = Array.isArray(A.files) && A.files.length ? A.files : null
const PRIOR = Array.isArray(A.priorAdjudications) ? A.priorAdjudications : []

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
    rule: 'Public visibility is an API commitment, not secrecy. Expose `public` getters/functions only for values needed by external Move composition, PTB construction, or clear user-facing protocol state. Keep internal protocol composition `public(package)`. Public-read classification (move.md): a `public` read function with no in-repo Move consumer must name its intended consumer class in its doc comment (external composition / PTB construction / devInspect / provenance); zero in-repo callers alone never proves deadness (devInspect and PTB consumers are invisible to grep), but zero callers AND no stated consumer class = unclassified, and the default is delete pre-deploy.',
    focus: 'Every `public fun` and public struct. Flag (a) public surface that only serves internal package composition with no external/PTB/user-facing consumer, and (b) UNCLASSIFIED public reads: zero-caller public read functions whose doc comment names no consumer class — report as classify-or-delete, never as dead; a zero-caller public read WITH a stated consumer class is a documented composability read (non-finding). `public(package)` functions are not part of the frozen upgrade surface — unused/test-only package getters are plain cleanup, never a deploy gate.' },
  { key: 'object-identity-keys', scope: 'packages/predict/sources',
    rule: 'Raw key constructors taking arbitrary object IDs stay package-only; public constructors are exposed through the object that anchors the key (immutable refs where possible). Do not store generic `config_id`/`object_id` fields in config structs or events when object identity already suffices.',
    focus: 'range_codec keys, predict_account `PositionKey`, registry lookup helpers, market_manager `MarketKey`, events, and any object-ID-based constructor.' },
  { key: 'create-and-share-naming', scope: ALL,
    rule: 'A function that creates AND shares a shared object is named `create_and_share*`.',
    focus: 'Every `transfer::share_object`/`public_share` call and any entrypoint that creates+shares (predict markets/managers/vaults; propbook `registry::create_and_share_pyth_feed`/`create_and_share_block_scholes_{spot,forward,svi}_feed`).' },
  { key: 'protocol-config-gates', scope: 'packages/predict/sources',
    rule: 'Public flow functions call the applicable ProtocolConfig gate. Trading pause blocks NEW risk creation (`assert_trading_allowed`); exits, settlement cleanup, and valuation are blocked ONLY by the valuation lock (`assert_not_valuation_in_progress` / valuation-lock lifecycle) unless semantics intentionally change.',
    focus: 'Produce a flow-gate matrix for every external public/entry flow: function | category (risk-creation / exit-cleanup / valuation / oracle-settlement / admin / read-only) | expected gate | actual gate (including gates delegated through callees) | verdict. Risk creation = mint, create_and_share_expiry_market, grow allocation. Exit/cleanup = redeem, shrink allocation, compaction. Record delegated gates before flagging a wrapper.' },
  { key: 'arithmetic-guard-noise', scope: ALL,
    rule: "Do not add explicit overflow/underflow/numeric-cast asserts solely to replace Move's primitive VM aborts (those are free atomic checks). KEEP named assertions for semantic domain bounds, division-by-zero with a meaningful named zero error, solvency/accounting invariants, authorization, lifecycle, gas-bounded iteration, and option/vector/balance assumptions.",
    focus: 'Math/pricing (fixed_math use, predict pricing), strike_payout_tree, expiry_cash, plp allocation math, propbook oracle normalization. Flag ONLY asserts that duplicate a VM overflow/cast abort. The leaf-self-consistency / redundant-caller-guard half of this rule is the ownership walk (R5) — do NOT report it here.' },
  { key: 'test-coverage-rules', scope: ALL,
    rule: "Every REACHABLE source `const E*` error code has >=1 `expected_failure` test naming that abort code (with a trailing guard abort using a DISTINCT code like `abort 999`). A guard behind a `public(package)` helper must be made independently testable (extract the pure precondition into a `public(package)` checker taking scalar inputs and test it directly) — package-internal visibility is not a reason to leave it uncovered. A genuinely structurally-unreachable defense-in-depth code is documented, not given a contrived bypass test (Rule 12). Every non-failure test asserts an output value or state change. Every test calls the function it claims to test. Prefer `assert_eq!`, import constants instead of duplicating, avoid magic numbers.",
    focus: 'All tests/ + every source error constant. Cross-check each REACHABLE `E*` against an `expected_failure`; a `public(package)` guard with no test is a finding (recommend extracting a testable checker), and a structurally-unreachable code with no test is a non-finding if documented. (The predict flow tests are no longer `.move.disabled` — they were re-enabled; do not assume a disabled suite.)' },
  { key: 'timestamp-semantics', scope: 'packages/predict/sources and packages/propbook/sources',
    rule: "Timestamp fields have clear semantics; do not bump a 'last price update' field on unrelated updates (an SVI-param change must not bump a spot timestamp). Distinguish on-chain landing time (`*_timestamp_ms` = `clock.timestamp_ms()`) from source-data time (`*_published_at_us` or similar) in field/getter/event names.",
    focus: 'propbook `pyth_feed` + the 3 BS feeds + oracle_lane, predict pricing freshness checks, events, getter names. (The old in-package `pyth_source`/`market_oracle` were extracted to propbook — check the current feeds.)' },
  { key: 'events-hygiene', scope: ALL,
    rule: "Avoid 'created' events unless a concrete indexer/off-chain discovery need exists. Events are emitted by the module owning the lifecycle/action, AFTER the state transition completes, with semantic field names (`expiry_market_id`, `pool_vault_id`, `pyth_feed_id` — not generic `owner_id`/`object_id`/`config_id`). Embedded helper modules do not emit parent-scoped events.",
    focus: 'Every event struct + `event::emit` across predict events/, propbook events, account_events. Flag created-events without an indexer need, generic id fields, helper modules emitting parent-scoped events, and events emitted before their postcondition.' },
  { key: 'dead-field-liveness', scope: ALL,
    rule: 'Every declared struct field should have BOTH a writer AND a reader on a LIVE (non-test, non-.disabled) path. A WRITE-ONLY field (set/incremented but never read by live logic for a decision/payout/event) or a READ-ONLY mirror (read but never maintained) is an ownership/liveness defect. Canonical bug class to hunt: a field whose sole consumer is removed by a rework, leaving it write-only — e.g. a rebate reserve still accrued but no longer read/paid, silently walling off fees.',
    focus: 'Enumerate EVERY struct field across all four packages. For each, grep its writers and its readers on LIVE paths (exclude tests + .disabled). Flag (a) write-only fields, (b) read-only mirrors, (c) a field whose sole consumer was removed by the oracle/custody/async-LP rework. This is the exhaustive MECHANICAL complement to the ownership-walk R7 contextual catch — list the fields you cleared too, so coverage is provable.' },
  { key: 'signature-shape', scope: ALL,
    rule: 'Function inputs are ordered by role: mutable receiver/state owner first, capability/authority proofs second, other domain/config objects next, primitive domain values and options next, execution context last (`clock: &Clock` second-to-last when present, `ctx: &mut TxContext` always last). Public and package APIs must not put primitive values before object references (private algorithm helpers may keep traversal/key order when more readable). EXCEPTIONS (settled): `&AccumulatorRoot` is execution context and sits in the tail with clock/ctx; `emit_*` helpers in events/ modules may mirror the event struct field order; existing `public` entrypoints are NOT reordered (TS PTB callers break at runtime) — flag only package-only signatures as fix-code. Avoid runs of 3+ same-typed primitives with domain meaning from one state owner — pass the owner or a named summary. Name accessors so receiver syntax works naturally (`fun sigma(params: &SVIParams)` not `get_sigma`); never rename an existing public API just for receiver style.',
    focus: 'Every public and public(package) fun signature across all four packages. Flag: role-order violations (primitives before objects, misplaced clock/ctx), 3+ same-typed primitive runs, and `get_`-prefixed or unnaturally-named accessors that defeat receiver syntax. IMPORTANT: reordering a Move signature silently breaks positional TypeScript PTB callers (scripts/, packages/predict/harness/ts, packages/predict/simulations) at runtime, not compile time — every reorder recommendation must name the TS surfaces to grep.' },
  { key: 'module-layout', scope: ALL,
    rule: 'Within a module: `public fun` first, then `public(package) fun`, then private `fun`; within each visibility group, read-only/query functions before mutating ones; private helpers placed after their first caller when that does not break the visibility grouping. EXCEPTIONS (settled): `init` AND its init-only private helpers come early (after struct definitions); constant-like `macro fun`s (no parameters, literal/derived-constant bodies) live in the constants section near the top and are exempt from visibility-group ordering. Every Predict-cluster source file starts with the Mysten copyright/SPDX header and has a module-level `///` doc immediately before `module`. Error constants are `EPascalCase`, regular constants `ALL_CAPS`, capabilities suffixed `Cap`, events named in past tense.',
    focus: 'Every module in all four packages: visibility-group ordering, header + module-doc presence, and naming-convention conformance. Group multiple ordering violations within one module into ONE finding per module; cite the out-of-place functions by name.' },
  { key: 'comment-hygiene', scope: ALL,
    rule: 'Comments are opt-in: they state what the code cannot (invariants, units/scaling, custody/ownership, sequencing, lifecycle, non-obvious math or gas tradeoffs) and never restate a name or narrate the next line — a comment whose deletion loses nothing should be deleted. Comments must match the code they describe: math comments name the semantics of the actual function called (`a * b / c` for mul_div_round_down, `ceil(a * b / c)` for mul_div_round_up; no invented two-step forms), and stale comments contradicting behavior are worse than missing ones. All `public fun` / `public macro fun` APIs have doc comments; admin-tunable config structs document every stored field; plain package-only getters and thin shims need none, and (settled) trivial public field getters grouped under a getters header need no per-function docs when the struct and its fields are documented.',
    focus: 'Sweep all four packages for: narrating/restating comments (delete candidates), stale comments contradicting adjacent code, math comments that mismatch the called function or its rounding direction, missing module-level docs or public-API docs, and undocumented admin-tunable config-struct fields. Quote the exact offending comment text in each finding.' },
  { key: 'test-independence', scope: 'all four packages tests/**',
    rule: 'Expected values in tests are INDEPENDENT of the implementation under test (unit-tests Rule 1): never computed by calling contract functions, source helpers, or re-implementing the production formula inline. Golden snapshots asserting the contract own current output are change-detectors, not correctness oracles — the assertion target must be the independently-derived value with provenance (hand math in a comment, committed generator, checked-in reference data). Approximation bounds derive from documented precision or principled numerics, NEVER measured from current contract output. No approximate/range assertions outside the fixed-point carve-out (`test_helpers::assert_within` with a principled bound).',
    focus: 'Every assert_eq!/assert! comparing contract output, across all test files. Flag: (a) expected values computed via source functions or an inline copy of the production formula, (b) snapshot-style expected constants with no provenance comment, or whose comment admits mirroring contract output, (c) tolerance/range assertions with an unprincipled or measured-from-output bound, (d) reference constants contradicting their own provenance comment. Cite the constant and its provenance or lack. Canonical bug class: math_tests asserting LN_2 = ...180 (contract output) instead of the true ...181.' },
  { key: 'docs-drift', scope: 'packages/predict/docs/**, packages/predict/predeploy/*.md (not stress/ logs), packages/{predict,propbook,account}/README.md and other committed package prose',
    rule: 'Committed prose matches HEAD code: every Move identifier (module, function, struct, error constant, event, config field) named in the docs resolves at HEAD with the described signature and behavior; described flows, gate sequences, units/scaling, and invariants match the current implementation. Docs clearly labeled historical/superseded are exempt.',
    focus: 'Read each doc file, extract every code identifier and load-bearing behavioral claim, then grep/read the source to verify. Flag: identifiers that no longer resolve (renamed or removed), signatures/flows described differently than HEAD, missing new gates or removed steps still described, and stale economic vocabulary vs docs/glossary.md. Recent renames to check explicitly: create_and_share_expiry_market, create_and_share_builder_code, set_template_cadence_config.' },
  { key: 'abort-code-multiplexing', scope: ALL,
    rule: 'One error code per distinct failure condition: an E constant asserted at multiple sites is conformant only when every site checks the SAME semantic predicate. Two different predicates under one code hide which condition failed; error-code meanings freeze at deploy, so pre-deploy splitting (with contiguous renumbering) is free. Precedent: EInvalidMarketTickSize was split into grid-validity vs the EMarketTickSizeTooLarge overflow ceiling.',
    focus: 'For every E constant in all four packages, enumerate its assert!/abort sites and compare predicates. Flag constants guarding two or more semantically distinct conditions (different fields, different bounds, different failure stories). A multi-site constant with ONE predicate (the same check on set + create paths) is a non-finding. Recommend the narrowest split.' },
]

const wantRules = Array.isArray(A.rules) ? A.rules : null
// Scope is REQUIRED. The old no-arg fall-through swept every family — the most expensive shape as the
// accident default. An explicit rules:'all' is the deliberate opt-in for the full sweep.
if (!(wantRules && wantRules.length) && A.rules !== 'all') {
  log('⚠ no scope given — pass rules: [<keys>] or rules: "all"; the whole-sweep no-arg default was removed')
  return { error: 'scope_required', valid_keys: RULE_FAMILIES.map(r => r.key) }
}
const FAMILIES = wantRules && wantRules.length ? RULE_FAMILIES.filter(r => wantRules.indexOf(r.key) >= 0) : RULE_FAMILIES
const unknown = wantRules ? wantRules.filter(k => !RULE_FAMILIES.some(r => r.key === k)) : []
log(`rule-sweep config — rules: ${wantRules ? wantRules.join(',') : `ALL ${RULE_FAMILIES.length}`} | depth: ${depthName} | maxFindings/rule: ${maxFindings}`
  + (FILES ? ` | DELTA files: ${FILES.length}` : '') + (PRIOR.length ? ` | prior adjudications: ${PRIOR.length}` : '')
  + ` | groundTruth: ${String(groundTruth).slice(0, 60)}`
  + (unknown.length ? ` | ⚠ UNKNOWN RULE KEYS IGNORED: ${unknown.join(',')} (valid: ${RULE_FAMILIES.map(r => r.key).join(',')})` : ''))
if (!A.groundTruth || String(A.groundTruth).length < 40) {
  log('⚠ groundTruth is missing or suspiciously short — confirm Step 1 (build/test in the MAIN loop) actually ran; a false "all green" poisons the sweep')
}
if (wantRules && !FAMILIES.length) {
  log('⚠ rule filter matched nothing — aborting')
  return { error: 'no_rules_matched', requested: wantRules, valid_keys: RULE_FAMILIES.map(r => r.key) }
}

const PRELUDE = `You are an agent in the Predict RULE SWEEP — a per-rule conformance audit of the MECHANICAL repo rules. FIRST read:
  1. ${SKILL}/primer.md  (current module map, scope, prior-awareness, report format)
  2. the source rules: .claude/rules/move.md, .claude/rules/code-review.md, .claude/rules/unit-tests.md, and AGENTS.md "Settled design decisions".
Conflict order: most-specific Predict rule in AGENTS.md, then committed predeploy policy (rounding-policy + response-policies RP-*) / open items, then .claude/rules/*.md, then general guidance. Be prior-aware: a candidate matching an AGENTS settled decision or committed predeploy policy/open item is a non-finding (tag it). Do not use local ignored design scratch as authority for audit triage. The .claude/predict-review map is STALE — trust primer.md + the current tree. Read-only on source; do NOT run sui build/test or localnet (the watchdog kills subagents — the main loop runs the compiler in reconciliation). Your job is ONE rule only; do not report other rules' violations or the ownership-walk's R1-R7.`

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
const DRY_TARGET = A.dryRounds || DP.dryRounds || 2
const MAX_ROUNDS = A.maxRounds || DP.maxRounds || 3
// typeof-check, not ||: mini's verifyCap 0 is falsy and must not fall through to the default.
const VERIFY_CAP = [A.verifyCap, DP.verifyCap, 60].find(v => typeof v === 'number')
const RESERVE = (budget && budget.total) ? Math.max(3_000_000, Math.floor(budget.total * 0.3)) : 3_000_000
function budgetLeft() { return budget && typeof budget.remaining === 'function' ? budget.remaining() : Infinity }
// strip line numbers (so a shifted-line same violation dedups) but KEEP a claim digest, so two DISTINCT
// violations of the same rule in the same file stay distinct and the 2nd is not silently dropped.
function fkey(f) { return `${f.rule_family}|${(f.location || '').toLowerCase().replace(/:[0-9][0-9,\- ]*/g, '').replace(/[^a-z0-9/._;]/g, '')}|${(f.claim || '').toLowerCase().replace(/[^a-z0-9]+/g, '').slice(0, 50)}`.slice(0, 220) }
const priorBlock = PRIOR.length
  ? `ADJUDICATED IN PREVIOUS RUNS (already confirmed/refuted/settled over unchanged code — do NOT re-report):\n${PRIOR.map(p => `- [${p.status}] ${p.title || p.claim || ''} @ ${p.location}${p.note ? ` — ${p.note}` : ''}`).join('\n')}\n\n`
  : ''
const focusBlock = FILES
  ? `DELTA SCOPE — this sweep targets a change set. CONCENTRATE on rule sites in/around these changed files (plus their direct callers); treat the rest as context:\n${FILES.map(f => `- ${f}`).join('\n')}\n\n`
  : ''
function sweepPrompt(rf, round, known) {
  return `${PRELUDE}\n\n=== RULE FAMILY: ${rf.key} (round ${round}) ===\nRULE: ${rf.rule}\nSCOPE: ${rf.scope}\nWHERE TO LOOK: ${rf.focus}\n\n${focusBlock}${priorBlock}`
    + (known ? `ALREADY-FOUND violations of this rule (do NOT re-report — find DIFFERENT ones, in modules/branches not yet covered):\n${known}\n\n` : '')
    + `Inspect every relevant module/function/branch/test for THIS rule across the scope. Report each violation with file:line, the rule text it breaks, a SEVERITY (high only if it can strand funds / brick a flow / misprice an indexer — e.g. a write-only field; most hygiene is cleanup/low), context, whether it is a defensible exception (yes/no/unclear), the recommended action (fix-code / update-rule / design-decision / false-positive), and the smallest fix or narrowest rule exception. Per the calibration principle, a defensible recurring pattern is an update-rule candidate, not many repeat findings. Keep each finding CONCISE — claim and recommendation ≤2 sentences each, context ≤1 line; a verbose response risks truncating the structured output. Cap at your ${maxFindings} highest-value NEW findings.`
}

phase('Sweep')
const seen = new Set()
const candidates = []
const coverageByFamily = {}
// PER-FAMILY retirement (ported from the orchestrator's per-lane trim): a family that produces no NEW
// finding for DRY_TARGET consecutive rounds retires, so later rounds only re-run families still surfacing
// issues. An ERRORED family (null result) is neither advanced nor reset — it retries next round.
const dryByFamily = {}
FAMILIES.forEach(rf => { dryByFamily[rf.key] = 0 })
let round = 0
while (round < MAX_ROUNDS && budgetLeft() > RESERVE) {
  const activeFamilies = FAMILIES.filter(rf => dryByFamily[rf.key] < DRY_TARGET)
  if (!activeFamilies.length) break
  round++
  const knownByFamily = {}
  candidates.forEach(f => { (knownByFamily[f.rule_family] = knownByFamily[f.rule_family] || []).push(`- ${f.location}: ${(f.claim || '').slice(0, 120)}`) })
  const roundRes = await parallel(activeFamilies.map(rf => () => agent(sweepPrompt(rf, round, (knownByFamily[rf.key] || []).join('\n')),
    { schema: SWEEP_SCHEMA, effort: DP.effort || 'high', phase: 'Sweep', label: `sweep:${rf.key}:r${round}` })))
  const freshByFamily = {}
  // Index by the family we DISPATCHED (activeFamilies[i]), not the agent-returned r.rule_family — parallel()
  // preserves order and the dispatched key is the stable identity (same fix as the orchestrator's lanes).
  roundRes.forEach((r, i) => {
    if (!r) return
    const famKey = activeFamilies[i].key
    if (r.coverage) coverageByFamily[famKey] = r.coverage
    ;(r.findings || []).forEach(f => {
      const ff = { ...f, rule_family: famKey }
      const k = fkey(ff)
      if (!seen.has(k)) { seen.add(k); candidates.push(ff); freshByFamily[famKey] = (freshByFamily[famKey] || 0) + 1 }
    })
  })
  activeFamilies.forEach((rf, i) => { if (!roundRes[i]) return; if ((freshByFamily[rf.key] || 0) === 0) dryByFamily[rf.key]++; else dryByFamily[rf.key] = 0 })
  const freshCount = Object.values(freshByFamily).reduce((a, b) => a + b, 0)
  const retired = FAMILIES.filter(rf => dryByFamily[rf.key] >= DRY_TARGET).length
  log(`Sweep round ${round}: ran ${activeFamilies.length} famil(ies), +${freshCount} new (total ${candidates.length}) | ${retired}/${FAMILIES.length} retired | budget ${budgetLeft() === Infinity ? '∞' : Math.round(budgetLeft() / 1e6) + 'M'} left`)
}
log(`Sweep converged after ${round} rounds: ${candidates.length} unique candidate findings (${FAMILIES.filter(rf => dryByFamily[rf.key] >= DRY_TARGET).length}/${FAMILIES.length} families retired)`)

// SEVERITY-GATED + CAPPED: only high/medium (or fix-code) findings get a verifier; low/cleanup hygiene is
// reported RAW (unverified). Capped at VERIFY_CAP by severity so the agent count stays bounded.
phase('Verify')
const sevRankF = { high: 4, medium: 3, low: 2, cleanup: 1 }
const effSev = f => f.severity || (f.classification === 'fix-code' ? 'medium' : 'low')
const ruleShouldVerify = f => { const s = effSev(f); return s === 'high' || s === 'medium' }
const verifyAll = candidates.filter(ruleShouldVerify).sort((a, b) => (sevRankF[effSev(b)] || 0) - (sevRankF[effSev(a)] || 0))
const toVerify = verifyAll.slice(0, VERIFY_CAP)
const verifyOverflow = verifyAll.slice(VERIFY_CAP)   // beyond the cap -> reported unverified (logged, never silently dropped)
const unverifiedF = candidates.filter(f => !ruleShouldVerify(f)).concat(verifyOverflow)
if (verifyOverflow.length) log(`Verify cap ${VERIFY_CAP} hit: ${verifyOverflow.length} finding(s) reported UNVERIFIED — raise verifyCap to verify them all`)
// CROSS-MODEL verify (ported from the orchestrator): the verifier runs on codex — a different model than the
// Claude sweeper — and a null verdict (codex absent, StructuredOutput flake) is retried ONCE on Claude.
const CODEX = 'codex:codex-rescue'
async function verdictAgent(prompt, label) {
  const base = { schema: VERDICT_SCHEMA, effort: 'high', phase: 'Verify' }
  let v = await agent(prompt, { ...base, label, agentType: CODEX })
  if (!v) v = await agent(prompt, { ...base, label: `${label}:retry` })
  return v
}
const verifiedRaw = (await parallel(toVerify.map((f, fi) => () => verdictAgent(
  `${PRELUDE}\n\nADVERSARIALLY VERIFY this single rule-sweep finding (rule family ${f.rule_family}). Read the cited code; decide: confirmed (real violation) / refuted (not a violation, or the claim is wrong) / settled (matches AGENTS or committed predeploy policy/open item — cite it). Then classify: fix-code / update-rule (defensible → narrowest exception) / design-decision / false-positive. Be skeptical; mechanical rules have many intentional exceptions (deliberately retained getters, public APIs needed for PTBs, disabled test suites).\n\nFINDING:\n${JSON.stringify(f, null, 2)}`,
  `verify:${f.rule_family}:${fi}`)
  .then(verdict => ({ ...f, verdict }))))).filter(Boolean)
// A finding whose verifier died even after the retry is reported UNVERIFIED — the pre-port code let it
// vanish from every output bucket (a silent drop the consolidator's accounting could not see).
const verdictDead = verifiedRaw.filter(x => !x.verdict)
if (verdictDead.length) log(`⚠ ${verdictDead.length} finding(s) lost their verifier even after retry — reported unverified, not dropped`)
const all = verifiedRaw.filter(x => x.verdict)
const confirmed = all.filter(x => x.verdict.verdict === 'confirmed')
const settledOut = all.filter(x => x.verdict.verdict === 'settled')
const refutedOut = all.filter(x => x.verdict.verdict === 'refuted')
log(`Rule families: ${FAMILIES.length} | rounds: ${round} | findings: ${all.length} | confirmed: ${confirmed.length} | settled: ${settledOut.length} | refuted: ${refutedOut.length} | verifier-dead: ${verdictDead.length}`)

function shape(x) {
  return { rule_family: x.rule_family, severity: x.severity || (x.classification === 'fix-code' ? 'medium' : 'low'), location: x.location, claim: x.claim, classification: (x.verdict && x.verdict.classification) || x.classification, recommendation: x.recommendation, evidence: x.verdict && x.verdict.evidence }
}
return {
  summary: { rule_families: FAMILIES.length, rounds: round, findings: all.length, confirmed: confirmed.length, settled: settledOut.length, refuted: refutedOut.length, unverified: unverifiedF.length + verdictDead.length, verifier_dead: verdictDead.length },
  coverage: Object.keys(coverageByFamily).map(rf => ({ lane: rf, coverage: coverageByFamily[rf] })),
  confirmed: confirmed.map(shape),
  settled: settledOut.map(shape),
  refuted: refutedOut.map(x => ({ rule_family: x.rule_family, location: x.location, claim: x.claim, why: x.verdict && x.verdict.reasoning })),
  unverified: unverifiedF.map(x => ({ rule_family: x.rule_family, severity: effSev(x), location: x.location, claim: x.claim, classification: x.classification, recommendation: x.recommendation, status: 'unverified' }))
    .concat(verdictDead.map(x => ({ rule_family: x.rule_family, severity: effSev(x), location: x.location, claim: x.claim, classification: x.classification, recommendation: x.recommendation, status: 'unverified-panel' }))),
}
