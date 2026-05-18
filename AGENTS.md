# DeepBook V3 Agent Guide

This file is the repo-level entry point for coding agents working in `deepbookv3`.

## Start Here

- Read [`CLAUDE.md`](/Users/aslantashtanov/Desktop/Projects/deepbookv3/CLAUDE.md) first.
- Treat `.claude/rules/*.md` as the source of truth for file-type-specific guidance.
- Keep changes scoped. This repo mixes Move contracts, Rust services, and TypeScript scripts.

## Repo Layout

- `packages/` contains Sui Move packages:
  - `deepbook/` is the core protocol.
  - `predict/` is the prediction-market package built on top of DeepBook patterns.
  - `deepbook_margin/`, `margin_trading/`, `margin_liquidation/`, `token/`, `dbtc/`, `dusdc/` are supporting packages.
- `crates/` contains Rust services:
  - `server/`, `indexer/`, `schema/`
- `scripts/` contains TypeScript transaction and ops scripts.
- `.claude/rules/` contains repo-specific coding, testing, and review guidance.

## Auto-Loaded Rule Files

These are the most important rule files to consult based on the code you touch:

- `.claude/rules/move.md` for `packages/**/*.move`
- `.claude/rules/unit-tests.md` for `packages/**/tests/**`
- `.claude/rules/code-review.md` when reviewing Move changes
- `.claude/rules/indexer.md` for `crates/server/**`, `crates/indexer/**`, `crates/schema/**`
- `.claude/rules/scripts.md` for `scripts/**`

## Common Commands

### Move

- Build all Move packages:
  - `sui move build`
- Build a specific package:
  - `sui move build --path packages/predict`
  - `sui move build --path packages/deepbook`
- Run all tests for a package:
  - `sui move test --path packages/predict --gas-limit 100000000000`
  - `sui move test --path packages/deepbook --gas-limit 100000000000`
- Format Move code:
  - `bunx prettier-move -c *.move --write`

### Rust

- Build server:
  - `cargo build -p deepbook-server`
- Test server:
  - `cargo test -p deepbook-server`

### JavaScript / TypeScript

- Lint:
  - `pnpm run lint`
- Format:
  - `pnpm run prettier:fix`

## Working Norms

- Prefer narrow tests over broad changes. Most bugs here are boundary-condition bugs.
- For Move work, run the smallest relevant package test suite before expanding scope.
- For protocol changes, add or update unit tests in the package you touched.
- For complex unit tests, follow the existing style in core DeepBook tests:
  - short scenario comments above the test
  - inline arithmetic comments when expected values are not obvious
- Do not assume generated fixtures are authoritative if the on-chain integer math differs; test the contract behavior directly when needed.

## Predict Package Notes

- `packages/predict/tests/generated_tests/` contains generated fixture-based tests.
- Hand-written protocol behavior tests live in:
  - `packages/predict/tests/predict_tests.move`
  - `packages/predict/tests/vault/vault_tests.move`
  - related helper and manager test files under `packages/predict/tests/`
- If you change predict pricing, vault accounting, or oracle math, rerun the full predict suite:
  - `sui move test --path packages/predict --gas-limit 100000000000`
- Predict comment rules:
  - Comments are opt-in, not a coverage requirement. Do not add comments just because a function, branch, or field exists.
  - Every Predict Move source file must start with the standard Mysten copyright and SPDX header.
  - Every Predict Move module needs a module-level `///` doc immediately before `module`.
  - Module docs should usually be 1-4 sentences and explain what state or types the module owns, what flows it is responsible for, and what it intentionally does not own when the boundary is easy to confuse.
  - Longer module docs are appropriate for algorithmic or data-structure-heavy modules such as pricing, math, and strike exposure index code.
  - All `public fun` and `public macro fun` external APIs should have doc comments because they are protocol API surface.
  - `#[test_only]` helpers do not need public API docs unless their setup behavior is non-obvious.
  - `public(package) fun` comments should be used for cross-module flows, non-obvious mutations, constructors/destructors that establish ownership, witness or hot-potato functions, invariant boundaries, or sequencing-sensitive helpers.
  - Plain package-only config getters/setters and thin constructor shims do not need doc comments when names and module docs already make the behavior clear.
  - Private `fun` comments should be rare and limited to algorithms, formulas, invariants, gas/storage tradeoffs, or non-obvious sequencing.
  - Public structs should have doc comments. Admin-tunable config structs should usually document every stored field because those fields encode protocol policy, units, and economic meaning.
  - Non-config struct fields should be commented selectively: mappings, balances/custody, timestamps, lifecycle markers, sentinel/state fields, and fields with non-obvious units or invariants. Do not comment simple IDs, counters, or private bookkeeping fields when the module/struct docs and field names are enough.
  - A struct-level doc can cover a group of obvious fields that share one convention; do not duplicate that same sentence above every field.
  - Inline comments should explain why, not what. Good targets are compaction sequencing, valuation freshness assumptions, storage/gas tradeoffs, simulator/localnet stubs, external package quirks, and post-mutation accounting dependencies.
  - Do not write comments that restate the function name, narrate obvious code, explain Move syntax, describe simple assignments, or repeat names already clear from types.
  - If deleting a comment would not make the code harder to use or safely modify, delete it.
  - When changing behavior, update nearby comments in the same edit. Stale comments are worse than missing comments.
- Predict config rules:
  - Split config into two classes: admin-tunable values and upgrade-required values.
  - Admin-tunable values live in config structs and are updated only through admin-gated entrypoints.
  - Upgrade-required values stay as constants/macros and do not get config structs, setters, bounds, or admin flows.
  - Each admin-tunable value should have a stored field plus package-only `default_*` and `assert_*` helpers in `config_constants.move`.
  - For admin-tunable values, `config_constants.move` is only for config construction and config update validation. App-layer protocol logic must not read admin-tunable defaults directly; it should read the current value from the relevant config object.
  - `min_*` and `max_*` bounds in `config_constants.move` are upgrade-required constants colocated with defaults for readability. They define the admin-tunable validation envelope and may also be read directly by runtime logic when intentionally serving as an upgrade-required hard cap or floor. Do not add config fields or getters for these bounds.
  - Upgrade-required values are read directly from constants/macros by the app logic that needs them. Do not hide upgrade-only constants behind config struct getters.
  - For admin-tunable values, defaults seed initial config state while config structs hold the current protocol value. Runtime logic should treat config fields as plain numbers and should not read the defaults that produced them.
  - Each `assert_*` helper should use a specific error code for that config value.
  - Defaults are applied in the module that creates the config/object.
  - Global template config can be snapshotted into per-object state at creation; existing objects should only change through an explicit admin path if one is intentionally added.
  - Name global-template setters with `template` when the value affects future objects but not existing objects.
  - External admin entrypoints live in the admin/router module, currently `registry`; config struct setters stay `public(package)`.
  - Single-value bounds live in `config_constants::assert_*`; relational checks that depend on multiple fields live in the owning config setter.
  - Do not store generic `config_id` fields inside config structs or events; object identity is enough when identity matters.
  - Do not add singleton creation flags for objects created during package init.
  - Per-market oracle bounds can be tunable by `MarketOracleCap`; this is an intentional per-oracle operator control, not a generic admin config path.
  - Public visibility is an API commitment, not secrecy; on-chain state is still observable.
  - Keep admin-tunable config structs readable inside the package by default.
  - Expose public getters only for values needed by external Move composition, PTB construction, or clear user-facing protocol state.
  - Keep config constructors, setters, bounds checks, and template/snapshot wiring `public(package)`.
- Predict naming and API rules:
  - Functions that create and share a shared object should be named `create_and_share`.
  - Pyth Lazer feed IDs should use `u32` consistently across Predict.
  - Avoid created events unless there is a concrete indexer or off-chain discovery requirement.
  - Events should be emitted by the module that owns the lifecycle/action being reported.
  - Event fields should use semantic names from the event domain. Prefer `expiry_market_id`, `pool_vault_id`, or `market_oracle_id` over generic names like `owner_id`, `object_id`, or `config_id`.
  - Do not thread IDs through unrelated leaf/helper modules only to provide event context.
  - Embedded accounting/helper modules should not emit parent-scoped events unless the parent identity is part of their own domain model. If a parent-scoped event needs helper-computed amounts, have the helper return a summary and emit the event in the parent/action module.
  - Do not call `object::id(&obj)` or `object::id(obj)` at use sites when the object's module can expose an ID getter. Prefer receiver syntax such as `market.id()`, `vault.id()`, or a type-specific getter like `cap.cap_id()`.
  - Raw key constructors that take arbitrary object IDs should stay package-only; expose public constructors through the object that anchors the key, using immutable references when possible.
  - Prefer native/framework helpers with receiver syntax when available and readable, especially for standard containers such as `Option`, `Table`, and `vector`. For example, use `opt.borrow()`, `opt.borrow_mut()`, `opt.extract()`, and `table.borrow_mut(key)` instead of module-style calls when the receiver is clear.
  - Prefer receiver syntax when a Move function's first parameter is the owning type and the caller has a named local/reference. Name accessors and helpers naturally so receiver syntax works directly, e.g. `fun sigma(params: &SVIParams)` so callers use `params.sigma()`.
  - Do not add `public use fun ... as Type.method` aliases inside Predict just to make a prefixed function name look like a method. Rename the function or local variable instead. Reserve method aliases for framework/external functions or intentional compatibility.
  - Do not rename an existing public API just to improve receiver syntax or local style. Keep the old public function as a compatibility wrapper, or make the API break an explicit migration decision.
  - Keep module syntax for constructors, stateless service functions such as pricing, math/framework helpers, and complex receiver expressions where method syntax is less readable.
  - Return tuples should be small and semantic. Across module boundaries, return only values the caller cannot already derive. Avoid wide positional tuples, especially 4+ items or repeated primitive types with domain meaning. If those values need to travel together, either reduce the return shape or use a named package-only summary struct. Private, tightly local algorithm helpers can use tuples when destructuring names make the meaning clear.
- Predict validation rules:
  - Every assertion must have one clear owner: the module/function whose contract depends on that fact. Do not assert facts only because a later callee might abort; Move transactions are atomic.
  - Public flow functions own flow gates: protocol pause/valuation locks, admin or cap authorization, and user permission when the flow itself is permissioned.
  - The module composing multiple objects owns cross-object binding checks. For example, `ExpiryMarket` validates that a market, oracle, Pyth source, and range key belong together because it composes those objects for trading.
  - If a flow branches on another object's lifecycle or state, validate the object binding before using that state for branch selection, unless that branch intentionally does not require the object.
  - If a flow needs to assert a fact derived from another module's private state, the state-owning module should expose a package-level factual assertion or query. The flow module decides when the fact is required, but should not reconstruct it from public getters unless the state owner intentionally exposes only that raw value.
  - Callees own local operation preconditions. For example, strike exposure indexes own raw range/grid checks, `Pricing` owns live pricing/freshness/ask bounds, `PredictManager` owns balance and position availability, `ExpiryMarket` owns expiry fee escrow and rebate liability semantics, and `PoolVault` owns fee-surplus distribution semantics.
  - State-mutating functions own their postconditions and invariants immediately after the state transition that creates them. Split invariants if only part is meaningful at a point in the flow; avoid broad helpers that re-check unrelated facts.
  - Before a function mutates state owned by one module, it must first validate the mutation-independent facts that function owns: flow gates, authorization, object binding, branch policy, lifecycle policy, static creation inputs, and other facts that decide whether this function is allowed to start the state transition.
  - Do not preflight another module's local leaf preconditions just to avoid a later abort. Preflight another module's fact only when this function must know that fact before it mutates a different state owner; keep that preflight narrow and exposed by the state-owning module.
  - If a quote, liability, or accounting value intentionally depends on post-mutation state, the mutation-before-calculation sequence is allowed only when the mutation-independent flow facts have already been checked and the post-state dependency is obvious from the code or a short comment.
  - Creation flows must validate known static creation inputs before mutating pool allocation, balance, registry, or newly shared object state.
  - Compaction or destructive state transitions must prove the liability/solvency facts they depend on before committing replacement state or moving balances. If the liability can only be computed by consuming dense state, compute it once, then validate before applying cash/accounting deltas.
  - Keep assertion helpers private by default. Use `public(package)` only for real cross-module business preconditions, object binding checks, or package-level APIs that other modules must call directly.
  - Do not expose `public(package)` preflight helpers just because a leaf mutation has an internal guard. Leaf primitives should keep their own guards, and callers should rely on them.
  - `public(package) assert_can_*` helpers are only for cross-module business preconditions that the caller must know before sequencing multiple objects. Do not expose another module's internal arithmetic, counter, balance-overflow, or storage-capacity invariants as package API.
  - Avoid defensive duplicates. If the caller and callee both check the same fact, either remove the caller check or document why failing before a different object is mutated is a real business requirement.
  - Do not add explicit overflow asserts around primitive arithmetic. Move arithmetic and numeric casts already abort on overflow; only keep assertions for semantic domain bounds, solvency, authorization, lifecycle, or gas-bounded iteration.
  - `ProtocolConfig` owns global gates such as trading pause and valuation lock. Flow modules decide which gates apply to each flow.
  - `MarketOracle` owns lifecycle facts such as active, pending settlement, settled, and Pyth-source binding.
  - `Pricing` owns price construction, live oracle freshness, live market status for pricing, and price-specific bounds.
  - `ExpiryMarket` owns trade-flow validation and expiry-local invariants for mint, live redeem, settled redeem, compacted redeem, valuation, allocation, and compaction.
  - `PoolVault.active_expiry_markets` tracks only expiries that still contribute active pool valuation/risk. Compaction must unregister the expiry from the active index.
  - Pool-coordinated compaction is required when compaction returns LP cash to `PoolVault`, unregisters an active expiry, or updates `PoolVault.total_allocated_capital`; do not expose a separate public expiry-only compaction path that can strand free capital.
  - `allocated_capital` is active risk budget only. After compaction it should be `0`, and `PoolVault.total_allocated_capital` should be reduced by the expiry's full pre-compaction allocation.
  - After compaction, an expiry market should be payout and rebate escrow: dense strike state removed, LP-owned cash reduced to the current settled liability, fee cash reduced to remaining rebate liability, and no free LP cash or fee surplus left inside the expiry. PoolVault owns compaction-time fee-surplus distribution into LP idle liquidity, protocol revenue, and insurance.
  - Dynamic allocation resize is live-market-only. Settled, pending-settlement, or compacted markets should not grow or shrink; settled cleanup should happen through compaction.
  - Inline one-off, obvious assertions. Use private helpers for repeated local facts or nontrivial checks. Use flow validation helpers only when they remove real duplication or clarify a complex branch.
  - Trading pause blocks new risk creation, but exits, settlement cleanup, and valuation should only be blocked by the valuation lock unless the protocol intentionally changes pause semantics.
  - When adding or materially changing a public Predict flow, add at least one production-valid success test and focused failure tests for its main gates, state transitions, and accounting effects.

## Code Review Norms

- Findings should focus on correctness, regressions, missing coverage, and brittle assumptions.
- For generated-test changes, check for:
  - duplicate scenarios
  - overly loose assertions
  - hardcoded fixture indices that can silently drift

## When Updating Repo Guidance

Update `CLAUDE.md` or `.claude/rules/*.md` when you learn something that should change future agent behavior, especially:

- newly discovered bug patterns
- test-writing rules
- package-specific gotchas
- build or tooling pitfalls
