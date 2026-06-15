---
paths:
  - "packages/**/*.move"
---

# Sui Move Instructions

**Update this file** when you discover new Move patterns, gotchas, or best practices during sessions.

- Comments are opt-in, not a coverage requirement. Use comments to explain module responsibility, public API contracts, ownership boundaries, invariants, unit/scaling conventions, lifecycle state, sequencing requirements, gas/storage tradeoffs, external dependency quirks, or non-obvious math.

- Do not add comments that restate a function name, narrate obvious code, explain Move syntax, describe simple assignments, or repeat names already clear from types. If deleting a comment would not make the code harder to use or safely modify, delete it.

- For struct fields, comment selectively. Config structs are strong candidates for field comments because they encode policy, units, and economic meaning. Non-config structs should only comment fields with non-obvious mapping semantics, custody/ownership, timestamps, lifecycle state, sentinel values, units, or invariants.

- A struct-level doc can cover a group of obvious fields that share one convention. Do not duplicate the same explanation above every field.

- When changing behavior, update nearby comments in the same edit. Stale comments are worse than missing comments.

- Sui is an object-oriented blockchain. Sui smart contracts are written in the Move language.

- Sui's object ownership model guarantees that the sender of a transaction has permission to use the objects it passes to functions as arguments.

- Sui object ownership model in a nutshell:
  - Single owner objects: owned by a single address - granting it exclusive control over the object.
  - Shared objects: any address can use them in transactions and pass them to functions.
  - Immutable objects: like Shared objects, any address can use them, but they are read-only.

- Abilities are a Move typing feature that control what actions are permissible on a struct:
  - `key`: the struct can be used as a key in storage. If an struct does not have the key ability, it has to be stored under another struct or destroyed before the end of the transaction.
  - `store`: the struct can be stored inside other structs. It also relaxes transfer restrictions.
  - `drop`: the struct can be dropped or discarded. Simply allowing the object to go out of scope will destroy it.
  - `copy`: the struct can be copied.

- Structs can only be created within the module that defines them. A module exposes functions to determine how its structs can be created, read, modified and destroyed.

- Similarly, the `transfer::transfer/share/freeze/receive/party_transfer` functions can only be called within the module that defines the struct being transferred. However, if the struct has the `store` ability, the `transfer::public_transfer/public_share/etc` functions can be called on that object from other modules.

- All numbers are unsigned integers (u8, u16, u32, u64, u128, u256).

- Functions calls are all or nothing (atomic). If there's an error, the transaction is reverted.

- Move transactions are atomic, but protocol-level ordering races can still exist when multiple valid transactions can write the same terminal state. Treat first-writer-wins behavior as a protocol decision and validate every path that can reach the terminal write.

- It is allowed to compare a reference to a value using == or !=. The language automatically borrows the value if one operand is a reference and the other is not.

- Integer overflows/underflows are automatically reverted. Any transaction that causes an integer overflow/underflow cannot succeed. E.g. `std::u64::max_value!() + 1` raises an arithmetic error.

- Don't worry about "missing imports", because the compiler includes many std::/sui:: imports by default.

- Current smart-contract work in this repo is pre-deploy development. Do not optimize contract changes for backwards compatibility, object layout preservation, or migration paths unless the user explicitly says deployed objects or upgrade compatibility matter.

- Do not add `sui::dynamic_field` storage unless the user explicitly requests it or agrees to that design before editing. If dynamic fields look like the right upgrade/storage shape, surface the tradeoff and get confirmation first.

- When using `sui::dynamic_field`, always define `use fun` aliases for method syntax on UID:
```move
use sui::dynamic_field as df;

use fun df::add as UID.add;
use fun df::borrow as UID.borrow;
use fun df::borrow_mut as UID.borrow_mut;
use fun df::exists_ as UID.exists_;
```
Then call as `self.id.exists_(key)`, `self.id.add(key, value)`, `self.id.borrow(key)`, `self.id.borrow_mut(key)` instead of `df::exists_(&self.id, key)` etc.

- Prefer receiver (method) syntax over module-qualified calls when available. Move auto-resolves `x.fn(...)` whenever `fn` is defined in the module that declares `x`'s type (including across packages — e.g. `feed.price()` resolves to `pyth_lazer::feed::price(&feed)`, `inner.magnitude()` resolves to `predict_math::i64::magnitude(&inner)`). No `use fun` alias is needed for this case; it's only required when the function lives in a *different* module from the type (as with `dynamic_field` on `UID`). Receiver syntax lets you drop the module alias entirely when it was only used for those calls — check for and remove the now-unused `Self` import (the compiler warns `unused alias`).

- Prefer macros over constants.

- Function ordering within a module (top to bottom):
  1. `public fun` - external API functions
  2. `public(package) fun` - package-internal functions
  3. `fun` - private/internal helper functions

  Within each visibility group, put read-only/query functions before mutating/write functions. Place private helpers after the function that first makes the call when that does not conflict with the visibility grouping; if read/write ordering and adjacency conflict, preserve the broader read-before-write grouping.

  Exception: `init` function typically comes early (after struct definitions).

- Predict sources are organized by domain subsystem, not by visibility. A subsystem with helper modules gets a folder named for the domain, and its state-owning facade or entry module lives in that folder with its internals. Single-module domains stay as root files. Entrypoints live with the state they mutate because Move struct fields are module-private; do not split a public entry module away from its domain just to make root-level files mean "callable." Predict tests should mirror source domain folders except for shared helpers and broad flow tests.

## Predict Package Rules

### Comments And Docs

- Every Predict Move source file must start with the standard Mysten copyright and SPDX header.
- Every Predict Move module needs a module-level `///` doc immediately before `module`.
- Module docs should usually be 1-4 sentences and explain what state or types the module owns, what flows it is responsible for, and what it intentionally does not own when the boundary is easy to confuse. Longer module docs are appropriate for algorithmic or data-structure-heavy modules such as pricing, math, and strike exposure index code.
- All `public fun` and `public macro fun` external APIs should have doc comments because they are protocol API surface.
- `#[test_only]` helpers do not need public API docs unless their setup behavior is non-obvious.
- `public(package) fun` comments should be used for cross-module flows, non-obvious mutations, constructors/destructors that establish ownership, witness or hot-potato functions, invariant boundaries, or sequencing-sensitive helpers.
- Plain package-only config getters/setters and thin constructor shims do not need doc comments when names and module docs already make the behavior clear.
- Private `fun` comments should be rare and limited to algorithms, formulas, invariants, gas/storage tradeoffs, or non-obvious sequencing.
- Public structs should have doc comments. Admin-tunable config structs should usually document every stored field because those fields encode protocol policy, units, and economic meaning.
- Non-config struct fields should be commented selectively: mappings, balances/custody, timestamps, lifecycle markers, sentinel/state fields, and fields with non-obvious units or invariants. Do not comment simple IDs, counters, or private bookkeeping fields when the module/struct docs and field names are enough.

### Config

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
- `AdminCap` lives in `admin`. Public admin entrypoints live on the module that owns the mutated state: `protocol_config` for global protocol config, object modules for per-object admin state, and `registry` only for registry-owned version, pause-cap, uniqueness, and multi-object creation flows. Embedded config struct setters stay `public(package)`.
- Single-value bounds live in `config_constants::assert_*`; relational checks that depend on multiple fields live in the owning config setter.
- Do not store generic `config_id` fields inside config structs or events; object identity is enough when identity matters.
- Do not add singleton creation flags for objects created during package init.
- Public visibility is an API commitment, not secrecy; on-chain state is still observable.
- Keep admin-tunable config structs readable inside the package by default.
- Expose public getters only for values needed by external Move composition, PTB construction, or clear user-facing protocol state.
- Keep config constructors, setters, bounds checks, and template/snapshot wiring `public(package)`.

### Capabilities

- Every capability lives in its own module under `sources/capabilities/`, named after the cap. The cap module owns only what the cap itself owns: the struct, a `public(package) new` constructor, a public `destroy`, and `id()`/field getters. Allowlists, the asserts that consume them, and mint/revoke entrypoints that touch other state stay in the state-owning module and call the cap module's package constructor.
- Two birth forms, two verbs. `mint_*` creates and allowlists atomically and is hosted by the allowlist-owning module (`registry::mint_pause_cap`, `registry::mint_lifecycle_cap`, `predict_manager::mint_*_cap`); the cap is born authorized. `create` is the alternative born-inert form — a constructor in the cap module itself, legal only when creation touches no other state, with authority arriving later via registration. (The `MarketOracleWriterCap` that exercised the `create` form was removed with the oracle extraction, so the pattern currently has no live instance; the form is still the right choice if a future cap needs inert creation.)
- Authorization-state placement is constraint-driven, not stylistic: the allowlist must live in a module at or below every gating call site in the dependency order, because struct fields are module-private and Move forbids import cycles. The market-lifecycle allowlist lives on `Registry` because its lone gating call site is `registry::create_expiry_market` — the allowlist sits on the consumer module itself. (It briefly lived on `PoolVault` (`plp`) when `plp::compact_storage` was a second consumer in a lower module and both call sites had to reach one allowlist; the prune deleted that path, leaving `registry` the sole consumer.) Within that constraint there are two shapes: a protocol-wide allowlist on a singleton for cross-cutting ops (`PauseCap` and `MarketLifecycleCap`, both on `Registry`), and a per-instance set on the guarded object for instance-scoped authority (the per-`PredictManager` manager caps; the per-oracle `MarketOracleWriterCap` was this shape before the oracle extraction removed it). Pick by intended blast radius.
- Vocabulary: `revoke_*` removes existence-level authority from a birth allowlist; `register_*`/`unregister_*` manage per-instance membership for born-inert caps; `self_unregister_*` is the holder's possession-proved detach.
- Authorize by ID, prove by possession. Registration and seeding APIs take `ID`s because a transaction cannot reference another address's owned objects — multi-party provisioning must be by ID (e.g. `registry::revoke_lifecycle_cap`/`revoke_pause_cap` taking a cap `ID`). Object IDs are unforgeable and never reused, so seeding a wrong ID is permanently inert, never exploitable. Possession (`&Cap`) is reserved for self-actions (proof generation, self-unregister).
- `destroy` never deregisters. A stale allowlist entry left by a destroyed cap is harmless by ID-uniqueness and can be swept later via `revoke_*`/`unregister_*` by copied ID (pinned by `destroy_lifecycle_cap_does_not_revoke`). Every transferable cap gets a public `destroy`; `AdminCap` deliberately has none.
- Version-gating: mint is version-gated (granting authority under a version freeze is the risky direction); existence-level revocation never is — it is harm-reducing and must stay available even when per-object version mirrors transiently disagree (`revoke_pause_cap`, `revoke_lifecycle_cap`). Per-instance `unregister_*` may keep the guarded object's own version gate: the cap's acts and its removal read the same mirror on the same object, so they freeze atomically and no disagreement window exists. Born-inert `create` is stateless and ungated — authority is only granted through version-gated registration. Kill-switch caps (`PauseCap`) additionally bypass the mint gate so emergencies work under a version freeze.
- Cap allowlist changes emit no events today (only the manager-cap mints emit `*CapMinted`). Indexing the lifecycle/pause cap sets would require adding events first — a deliberate omission, not an oversight.

### API Shape

- Functions that create and share a shared object should be named `create_and_share`.
- Pyth Lazer feed IDs should use `u32` consistently across Predict.
- Avoid created events unless there is a concrete indexer or off-chain discovery requirement.
- Events should be emitted by the module that owns the lifecycle/action being reported.
- Event fields should use semantic names from the event domain. Prefer `expiry_market_id`, `pool_vault_id`, or `pyth_feed_id` over generic names like `owner_id`, `object_id`, or `config_id`.
- Do not thread IDs through unrelated leaf/helper modules only to provide event context.
- Embedded accounting/helper modules should not emit parent-scoped events unless the parent identity is part of their own domain model. If a parent-scoped event needs helper-computed amounts, have the helper return a summary and emit the event in the parent/action module.
- Events should be emitted after the state transition and postconditions they report have completed, unless the event intentionally reports an attempted action rather than a completed one.
- Do not call `object::id(&obj)` or `object::id(obj)` at use sites when the object's module can expose an ID getter. Prefer receiver syntax such as `market.id()`, `vault.id()`, or a type-specific getter like `cap.cap_id()`.
- Raw key constructors that take arbitrary object IDs should stay package-only; expose public constructors through the object that anchors the key, using immutable references when possible.
- Prefer native/framework helpers with receiver syntax when available and readable, especially for standard containers such as `Option`, `Table`, and `vector`. For example, use `opt.borrow()`, `opt.borrow_mut()`, `opt.extract()`, and `table.borrow_mut(key)` instead of module-style calls when the receiver is clear.
- For lazy table rows, prefer the DeepBook core pattern: call a small `ensure_*` or `create_*_if_missing` helper that only creates the row when absent, then borrow or index the table directly at the call site. Avoid get-or-create helpers that return `&mut` unless they hide real complexity beyond row creation.
- Prefer receiver syntax when a Move function's first parameter is the owning type and the caller has a named local/reference. Name accessors and helpers naturally so receiver syntax works directly, e.g. `fun sigma(params: &SVIParams)` so callers use `params.sigma()`.
- Do not add `public use fun ... as Type.method` aliases inside Predict just to make a prefixed function name look like a method. Rename the function or local variable instead. Reserve method aliases for framework/external functions or intentional compatibility.
- Do not rename an existing public API just to improve receiver syntax or local style. Keep the old public function as a compatibility wrapper, or make the API break an explicit migration decision.
- Keep module syntax for constructors, stateless service functions such as pricing, math/framework helpers, and complex receiver expressions where method syntax is less readable.
- Return tuples should be small and semantic. Across module boundaries, return only values the caller cannot already derive. Avoid wide positional tuples, especially 4+ items or repeated primitive types with domain meaning. If those values need to travel together, either reduce the return shape or use a named package-only summary struct. Private, tightly local algorithm helpers can use tuples when destructuring names make the meaning clear.
- Once a typed domain object exists, use it through the rest of the flow instead of continuing to pass or recompute its raw fields. For Predict orders, use `Order` internally and use packed `order_id` only at entry/exit/storage boundaries.
- Derived values should be computed at the leaf function that actually needs them. Do not pass derived accounting or index values through helper layers only so another helper can write them into state or assert against them. Pass raw domain inputs or owned objects instead, and let the state-owning leaf derive the values it needs. Exception: when multiple call sites must produce identical bits for a stored aggregate's round-trip (insert/remove/settlement recompute), the derivation is not a leaf concern — it must be one owned function that every site calls, never re-implemented per site.
- Avoid helper chains where function A derives `x`, returns it to function B, and B immediately passes `x` into function C. Move the derivation into C unless B owns the reason that `x` must be sampled there.
- It is fine to return values the caller cannot derive from its owned state, values needed for cross-module effects such as order IDs, payouts, fees, or events, or values that must be sampled once because the calculation is expensive or must remain identical across multiple operations in the same local flow.
- **Producers return owned facts; policy transforms happen once, at the policy owner.** A module that provides data to a downstream flow returns facts it owns — quantities it is the source of truth for, derived entirely within its own domain. It must not pre-shape a return value for one consumer's policy (marks, haircuts, optimistic/conservative stances, netting against a liability measure chosen by the caller's flow).
- Never apply a lossy transformation (clamp/floor at zero, `min`/`max` against another quantity, saturating subtraction, rounding) to a returned value that any consumer applies further arithmetic to. Lossy ops are one-way: the consumer cannot see what was removed, so corrections derived from the pre-transform identity double-count or gap. Each economic quantity is clamped exactly once, in the module that owns the policy, as the last step before use.
- The same expression can be a fact inside an assert and policy as a return. Producers may use clamped/derived values freely in their own assertions and internal state; the producer-fact rule governs returned shape only.
- Producer-policy bug signatures: a return name encoding a stance (`*_optimistic`, `*_conservative`, `net_*`); a consumer or test that adds back, re-derives, or inverts a producer's step; the same excess clamped at two altitudes.
- The producer-fact rule is not a mandate to return raw internals. A derived value owned end-to-end by the module (a reserve computed from its own fee basis, aggregate index totals) is a fact; return the most-derived value that is still purely an owned fact, and keep the fact set minimal (past ~3 values, use a named summary struct per the return-tuple rule).

### Validation And Ownership

- Every assertion must have one clear owner: the module/function whose contract depends on that fact. Do not assert facts only because a later callee might abort; Move transactions are atomic.
- Public flow functions own flow gates: protocol pause/valuation locks, admin or cap authorization, and user permission when the flow itself is permissioned.
- The module composing multiple objects owns cross-object binding checks. For example, `ExpiryMarket` validates that a market, oracle, Pyth source, and range key belong together because it composes those objects for trading.
- If a flow branches on another object's lifecycle or state, validate the object binding before using that state for branch selection, unless that branch intentionally does not require the object.
- If a flow needs to assert a fact derived from another module's private state, the state-owning module should expose a package-level factual assertion or query. The flow module decides when the fact is required, but should not reconstruct it from public getters unless the state owner intentionally exposes only that raw value.
- Callees own local operation preconditions. For example, strike exposure indexes own raw range/grid checks, `Pricing` owns live pricing/freshness/ask bounds, `PredictManager` owns balance and position availability, `ExpiryMarket` owns expiry fee escrow and rebate liability semantics, and `PoolVault` owns fee-surplus distribution semantics.
- `StrikeExposure` owns raw order strike validation, grid normalization, exposure index mutation, and order strike decoding. `ExpiryMarket` should not pre-validate order strikes or duplicate exposure-derived facts just to call `StrikeExposure`.
- State-mutating functions own their postconditions and invariants immediately after the state transition that creates them. Split invariants if only part is meaningful at a point in the flow; avoid broad helpers that re-check unrelated facts.
- Before a function mutates state owned by one module, it must first validate the mutation-independent facts that function owns: flow gates, authorization, object binding, branch policy, lifecycle policy, static creation inputs, and other facts that decide whether this function is allowed to start the state transition.
- Do not preflight another module's local leaf preconditions just to avoid a later abort. Preflight another module's fact only when this function must know that fact before it mutates a different state owner; keep that preflight narrow and exposed by the state-owning module.
- If a quote, liability, or accounting value intentionally depends on post-mutation state, the mutation-before-calculation sequence is allowed only when the mutation-independent flow facts have already been checked and the post-state dependency is obvious from the code or a short comment.
- In multi-object Predict flows, a mid-function assertion is often a phase boundary. Prefer extracting that phase into a helper where the helper starts with its own mutation-independent preconditions, performs one coherent state transition, and ends with the postconditions for the resources it changed. Keep postcondition helpers named by the resource they protect, such as allocation backing versus cash backing, and only combine them when they are always meaningful at the same point.
- Creation flows must validate known static creation inputs before mutating pool allocation, balance, registry, or newly shared object state.
- Compaction or destructive state transitions must prove the liability/solvency facts they depend on before committing replacement state or moving balances. If the liability can only be computed by consuming dense state, compute it once, then validate before applying cash/accounting deltas.
- Keep assertion helpers private by default. Use `public(package)` only for real cross-module business preconditions, object binding checks, or package-level APIs that other modules must call directly.
- Do not expose `public(package)` preflight helpers just because a leaf mutation has an internal guard. Leaf primitives should keep their own guards, and callers should rely on them.
- `public(package) assert_can_*` helpers are only for cross-module business preconditions that the caller must know before sequencing multiple objects. Do not expose another module's internal arithmetic, counter, balance-overflow, or storage-capacity invariants as package API.
- Avoid defensive duplicates. If the caller and callee both check the same fact, either remove the caller check or document why failing before a different object is mutated is a real business requirement.
- `ProtocolConfig` owns global gates such as trading pause and valuation lock. Flow modules decide which gates apply to each flow.
- `ExpiryMarket` owns per-expiry market state and stores the Propbook underlying ID plus tick size. It does not snapshot Propbook oracle object IDs; priced flows pass feed objects through to `pricing::load_live_pricer`.
- `Pricing` owns the live pricing boundary: current Propbook canonical binding for the market's underlying, the pre-expiry live-pricing check, feed freshness, Predict's pricing-safe surface envelope, and SVI price construction.
- `ExpiryMarket` owns trade-flow validation and expiry-local invariants for mint, live redeem, settled redeem, valuation, and allocation.
- Trading pause blocks new risk creation, but exits, settlement cleanup, and valuation should only be blocked by the valuation lock unless the protocol intentionally changes pause semantics.

### Predict Economics

- Predict order IDs are scoped by `(expiry_market_id, order_id)`. Do not encode or infer market lifecycle facts such as expiry from the order ID; bind an order to a market through `PredictManager` position keys and the market/exposure state that created it.
- Mint-admission policy must not be part of packed order decoding or structural `Order` validation. Future upgrades to mint-only policy, such as leverage tiers or price thresholds, must not retroactively make existing packed order IDs invalid.
- `PoolVault.active_expiry_markets` tracks only expiries that still contribute active pool valuation/risk. Compaction must unregister the expiry from the active index.
- Pool-coordinated compaction is required when compaction returns LP cash to `PoolVault`, unregisters an active expiry, or updates `PoolVault.total_allocated_capital`; do not expose a separate public expiry-only compaction path that can strand free capital.
- `allocated_capital` is active risk budget only. After compaction it should be `0`, and `PoolVault.total_allocated_capital` should be reduced by the expiry's full pre-compaction allocation.
- After compaction, an expiry market should be payout and rebate escrow: dense strike state removed, LP-owned cash reduced to the current settled liability, fee cash reduced to remaining rebate liability, and no free LP cash or fee surplus left inside the expiry. PoolVault owns compaction-time fee-surplus distribution into LP idle liquidity, protocol revenue, and insurance.
- Dynamic allocation resize is live-market-only. Settled, pending-settlement, or compacted markets should not grow or shrink; settled cleanup should happen through compaction.
- Predict sells binary (digital) contracts — European cash-or-nothing range digitals — not a separate spot contract plus an external debt overlay. A contract's live value is its range probability value minus its deterministic floor value, floored at zero; 1x orders are the special case where the floor is zero.
- Terminology: docs use options/structured-product vocabulary (canonical glossary: `packages/predict/docs/glossary.md`). Mint-economics identifiers are `entry_value`, `net_premium`, `financed_amount`, `min_net_premium` (and the `OrderMinted.net_premium` event field). The `floor_*` family (`floor_shares`, `floor_index`, `terminal_floor_index`, `floor_amount`) is the payoff primitive — never rename it to financing/debt vocabulary; the glossary bridges the two. The EWMA congestion surcharge keeps core's `penalty` vocabulary in code.
- Leveraged Predict economics are part of the contract terms. Leverage changes the deterministic floor schedule of the contract over time, so pricing, NAV, payout, and settlement accounting should model one contract with a time-varying floor rather than bolting on separate leverage-specific scans when the value can be derived from indexed contract terms.
- Contract floors should track only the atomic values needed by each index. NAV uses aggregate floor shares with the current floor index. Payout backing uses exact terminal payout plus a conservative static max-live backing payout so live backing can be read without scanning or passing a clock.
- An index may aggregate raw order atoms or derived terms. If it aggregates derived terms, removal must subtract bit-equal what insertion added, so the term derivation must be a single owned function (the canonical evaluator, `strike_exposure_config::index_terms`) called by mint insert, remove, reinsert, and any settlement recompute — never re-implemented per call site. The evaluator must stay pure (snapshotted config plus caller atoms only; no clock, no oracle, no policy asserts — mint admission stays in the mint-only wrapper), every atom it reads must round-trip losslessly through the packed order ID (a lossy repack of `quantity`, `floor_shares`, or `opened_at_ms` is an accounting bug, not a precision nit), and the config fields it reads (`terminal_floor_index`, floor-curve inputs) must never gain live-expiry setters. Re-calling the evaluator or one of its sub-primitives is free and safe; re-expressing its formula anywhere is the violation. Flow policy (e.g. mint admission) validates its bounds *before* evaluating terms, so the evaluator's own aborts always mean a broken atom round-trip, never bad flow input.
- Live payout backing may intentionally be conservative instead of exact when that removes runtime scans. Do not reuse terminal floor as live backing because it can understate pre-expiry liability; use a max-live backing term that is at least as large as any future live payout for that order.
- NAV may use aggregate floor accounting only under an explicit precondition that every active leveraged order is individually above its floor before valuation. If that invariant is not maintained by the surrounding health/liquidation flow, aggregate subtraction can overstate recoverable value and the implementation must fall back to exact per-order recoverability or another exact representation.
- For leveraged Predict economics, the contract floor is limited-recourse to the order that created it. A floor can offset only that order's live value or settled payout, capped at that value/payout. Do not treat aggregate floor value that exceeds aggregate position liability as positive NAV unless the implementation explicitly models exact per-order recoverability.
- **NAV-mark directional invariant — never undercount the SUPPLY mark.** The NAV mark that prices PLP **supply** must be an *upper bound* on true recoverable value (`supply_NAV >= TRUE_NAV`): a supplier priced `>= TRUE` mints `<=` fair shares, so it can never over-mint and dilute incumbents. The flush prices supply AND withdraw at **one mark** — `pool_nav = idle + Σ active-expiry current_nav` (net of the pending-protocol-profit exclusion), computed once in `finish_flush` and passed to both queues in `drain_lp_requests` — so that single mark must equal TRUE in both directions. It does: each `expiry_market::current_nav` is the **EXACT** per-expiry recoverable value (free cash minus the exact per-order live liability = payout-tree `walk_linear` minus the leveraged-book `correction_value`, floored at zero), so `supply_NAV = TRUE` at the valuation boundary — never an under- or over-count. There is **no conservative band** (the bucket/band decomposition belonged to the deleted approximate-NAV world); NAV manipulation is closed by the **privileged** cron flush (audit L8), and dilution by the fair FIFO drain at the frozen mark. A liveness clamp inside `current_nav` (the degenerate-underwater `saturating_sub` cash floor) must *maximize* NAV when it fires. A settlement-dependent mark — a **past-expiry-but-unsettled** market — has no well-defined TRUE, so it cannot be valued until settlement-v2: do NOT substitute an approximate mark (contribute-0 dilutes incumbents on supply; free-cash over-pays withdrawals — both break the single-mark dual-use). This is the documented flush-liveness precondition on `expiry_market::current_nav` / `plp::value_expiry`.
- Leveraged Predict orders must satisfy `max_terminal_floor <= max_terminal_payout` at creation, where max terminal floor is the order's floor amount evaluated at expiry under the market's snapshotted floor-index curve and max terminal payout is the order quantity. Trading fees and builder fees are transaction costs, not floor value, and should not be included in this invariant.

## General Move Patterns

- Function inputs should be ordered by role: mutable domain objects first, immutable domain objects second, primitive/domain values third, execution context last. `clock: &Clock` is execution context and should be second-to-last when present; `ctx: &mut TxContext` is always last. Constructors with only primitive grid inputs should use natural domain order such as `min_strike, tick_size, max_strike, ctx`. Private algorithm helpers may keep traversal/key ordering when changing it would make the algorithm less readable, but public and package APIs should not put primitive values before object references.

- Utility and math modules should only guard local mathematical or data-structure preconditions (division by zero, invalid precision, insufficient balance/quantity, invalid ranges). They should not encode application-level policy decisions like "this state shouldn't happen" or "this user type gets different treatment." Application-level guards belong in the calling module.

- Do not add explicit overflow, underflow, or numeric-cast asserts solely to replace Move's primitive VM aborts. Move arithmetic and numeric casts already abort atomically on overflow. Keep named assertions for semantic domain bounds, division by zero when the module has a meaningful named zero error, solvency/accounting invariants, authorization, lifecycle, and gas-bounded iteration.

- Subtraction is exact by default — Move's underflow abort is a free invariant check, so never convert a subtraction with a documented no-underflow invariant into a clamp. When clamping at zero *is* the policy, spell it `a.saturating_sub(b)` (`std::u64`, receiver syntax, no import needed) — never `a - a.min(b)`, `if (a > b) a - b else 0`, or a hand-rolled `sat_sub` helper. One spelling keeps the package's clamp inventory grep-complete (`grep saturating_sub`), and per the producer-fact rule each call site is a policy decision owned by the clamping module, ideally with a one-line why-clamp-not-abort comment. The same layering applies to other numeric utilities: take them from `std::uN` when std has the exact semantics (`min`/`max`/`diff`/`divide_and_round_up`); `predict_math` is only for fixed-point and domain math std cannot express.

- Bounding one input only proves the bound it names. For example, `pow10(shift)` can guard its exponent, while callers that need a semantic maximum normalized price should assert that semantic price bound explicitly. Do not add a second assert merely to give primitive multiplication overflow a custom abort code.

- When two code paths can drive the same terminal state transition (e.g. an oracle settlement frozen by either a permissionless feed update or a privileged operator update), make sure both paths apply the same validation. A first-writer-wins race is a hidden authorization decision: if the privileged path can race the trustworthy path during a degraded state (stale feed, paused upstream), the privileged actor can unilaterally write the terminal value with weaker checks. Either gate the privileged path on the trustworthy path's freshness, or require the trustworthy path for terminal transitions.

- Admin setters that don't bound away from "no-op" values are a defense-in-depth gap. A circuit-breaker deviation cap that accepts up to 100%, or absolute bounds with no floor/ceiling, lets a single bad admin call silently disable the protection without any error. When a setter exists primarily to tighten a safety check, give it a hard ceiling tighter than the trivially-disabling value (e.g. cap deviation at 50%, bound `min_basis`/`max_basis` within an absolute envelope) so admin error or compromise can't turn the guard into a no-op.

- Don't move leaf-level semantic guards to callers because "the current caller validates first." That reasoning creates a cross-module invariant. Leaf primitives in `public(package)` data structures should remain self-consistent for the domain facts they own, such as valid ranges, sufficient quantity, or balance availability. Primitive arithmetic overflow does not need a duplicate semantic wrapper unless the wrapper enforces a real domain bound.

- Converse of the leaf-guard rule: caller-side guards that merely duplicate a leaf semantic check (same bound, same intent) are clutter, not defense-in-depth. Two exceptions worth keeping the duplicate for: (a) the caller can supply a semantically richer error for a different business precondition; (b) the caller's bound is strictly tighter than the leaf's. Otherwise delete the caller-side assert and let the leaf be the single source of truth.

- Timestamp fields should have clear semantics. If `timestamp` means "last price update", don't bump it on unrelated updates (e.g., SVI param changes). Muddled semantics break staleness checks.

- Distinguish on-chain landing time from source-data time in the field name itself. A bare `lazer_timestamp` is ambiguous — does it mean the publisher's timestamp embedded in the verified payload, or `clock.timestamp_ms()` captured when the payload landed on chain? Use a unit suffix that encodes both the unit and the source: `*_timestamp_ms` for `clock.timestamp_ms()` values (on-chain landing time, always milliseconds in Sui), and `*_published_at_us` (or similar explicit phrase) for timestamps that come from the data being pushed. Same convention for event payload fields and getter names. Bulk renames across an entire package are safe with `perl -i -pe 's/\bX\b/Y/g'` since `\b` correctly skips compound identifiers like `lazer_X_ms`.

- Validate before mutate means contract-owned facts, not broad application preflighting. A function must validate the mutation-independent facts it owns before mutating state: flow gates, authorization, object binding, branch/lifecycle policy, static creation inputs, and facts that decide whether the function may start its transition. Do not duplicate another module's leaf guard just to avoid a later abort; preflight another module's fact only when the caller must know it before mutating a different state owner. If accounting or pricing intentionally depends on post-mutation state, make that dependency obvious and validate mutation-independent facts first. Always validate before consuming irreversible resources such as burning coins or destroying objects.

- In multi-object flows, a mid-function assertion is often a phase boundary. Prefer extracting that phase into a helper where the helper starts with its own mutation-independent preconditions, performs one coherent state transition, and ends with the postconditions for the resources it changed. Keep postcondition helpers named by the resource they protect, such as allocation backing versus cash backing, and only combine them when they are always meaningful at the same point.

- Emit events after the state transition and postconditions they report have completed, unless the event intentionally reports an attempted action rather than a completed one.

- A permissionless or keeper-callable settlement/claim function should treat empty or zero-amount cases as a no-op, not an abort: early-return when there is nothing to resolve, and guard each payout with `if (amount > 0)` before splitting/dispensing a balance. This keeps a single caller — or a batch sweep over many accounts — from reverting just because one account is owed nothing. Reserve aborts for real preconditions (authorization, lifecycle/settlement state, unclosed positions).

- Distributing reward assets to holders of a freely-transferable fungible share token (an LP/share `Coin`) is a fairness-vs-composability tradeoff. A bare transferable coin has nowhere to store a per-holder `reward_debt`, so naive pro-rata-at-claim lets a fresh depositor grab already-accrued rewards (mint shares → immediately claim a pro-rata slice → exit). Fair distribution needs one of: (a) lock/stake the token into a tracked position/ledger so an `acc_reward_per_share` + per-position `reward_debt` accumulator credits only post-join rewards; or (b) keep the token transferable but fold reward value into its redemption price — either swap rewards into the share's base asset (no oracle; yield realized as the base asset) or price them into NAV via an oracle (pays foreign assets in-kind). You cannot have transferable shares + fairness + foreign-assets-in-kind-without-pricing simultaneously. The same-asset case (reward == principal, e.g. slush_strategies) hides this because folding into share price is automatic.

- Lazily-rolled epoch state (e.g. DeepBook-style `active_stake`/`inactive_stake` where an `update(ctx)`/`update_stake(ctx)` moves inactive→active only on the first interaction in a new epoch, guarded by `if (self.epoch == ctx.epoch()) return`) is only authoritative right after that update runs. Always call the update at the top of any flow that reads the rolled field (mint/redeem/claim), and treat a bare getter (`active_stake()`) as potentially stale otherwise — it can read 0 while a full epoch's inactive amount is waiting to roll. The `==` guard is correct because epochs are monotonic: any later epoch (not just the next) triggers the roll, so skipped epochs are fine and inactive never expires.

- A public entrypoint that mutates a `Balance`/field belongs in the module that *declares* that field (struct fields are module-private). When asked to relocate custody (e.g. "hold the staked balance in `PoolVault` instead of `Registry`"), move the entrypoint that touches it into the owning module too, rather than adding leaky `join_x`/`split_x` package accessors just to keep the function where it was — the function can take the other domain objects (`&mut PredictManager`, etc.) as parameters. Place the move-version gate on the object being mutated (`vault.assert_version_allowed()`), not on an unrelated object that's only passed for the old location's sake.

- Default convention here is to separate *config storage* from *compute*: `pricing_config`/`risk_config`/etc. only store fields + getters + `assert_*`, while the math lives elsewhere (`pricing.move`). But a single, self-contained compute that only reads one config's own fields is fine to fold into that config module as a `&Config` method (e.g. `stake_config::fee_discount_fraction(&StakeConfig, active_stake)` reading its own `lower`/`upper`/caps) — it removes a whole module and shrinks call sites to `config.stake_config().fee_discount_fraction(active)`. Reserve a dedicated compute module for math that spans multiple inputs/objects or is large; don't stand one up for a lone config-bound formula.

- If a flow branches on another object's lifecycle or state, validate the object binding before using that state for branch selection, unless that branch intentionally does not require the object.

- Prefer explicit loop bounds over `while (true)` when the iteration range is easy to express. If a loop naturally means "from `min_page` to `max_page` inclusive" or "while `slot <= end_slot`", write that directly instead of using `while (true)` plus interior `break`s.

- Avoid deprecated Sui framework functions. Use the current recommended API (e.g., `coin_registry::new_currency_with_otw` instead of `coin::create_currency`). If a deprecated function must be used, add a comment explaining why the replacement doesn't work for this case.

- Burning DEEP requires the shared `token::deep::ProtectedTreasury` (it holds the `TreasuryCap` in a dynamic field) — you cannot just drop a `Coin<DEEP>`. Take `&mut ProtectedTreasury` as a parameter and call `token::deep::burn(treasury, coin)`, mirroring `deepbook::pool::burn_deep` (`packages/deepbook/sources/pool.move`). In tests, share one with `token::deep::share_treasury_for_testing(ctx)` then `take_shared<ProtectedTreasury>()`; `coin::mint_for_testing<DEEP>(...)` mints test DEEP and `token::deep::burn` reduces the cap's supply (no check that the coin came from that cap, so this works in tests).

- `create_and_share` constructors should accept tunable per-instance config as constructor parameters rather than seeding defaults that the admin must immediately overwrite. After `share_object` the only way to reconfigure is a separate setter tx, so a default-only constructor forces a two-tx admin flow whenever an instance needs non-default values. Take the params directly, validate them with the same `assert_*` helpers the setter uses (so creation and update share one validation path), and use defaults only when the config is genuinely the same for every instance.

## Tool Calling Instructions

- Use `sui move build --path packages/predict` from the repo root, or `sui move build` inside a package directory with `Move.toml`.
- Use `sui move test --path packages/predict --gas-limit 100000000000` from the repo root, or `sui move test --gas-limit 100000000000` inside the package directory. The high gas limit is needed because sui 1.66+ lowered the default test gas budget, causing complex tests to time out.
- When `sui move test` shows warnings (e.g., unused `mut` modifiers, unused variables), fix them immediately before proceeding
- Before claiming Move or protocol work is complete, run the relevant package test suite(s) and confirm they pass with zero failures. If the change affects multiple packages or local package manifests, run each impacted package's tests.
- when you have completed making Move changes, run `bunx prettier-move -c path/to/file.move --write` on any files that are modified to format them correctly.

# Move Code Quality Checklist

The rapid evolution of the Move language and its ecosystem has rendered many older practices
outdated. This guide serves as a checklist for developers to review their code and ensure it aligns
with current best practices in Move development.

## Code Organization

Some of the issues mentioned in this guide can be fixed by using
[Move Formatter](https://www.npmjs.com/package/@mysten/prettier-plugin-move) either as a CLI tool,
or [as a CI check](https://github.com/marketplace/actions/move-formatter), or
[as a plugin for VSCode (Cursor)](https://marketplace.visualstudio.com/items?itemName=mysten.prettier-move).

## Package Manifest

### Use Right Edition

All of the features in this guide require Move 2024 Edition, and it has to be specified in the
package manifest.

```toml
[package]
name = "my_package"
edition = "2024.beta" # or (just) "2024"
```

### Implicit Framework Dependency

Starting with Sui 1.45 you no longer need to specify framework dependency in the `Move.toml`:

```toml
# old, pre 1.45
[dependencies]
Sui = { ... }

# modern day, Sui, Bridge, MoveStdlib and SuiSystem are imported implicitly!
[dependencies]
```

### Prefix Named Addresses

If your package has a generic name (e.g., `token`) – especially if your project includes multiple
packages – make sure to add a prefix to the named address:

```toml
# bad! not indicative of anything, and can conflict
[addresses]
math = "0x0"

# good! clearly states project, unlikely to conflict
[addresses]
my_protocol_math = "0x0"
```

### Keep Local Package Style Consistent

If an old-style package depends on another local package, do not migrate only one side of that
dependency edge. In this repo, `packages/margin_liquidation` still depends on old-style
`packages/deepbook_margin`, so removing `[addresses] deepbook_margin = "0x0"` from
`packages/deepbook_margin/Move.toml` breaks dependents with
`Packages with old-style Move.toml files cannot depend on new-style packages`.

### Match the source of a transitively-shared dependency

When you add a dependency on a package that another of your dependencies already pulls in, declare
it with the *same source* that dependency uses — do not mix `git` and `local` for the same package
name. Example: `packages/deepbook` depends on `token` via
`{ git = "...deepbookv3.git", subdir = "packages/token", rev = "main" }`. When `packages/predict`
(which depends on `deepbook` locally) needed `token::deep::DEEP`, adding
`token = { local = "../token" }` would have created a git-vs-local source conflict for the single
`token` package; declaring `token` with the identical git line lets the resolver unify it. Copy the
exact `git`/`subdir`/`rev` (or local path) from the existing consumer.

## Imports, Module and Constants

### Using Module Label

```move
// bad: increases indentation, legacy style
module my_package::my_module {
    public struct A {}
}

// good!
module my_package::my_module;

public struct A {}
```

### No Single `Self` in `use` Statements

```move
// correct, member + self import
use my_package::other::{Self, OtherMember};

// bad! `{Self}` is redundant
use my_package::my_module::{Self};

// good!
use my_package::my_module;
```

### All `use` Statements at Module Top Level

```move
// bad! function-local imports
fun my_function() {
    use my_package::my_module;
    // ...
}

// good! all imports at module top level
use my_package::my_module;

fun my_function() {
    // ...
}
```

### Group `use` Statements with `Self`

```move
// bad!
use my_package::my_module;
use my_package::my_module::OtherMember;

// good!
use my_package::my_module::{Self, OtherMember};
```

### Error Constants are in `EPascalCase`

```move
// bad! all-caps are used for regular constants
const NOT_AUTHORIZED: u64 = 0;

// good! clear indication it's an error constant
const ENotAuthorized: u64 = 0;
```

### Regular Constant are `ALL_CAPS`

```move
// bad! PascalCase is associated with error consts
const MyConstant: vector<u8> = b"my const";

// good! clear indication that it's a constant value
const MY_CONSTANT: vector<u8> = b"my const";
```

## Structs

### Capabilities are Suffixed with `Cap`

```move
// bad! if it's a capability, add a `Cap` suffix
public struct Admin has key, store {
    id: UID,
}

// good! reviewer knows what to expect from type
public struct AdminCap has key, store {
    id: UID,
}
```

### No `Potato` in Names

```move
// bad! it has no abilities, we already know it's a Hot-Potato type
public struct PromisePotato {}

// good!
public struct Promise {}
```

### Events Should Be Named in Past Tense

```move
// bad! not clear what this struct does
public struct RegisterUser has copy, drop { user: address }

// good! clear, it's an event
public struct UserRegistered has copy, drop { user: address }
```

### Emit Events From the Owning Module

- Emit an event from the module that owns the lifecycle or action being reported.
- Name event fields semantically from that event domain. Prefer `expiry_market_id`, `pool_vault_id`, or `pyth_feed_id` over generic names like `owner_id`, `object_id`, or `config_id`.
- Do not thread IDs through unrelated helper or leaf modules only to provide event context.
- Embedded accounting/helper modules should not emit parent-scoped events unless the parent identity is part of their own domain model. If a parent-scoped event needs helper-computed values, return a summary and emit the event in the parent/action module.

### Use Positional Structs for Dynamic Field Keys + `Key` Suffix

```move
// not as bad, but goes against canonical style
public struct DynamicField has copy, drop, store {}

// good! canonical style, Key suffix
public struct DynamicFieldKey() has copy, drop, store;
```

## Functions

### No `public entry`, Only `public` or `entry`

```move
// bad! entry is not required for a function to be callable in a transaction
public entry fun do_something() { /* ... */ }

// good! public functions are more permissive, can return value
public fun do_something_2(): T { /* ... */ }
```

### Write Composable Functions for PTBs

```move
// bad! not composable, harder to test!
public fun mint_and_transfer(ctx: &mut TxContext) {
    /* ... */
    transfer::transfer(nft, ctx.sender());
}

// good! composable!
public fun mint(ctx: &mut TxContext): NFT { /* ... */ }

// good! intentionally not composable
entry fun mint_and_keep(ctx: &mut TxContext) { /* ... */ }
```

### Keep Return Tuples Small and Semantic

- Across module boundaries, return only values the caller cannot already derive.
- Avoid wide positional tuples, especially 4+ items or repeated primitive types with domain meaning.
- If several values need to travel together, either reduce the return shape or use a named package-only summary struct.
- Private, tightly local algorithm helpers can use tuples when destructuring names make the meaning clear.
- When a struct repeats the exact field group of another local struct and helpers only copy values between them, prefer embedding the named struct directly. This keeps the real data shape visible and removes projection boilerplate such as `to_summary` / `write_summary` helpers.

### Objects Go First (Except for Clock)

```move
// bad! hard to read!
public fun call_app(
    value: u8,
    app: &mut App,
    is_smth: bool,
    cap: &AppCap,
    clock: &Clock,
    ctx: &mut TxContext,
) { /* ... */ }

// good!
public fun call_app(
    app: &mut App,
    cap: &AppCap,
    value: u8,
    is_smth: bool,
    clock: &Clock,
    ctx: &mut TxContext,
) { /* ... */ }
```

### Capabilities Go Second

```move
// bad! breaks method associativity
public fun authorize_action(cap: &AdminCap, app: &mut App) { /* ... */ }

// good! keeps Cap visible in the signature and maintains `.calls()`
public fun authorize_action(app: &mut App, cap: &AdminCap) { /* ... */ }
```

### Getters Named After Field + `_mut`

```move
// bad! unnecessary `get_`
public fun get_name(u: &User): String { /* ... */ }

// good! clear that it accesses field `name`
public fun name(u: &User): String { /* ... */ }

// good! for mutable references use `_mut`
public fun details_mut(u: &mut User): &mut Details { /* ... */ }
```

## Function Body: Struct Methods

### Common Coin Operations

```move
// bad! legacy code, hard to read!
let paid = coin::split(&mut payment, amount, ctx);
let balance = coin::into_balance(paid);

// good! struct methods make it easier!
let balance = payment.split(amount, ctx).into_balance();

// even better (in this example - no need to create temporary coin)
let balance = payment.balance_mut().split(amount);

// also can do this!
let coin = balance.into_coin(ctx);
```

### Do Not Import `std::string::utf8`

```move
// bad! unfortunately, very common!
use std::string::utf8;

let str = utf8(b"hello, world!");

// good!
let str = b"hello, world!".to_string();

// also, for ASCII string
let ascii = b"hello, world!".to_ascii_string();
```

### UID has `delete`

```move
// bad!
object::delete(id);

// good!
id.delete();
```

### `ctx` has `sender()`

```move
// bad!
tx_context::sender(ctx);

// good!
ctx.sender()
```

### Vector Has a Literal. And Associated Functions

```move
// bad!
let mut my_vec = vector::empty();
vector::push_back(&mut my_vec, 10);
let first_el = vector::borrow(&my_vec);
assert!(vector::length(&my_vec) == 1);

// good!
let mut my_vec = vector[10];
let first_el = my_vec[0];
assert!(my_vec.length() == 1);
```

### Collections Support Index Syntax

```move
let x: VecMap<u8, String> = /* ... */;

// bad!
x.get(&10);
x.get_mut(&10);

// good!
&x[&10];
&mut x[&10];
```

## Option -> Macros

### Destroy And Call Function

```move
// bad!
if (opt.is_some()) {
    let inner = opt.destroy_some();
    call_function(inner);
};

// good! there's a macro for it!
opt.do!(|value| call_function(value));
```

### Destroy Some With Default

```move
let opt = option::none();

// bad!
let value = if (opt.is_some()) {
    opt.destroy_some()
} else {
    abort EError
};

// good! there's a macro!
let value = opt.destroy_or!(default_value);

// for the "assert-then-extract" case, prefer assert! + destroy_some over
// destroy_or!(abort E) — keeps named error codes consistent with the rest
// of the function and avoids mixing assert and abort styles.
assert!(opt.is_some(), ECannotBeEmpty);
let value = opt.destroy_some();
```

## Loops -> Macros

### Do Operation N Times

```move
// bad! hard to read!
let mut i = 0;
while (i < 32) {
    do_action();
    i = i + 1;
};

// good! any uint has this macro!
32u8.do!(|_| do_action());
```

### New Vector From Iteration

```move
// harder to read!
let mut i = 0;
let mut elements = vector[];
while (i < 32) {
    elements.push_back(i);
    i = i + 1;
};

// easy to read!
vector::tabulate!(32, |i| i);
```

### Do Operation on Every Element of a Vector

```move
// bad!
let mut i = 0;
while (i < vec.length()) {
    call_function(&vec[i]);
    i = i + 1;
};

// good!
vec.do_ref!(|e| call_function(e));
```

### Destroy a Vector and Call a Function on Each Element

```move
// bad!
while (!vec.is_empty()) {
    call(vec.pop_back());
};

// good!
vec.destroy!(|e| call(e));
```

### Fold Vector Into a Single Value

```move
// bad!
let mut aggregate = 0;
let mut i = 0;

while (i < source.length()) {
    aggregate = aggregate + source[i];
    i = i + 1;
};

// good!
let aggregate = source.fold!(0, |acc, v| {
    acc + v
});
```

### Filter Elements of the Vector

> Note: `T: drop` in the `source` vector

```move
// bad!
let mut filtered = [];
let mut i = 0;
while (i < source.length()) {
    if (source[i] > 10) {
        filtered.push_back(source[i]);
    };
    i = i + 1;
};

// good!
let filtered = source.filter!(|e| e > 10);
```

## Other

### Ignored Values In Unpack Can Be Ignored Altogether

```move
// bad! very sparse!
let MyStruct { id, field_1: _, field_2: _, field_3: _ } = value;
id.delete();

// good! 2024 syntax
let MyStruct { id, .. } = value;
id.delete();
```

## Comments

### Doc Comments Start With `///`

```move
// bad! tooling doesn't support JavaDoc-style comments
/**
 * Cool method
 * @param ...
 */
public fun do_something() { /* ... */ }

// good! will be rendered as a doc comment in docgen and IDE's
/// Cool method!
public fun do_something() { /* ... */ }
```

### Complex Logic? Leave a Focused Comment `//`

Use inline comments only when they explain a non-obvious invariant, sequencing
requirement, external dependency quirk, or gas/storage tradeoff. Do not narrate
the next line of code.

```move
// good!
// Note: can underflow if a value is smaller than 10.
// TODO: add an `assert!` here
let value = external_call(value, ctx);
```
