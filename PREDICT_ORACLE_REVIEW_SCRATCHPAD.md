# Predict Oracle Re-Architecture Review Scratchpad

Branch: `predict-oracle-rearchitecture`
Checkpoint pushed: `0dbe25e2385d9179e2f366417f68fe09819269f4`

## Gold Standard

- Oracle modules own writes and persisted source state.
- `pricing.move` owns all app-facing oracle read policy: Pyth vs Block Scholes selection, freshness interpretation, live vs settled values, quote inputs, and curve inputs.
- `predict.move` owns protocol execution only: authorization, position/vault mutations, fee routing, events, and risk checks.
- No ephemeral pricing/context structs unless they remove real complexity.
- Read policy should not leak outside pricing. Branching should exist only where it maps to real protocol states.
- Settlement should be driven by oracle updates, not by mint/redeem taking mutable oracle refs.
- Shared objects should be minimized on hot user flows: mint/redeem take read-only oracle refs.
- Keep builder-facing public APIs only where they expose core state or required quote information.

## Review Loop

### Loop 1

Status: completed.

Agents:
- Oracle write/state review: `Laplace` (`019e12b8-68f7-7f90-a39a-0ee8a7c84e55`), completed.
- Pricing/read-policy review: `Schrodinger` (`019e12b8-7fd9-7bc3-9878-231c0f58eef0`), completed.
- App/vault flow review: `Averroes` (`019e12b8-9770-7c31-964c-3a2e7d4ea789`), completed.
- Public API/surface review: `Godel` (`019e12b8-b19d-74c0-b081-51074d0d119e`), completed.

Findings:
- Fixed local finding: `pyth_source.move` had private `update_from_values` before later public getters; moved it below all public getters under a private section.
- Fixed agent finding: `market_oracle::update_block_scholes_prices` had an early pending-settlement branch that could settle from previously stored BS data before validating/applying the supplied BS update. Settlement now happens after the supplied BS update is validated/applied.
- Fixed agent finding: BS source timestamps were operator-supplied and not bounded against chain time. BS price and SVI updates now reject future source timestamps.
- Fixed related issue: Pyth source ingestion now rejects future source timestamps.
- Fixed agent finding: boundary live fair prices (`0` or `FLOAT_SCALING`) could abort in fee math even though they are valid pricing outputs. Boundary raw Bernoulli fee is now zero and the configured minimum fee still applies to live quotes.
- Fixed agent finding: `registry::create_market_oracle` accepted already-expired expiries. It now requires `expiry > clock.timestamp_ms()`.
- Fixed agent finding: compacted settled redemption computed payout in `predict` while compacted liability decrements used vault-stored settlement. Vault removal now returns the payout amount, and `predict` uses that value for the transfer.
- Fixed agent finding: `oracle_config::set_asset_feed_id` accepted values wider than Pyth Lazer's `u32` feed id and deferred failure to market creation. Feed width is now validated at config write time.
- Fixed defensive issue: `pricing::settlement_price` now reasserts the settlement source timestamp is after expiry at the read-policy layer.
- Fixed tooling issue: simulation transaction builders still targeted deleted oracle APIs. They now create/use `PythSource`, `MarketOracleCap`, `MarketOracle`, `market_oracle::update_block_scholes_prices`, current `RangeKey::new`, and current `predict::mint`.
- Local finding: PR description says settlement uses effective timestamp after expiry; current code intentionally requires `source_timestamp > expiry` plus freshness via effective timestamp. PR body needs correction before final.

Decisions:
- Do not reintroduce `PriceContext` to avoid repeated live input resolution. The gold standard prefers pricing as a direct read layer over ephemeral context objects; repeated immutable reads are acceptable unless they create correctness risk.
- Keep pricing oracle metadata wrappers for `predict.move`. Although they duplicate `market_oracle` getters, they preserve the architectural rule that app-layer oracle reads go through pricing.
- Keep settlement selection as earliest valid currently stored post-expiry source across Pyth and BS. This matches the prior design decision without adding historical Pyth caches; settlement uses the lowest available `source_timestamp` that is greater than expiry, with freshness checked separately.
- Superseded in loop 2: initially avoided an explicit settlement hook, but review showed that Pyth-valid settlement was unnecessarily coupled to valid BS pushes.
- Future source timestamp checks are part of source ingestion/update, not pricing read policy. Pricing still uses the conservative `min(source_timestamp, update_timestamp)` freshness timestamp.

Verification:
- `/Users/aslantashtanov/.local/bin/sui move build --path packages/predict` passed after fix batch 1.
- `/Users/aslantashtanov/.local/bin/sui move test --path packages/predict --gas-limit 100000000000` passed after fix batch 1: 43/43.
- `npx tsc -p packages/predict/simulations/tsconfig.json --noEmit` passed after simulation wiring update.

### Loop 2

Status: completed.

Agents:
- Full flow regression review: `Galileo` (`019e12c0-4cd8-7a02-9de2-dece6584f272`), completed.
- Public API/dependency simplification review: `Harvey` (`019e12c0-7c19-7be2-9e78-06cd0f665b9a`), completed.

Findings:
- Fixed loop 2 finding: Pyth-valid settlement was blocked by BS update validation. Added `market_oracle::settle_if_possible` as a keeper-callable oracle-only hook, and `update_block_scholes_prices` can now pre-settle when Pyth is already a valid earlier-or-equal candidate relative to the supplied BS timestamp.
- Partially addressed loop 2 finding: earliest valid Pyth cannot be perfectly preserved by a shared latest-only `PythSource` unless each market is settled promptly or PythSource stores per-expiry history. We chose the simpler keeper settlement hook, preserving mint/redeem read-only and avoiding per-market mutable Pyth caches.
- Fixed loop 2 simplification: `block_scholes_basis` is now `public(package)` instead of public, keeping the derived pricing primitive out of the external oracle surface.
- Fixed loop 2 simplification: freshness timestamp helpers are centralized in `oracle_time.move`; both `pricing.move` and `market_oracle.move` use it.
- Fixed loop 2 simulation cleanup: removed unused `expiry` from simulation state.
- Fixed loop 2 stale comment: settled redeem delta comment now describes burning settled liability and returning payout.

Decisions:
- Carry forward loop 1 gold-standard decisions unless a concrete correctness issue requires revisiting them.
- Add oracle-only `settle_if_possible` despite previously avoiding an explicit settle API. This does not violate the gold standard because it lives in the oracle write module, keeps user hot paths read-only, and exists only to improve settlement liveness from existing source state.
- Do not store per-expiry Pyth settlement candidates in `PythSource` or `MarketOracle` in this pass. That would add mutable cache/storage complexity and shared-object write coupling. Operators/keepers are expected to call oracle settlement promptly after post-expiry Pyth updates if they want Pyth to freeze first.

Verification:
- `/Users/aslantashtanov/.local/bin/sui move build --path packages/predict` passed after loop 2 fixes.
- `/Users/aslantashtanov/.local/bin/sui move test --path packages/predict --gas-limit 100000000000` passed after loop 2 fixes: 43/43.
- `npx tsc -p packages/predict/simulations/tsconfig.json --noEmit` passed after loop 2 fixes.

### Loop 3

Status: completed.

Agents:
- Oracle write/state review: `Russell` (`019e12c9-0a55-7022-8cb3-5e9a8bcea605`), completed.
- Pricing/read-policy review: `Gibbs` (`019e12c9-0aab-73d1-85b9-a26cb4deb6d9`), completed.
- App/vault flow review: `Feynman` (`019e12c9-0ac8-77a3-b390-410da2d05a50`), completed.
- Public API/surface review: `Goodall` (`019e12c9-0ad4-74f1-9328-9241bef7e61b`), completed.

Findings:
- Fixed loop 3 auth issue: `market_oracle::settle_if_possible` is now cap-gated with the same `MarketOracleCap` used for BS/SVI updates.
- Fixed loop 3 idempotency issue: `settle_if_possible` now returns `false` for already-settled or non-pending markets through the internal status gate instead of aborting on settled markets.
- Fixed loop 3 simplification: removed the pre-settlement/early-return branch from `update_block_scholes_prices`; BS updates now validate/apply BS data, then attempt settlement. The explicit settlement hook handles settlement-only calls.
- Fixed loop 3 precision issue: Pyth settlement eligibility now compares Pyth microsecond source timestamps directly against expiry milliseconds, and stores ceil-rounded milliseconds for Pyth settlement source timestamps so post-expiry sub-ms ticks remain valid at the read-policy layer.
- Fixed loop 3 bounds issue: BS basis is computed with `u128` and checked against basis bounds before casting to `u64`, avoiding VM cast aborts for extreme operator inputs.
- Fixed loop 3 registry issue: market creation now requires the supplied `PythSource` to match the registry's canonical feed-to-source mapping, not only the feed id.
- Fixed loop 3 pricing duplication: settled range payout now lives in `pricing.move`; `RangeKey` no longer owns settled payout math.
- Fixed loop 3 compaction issue: compacted settled redemption can now happen through `redeem_compacted_permissionless` without passing the terminal `MarketOracle`, and `refresh_oracle_mtm` is a no-op for compacted oracles.
- Fixed loop 3 API cleanup: pure pricing metadata/config/quote/curve getters that are only used internally are `public(package)`; `pricing::settlement_price` remains public because it enforces read-policy validation.
- Fixed loop 3 simulation issue: resume state now validates the required `pythSourceId` and reports that old artifacts need setup rerun.
- Fixed loop 3 fee safety issue: utilization multiplier now has a hard 10x ceiling.
- Fixed stale comments around quote assets, settled redemption, and compaction.

Decisions:
- Settlement policy is "earliest valid currently stored source after expiry" across Pyth and BS, not historical first Pyth tick. Preserving historical Pyth ticks would require per-expiry mutable caches or settling every market during Pyth updates, both of which violate the simplicity goal for this pass.
- BS can settle immediately after expiry if it is the earliest valid currently stored post-expiry source. This is intentional under the current earliest-valid-source policy, not a Pyth-grace-period design.
- Registry/create-market is allowed to read `PythSource` directly because it is setup/source-binding validation, not app-facing price read policy.
- Raw oracle source getters remain public for core observability; app execution modules still route read policy through `pricing.move`.

Verification:
- `/Users/aslantashtanov/.local/bin/sui move build --path packages/predict` passed after loop 3 fixes.
- `/Users/aslantashtanov/.local/bin/sui move test --path packages/predict --gas-limit 100000000000` passed after loop 3 fixes: 43/43.
- `npx tsc -p packages/predict/simulations/tsconfig.json --noEmit` passed after loop 3 fixes.
- `git diff --check` passed after loop 3 fixes.

### Loop 4

Status: completed.

Agents:
- Oracle write/state review: `Huygens` (`019e12d2-5412-74c0-b05f-8b4ed8c1691e`), completed.
- Pricing/vault/app flow review: `Ptolemy` (`019e12d2-5469-77b3-a9a3-41dd0a9b3fac`), completed.
- Public API/surface review: `Ramanujan` (`019e12d2-5472-75f2-9793-4311aec8ce09`), completed.

Findings:
- Fixed loop 4 timestamp precision issue: Pyth source ingestion now rejects future timestamps at microsecond precision, and terminal settlement stores `settlement_source_timestamp_us` rather than ceil-rounded milliseconds.
- Fixed loop 4 settlement-read invariant: `pricing::settlement_price` validates `settlement_source_timestamp_us > expiry_ms * 1000`.
- Fixed loop 4 idempotency issue: cap-gated `market_oracle::settle_if_possible` returns `false` for non-pending markets before validating the Pyth source object.
- Fixed loop 4 payoff-policy duplication: `pricing::settled_up_price` is package-level and `strike_matrix` uses it for settled MTM and compaction.
- Fixed loop 4 API clarity: raw oracle settlement getter is now named `raw_settlement_price`, while validated public reads stay in `pricing::settlement_price`; `MarketOracleCap` id getter is package-only.
- Fixed loop 4 comments/names: compacted-vs-dense vault redemption comments are accurate, simulation Pyth stub no longer references the deleted oracle module, and simulation builders use `createMarketOracleTx` / `updateBlockScholesPricesTx`.

Decisions:
- Keep `update_block_scholes_prices` as "validate/apply BS, then maybe settle". The explicit cap-gated `settle_if_possible` is the settlement-only path; reintroducing a pre-validation branch would make the BS update entrypoint do two jobs again.
- Keep raw oracle source getters public for core observability. They are explicitly raw and app execution continues to read through `pricing.move`.
- Keep existing settled dual-state APIs that accept Pyth/MarketOracle for backward app ergonomics, while adding `redeem_compacted_permissionless` for the oracle-free compacted closeout path.

Verification:
- `/Users/aslantashtanov/.local/bin/sui move build --path packages/predict` passed after loop 4 fixes.
- `/Users/aslantashtanov/.local/bin/sui move test --path packages/predict --gas-limit 100000000000` passed after loop 4 fixes: 43/43.
- `npx tsc -p packages/predict/simulations/tsconfig.json --noEmit` passed after loop 4 fixes.
- `git diff --check` passed after loop 4 fixes.

### Loop 5

Status: completed.

Agents:
- Final correctness/simplicity convergence review: `Carver` (`019e12db-2270-75d3-8ae9-6da6b95a4fef`), completed.
- Final API/surface/hygiene convergence review: `Cicero` (`019e12db-22c6-78a1-acc6-aa52c9b2fdd9`), completed.

Findings:
- Final correctness reviewer found no material correctness or simplification issues in the current diff.
- Fixed final hygiene finding: simulation builder naming now uses `createMarketOracleCapTx`, `createMarketOracleTx`, and `updateBlockScholesPricesTx`.
- Final hygiene finding: `oracle_time.move` must be added in the final commit; tracked as a staging requirement rather than a code change.
- Final hygiene finding: PR body must be updated because it still described settlement as requiring effective timestamp after expiry.

Decisions:
- No further architectural changes needed in this pass. Remaining low-level ergonomics around dual settled/live public APIs are intentional compatibility choices, with oracle-free compacted closeout available for the path that benefits from it.

Verification:
- `npx prettier-move -c packages/predict/sources --write` passed on final tree.
- `/Users/aslantashtanov/.local/bin/sui move build --path packages/predict` passed on final tree.
- `/Users/aslantashtanov/.local/bin/sui move test --path packages/predict --gas-limit 100000000000` passed on final tree: 43/43.
- `npx tsc -p packages/predict/simulations/tsconfig.json --noEmit` passed on final tree.
- `git diff --check` passed on final tree.
