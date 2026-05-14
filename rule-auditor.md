# Predict Rule Auditor

> **For agentic auditors:** Run this as a read-only, parallel audit before making code or rule changes. Each background agent owns exactly one rule family and must audit every relevant Predict module, function, flow, and branch for that rule only.

**Goal:** Identify every place in `packages/predict` that violates the repo rules in `AGENTS.md`, `CLAUDE.md`, and `.claude/rules/*.md`, then classify each finding as a code fix, a defensible exception that needs a rule update, a false positive, or a design decision.

**Architecture:** Use one focused read-only explorer per independent rule family. The parent agent coordinates, deduplicates, verifies reported evidence, and decides whether each issue should be fixed or used to calibrate the rules.

**Scope:** `packages/predict/sources/**/*.move`, `packages/predict/tests/**/*.move`, `packages/predict/Move.toml`, and Predict-specific docs when they define intended behavior.

---

## Source Rules

Auditors must read these files before reporting:

- `AGENTS.md`
- `CLAUDE.md`
- `.claude/rules/move.md`
- `.claude/rules/code-review.md`
- `.claude/rules/unit-tests.md`

When a rule conflict appears, prefer the most specific Predict rule in `AGENTS.md`, then `.claude/rules/*.md`, then general guidance.

## Audit Method

Each background agent must:

1. Read the source rule files listed above.
2. Read every relevant file under `packages/predict`.
3. For its assigned rule family, inspect every module, public function, package function, private helper, branch, state transition, and test path that can affect the rule.
4. Report only violations for that one rule family.
5. Include file and line references for every finding.
6. Distinguish hard violations from defensible exceptions.
7. Suggest whether the next action is a code fix, a rule update, or a design review.

Agents must not edit files during the audit.

## Output Format

Each agent returns:

```markdown
## Rule Family
<one sentence naming the audited rule>

## Coverage
- Files inspected:
- Functions/flows inspected:
- Search commands or traversal method:

## Findings

### Finding N: <short title>
- File: `<path>:<line>`
- Rule text:
- Why this appears to violate the rule:
- Context:
- Defensible? `yes` / `no` / `unclear`
- Recommended next action: `fix code` / `update rule` / `design decision` / `false positive`
- Suggested fix or rule calibration:

## Non-Findings Worth Noting
- <important places checked that comply, especially likely false positives>

## Residual Risk
- <anything the agent could not fully prove>
```

## Rule Families And Agent Assignments

### Agent 1: Admin-Tunable Config Runtime Reads

Audit the rule:

- Admin-tunable values live in config structs.
- `config_constants.move` contains two kinds of values in one place for readability:
  admin-tunable initialization defaults and upgrade-required bounds.
- App-layer protocol logic must not read admin-tunable defaults directly.
- App-layer protocol logic may read `min_*` and `max_*` bounds directly when the bound is intentionally serving as an upgrade-required runtime hard cap or floor.
- Runtime logic should read current values from the relevant config object and treat them as plain numbers.
- Do not add config struct fields or getters for upgrade-required bounds just to avoid a direct constant read.

Focus on every use of `config_constants::*` outside config construction, setters, bounds checks, and tests. Flag default reads in runtime logic as violations. For bound reads, classify as a violation only when the code is accidentally bypassing an admin-tunable current value; classify as non-finding when the bound is being used as an upgrade-required runtime envelope.

### Agent 2: Config API Shape And Admin Routing

Audit the rule:

- External admin entrypoints live in `registry`.
- Config struct setters stay `public(package)`.
- Constructors, setters, bounds checks, and template/snapshot wiring stay `public(package)`.
- Global-template setters must include `template` when they affect future objects but not existing objects.
- Per-market oracle bounds may be tunable by `MarketOracleCap`.

Focus on all config modules, `protocol_config`, `registry`, and `market_oracle`.

### Agent 3: Public API Exposure

Audit the rule:

- Public visibility is an API commitment.
- Expose public getters only for external Move composition, PTB construction, or clear user-facing protocol state.
- Keep internal protocol composition `public(package)` where possible.

Focus on all `public fun` and public structs in Predict.

### Agent 4: Raw Key Constructors And Object Identity

Audit the rule:

- Raw key constructors that take arbitrary object IDs should stay package-only.
- Public constructors should be exposed through the object that anchors the key, using immutable references when possible.
- Do not store generic `config_id` fields in config structs or events; object identity is enough.

Focus on `RangeKey`, manager keys, registry lookup helpers, events, and any object-ID based constructor.

### Agent 5: Shared Object Creation Naming

Audit the rule:

- Functions that create and share a shared object should be named `create_and_share`.

Focus on all calls to `transfer::share_object`, `public_share`, `share`, and any entrypoint that creates shared objects.

### Agent 6: Flow Validation Ownership

Audit the rule:

- Every assertion must have one clear owner: the module/function whose contract depends on that fact.
- State-owning modules expose factual queries and assertions about their own state when a flow needs those facts.
- Flow modules compose those facts into flow policy, including flow gates, authorization, object binding, branch/lifecycle policy, and static creation inputs.
- Do not reconstruct another module's derived facts in a caller when the state owner can expose the fact cleanly.
- Do not preflight another module's local leaf preconditions just to avoid a later abort.
- Prefer atomic fact helpers for reusable facts.
- Use flow validation helpers only when they remove real duplication or clarify a complex branch.

Focus on cross-module validation in `expiry_market`, `pricing`, `market_oracle`, `plp`, `predict_manager`, and `registry`.

### Agent 7: ProtocolConfig Gates And Pause Semantics

Audit the rule:

- Public flow functions should call the applicable `ProtocolConfig` gate.
- `ProtocolConfig` owns global gates such as trading pause and valuation lock.
- Trading pause blocks new risk creation.
- Exits, settlement cleanup, and valuation should only be blocked by valuation lock unless semantics intentionally change.

Focus on every public flow and admin mutation.

Agent 7 must produce a flow-gate matrix for every external public or entry flow:

- Function
- Flow category
- Expected gate
- Actual gate, including delegated gates through callees
- Verdict

Classification guidance:

- Risk creation includes minting positions, creating active expiry markets, and growing active allocation. Expected gate: `assert_trading_allowed`.
- Exit/cleanup includes redeem, shrinking allocation, and compaction. Expected gate: `assert_not_valuation_in_progress`.
- Valuation includes starting, reading, or completing pool valuation. Expected gate: valuation-lock lifecycle or `assert_valuation_in_progress`.
- Oracle update/settlement and admin config mutation are valuation-sensitive but not trading-pause-sensitive. Expected gate: `assert_not_valuation_in_progress`, plus authorization where applicable.
- Read-only flows, pure helper APIs, setup flows, cap management, and manager deposit/withdraw/share flows do not need a `ProtocolConfig` gate unless they touch valuation-sensitive state or create protocol risk.
- Registry/admin wrappers may delegate the actual gate to a `ProtocolConfig` setter or callee. Record the delegated gate before flagging a wrapper.

### Agent 8: Validate Before Mutate

Audit the rule:

- Before a function mutates state owned by one module, it must first validate mutation-independent facts that function owns: flow gates, authorization, object binding, branch policy, lifecycle policy, static creation inputs, and other facts that decide whether this function is allowed to start the state transition.
- Do not preflight another module's local leaf preconditions just to avoid a later abort. Preflight another module's fact only when this function must know that fact before it mutates a different state owner.
- If a quote, liability, or accounting value intentionally depends on post-mutation state, mutation-before-calculation is allowed only when mutation-independent flow facts have already been checked and the post-state dependency is obvious from the code or a short comment.
- Creation flows must validate known static creation inputs before mutating pool allocation, balance, registry, or newly shared object state.
- Compaction or destructive state transitions must prove liability and solvency facts before consuming dense state or replacing it with compacted state.
- Keep local arithmetic, accounting, and data-structure guards inline near the operation they protect.
- Validate before consuming irreversible resources.

Focus on all state-changing flows, especially mint, redeem, compaction, allocation resize, manager deposits/withdrawals, oracle updates, and fee accrual.

### Agent 9: Arithmetic And Semantic Guards

Audit the rule:

- Do not add explicit overflow, underflow, or numeric-cast asserts solely to replace Move's primitive VM aborts.
- Keep named assertions for semantic domain bounds, division by zero when the module has a meaningful named zero error, solvency/accounting invariants, authorization, lifecycle, gas-bounded iteration, and option/vector/balance assumptions.
- Leaf primitives in `public(package)` data structures should be self-consistent for the domain facts they own regardless of caller validation.
- Avoid duplicate caller guards that only repeat a leaf semantic guard unless they provide a genuinely different business precondition.

Focus on math helpers, pricing, strike matrix, fee reserve, manager balances, PLP allocation math, oracle normalization, and expiry cash movement.

### Agent 10: Test Rule Coverage

Audit the rule:

- Every `const E*` error code needs at least one `expected_failure` test.
- Every non-failure test must assert output values or state changes.
- Every test must call the function it claims to test.
- Tests should use `assert_eq!` where possible, import constants instead of duplicating them, avoid magic numbers in test bodies, and cover edge cases.
- Shared-object tests should use scenario-driven setup and IDs for shared objects.

Focus on all Predict tests and every source error constant.

### Agent 11: Timestamp And Source-Time Semantics

Audit the rule:

- Timestamp fields must have clear semantics.
- Do not bump a timestamp field on unrelated updates.
- Distinguish on-chain landing time from source-data time in field names.
- Use `*_timestamp_ms` for `clock.timestamp_ms()` values and explicit source phrases such as `*_published_at_us` for payload timestamps.

Focus on Pyth source, Lazer helper, market oracle, pricing freshness, events, and getter names.

### Agent 12: Events And Created Event Avoidance

Audit the rule:

- Avoid created events unless there is a concrete indexer or off-chain discovery requirement.
- Events should not store generic `config_id` fields where object identity already suffices.

Focus on every event struct and `event::emit` call.

## Parent Reconciliation Pass

After agents return, the parent agent must:

1. Deduplicate overlapping findings.
2. Re-read the reported code in context.
3. Classify each finding:
   - `Fix code`
   - `Update rule`
   - `Design decision`
   - `False positive`
4. For `Fix code`, identify the smallest code change and required tests.
5. For `Update rule`, draft exact replacement or exception text for `AGENTS.md` or `.claude/rules/*.md`.
6. Run:
   - `sui move build --path packages/predict`
   - `sui move test --path packages/predict --gas-limit 100000000000`

## Calibration Principle

Rules should remain strict enough to catch real protocol risk, but precise enough that auditors do not repeatedly flag intentional architecture. If a violation is defensible, update the rule with the narrowest exception and the rationale.
