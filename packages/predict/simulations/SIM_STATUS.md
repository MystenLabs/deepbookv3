# Simulation Harness — Consolidation Rewire Status

The consolidation (oracle → propbook feeds, strikes → absolute ticks, dense NAV
matrix → payout-tree walk, sync → async privileged flush, no-spot market creation,
`predict_math` → `fixed_math`) changed the contract deeply. This harness is a
localnet/Python **economic-parity** tool, so its correctness is ultimately defined
by a full `run.sh` localnet parity run.

## Done + lightweight-verified (no localnet needed)
- **`src/runtime.ts` / `src/sim.ts` / `src/env.ts` / `src/shared.ts`** rewired to the
  propbook flow: Predict `register_underlying` +
  Propbook `create_and_share_pyth_feed` / `create_and_share_block_scholes_feed`
  + admin `bind_pyth_to_underlying` / `bind_block_scholes_to_underlying`; spot
  via `pyth_feed::update`;
  surface via `block_scholes_oracle::update::new_update` → `block_scholes_feed::
  update` (no writer cap); `create_expiry_market` taking the propbook
  `OracleRegistry` + the canonical underlying id + tick size + the lifecycle cap
  (binding-validated, no spot, one returned id); `mint` taking the
  `(lower_tick, higher_tick)` tick pair (no packed range key); the privileged flush
  start (`start_pool_valuation` + AdminCap);
  event normalizers swapped to the propbook + async-LP events. **`npx tsc --noEmit`
  is clean.**
- **`python_indexes/strike_nav_matrix.py` DELETED** (the dense NAV matrix is gone);
  `python_replay.py` NAV now mirrors the exact `current_nav` = free cash −
  (`walk_linear` − leveraged `correction`), floored, with no conservative band.
- **`python_replay.py`** moved to the absolute-tick model (orders carry
  `lower_tick`/`higher_tick`; raw strike = tick·tick_size; no grid centering); the
  withdraw-band fee is removed. **`python3 -m py_compile` is clean** for every changed
  file. **`bash -n run.sh` is clean.**

## Remaining — REQUIRES a localnet `run.sh` parity run to confirm
Flagged in-code with `TODO(sim-parity)`:
1. **Async LP supply/withdraw + flush cadence.** The sync `supply`/`withdraw` (which
   returned a PLP coin) became `request_*` + a privileged flush that delivers fills via
   the balance accumulator (no coin returned). The CSV has no flush row, so the runner
   must synthesize flush txs; the per-row vs batched cadence, the withdraw-escrow source
   (the manager holds PLP as accumulator credit, not a coin), and the request-vs-flush
   balance timing must be reconciled against a real run. `sim.ts::executeRow` currently
   enqueues `supply` and throws on `withdraw`; the Python mirror models request+flush
   together — the two are not yet aligned on the flush half.
2. **Vault bootstrap funding** (`setupSimulation`) — the synchronous vault seed must
   become `request_supply` + a bootstrap flush (1:1 mint needs empty NAV) +
   `rebalance_expiry_cash`; ordering vs market creation needs a localnet run.
3. **Canonical per-row event sequence parity** — the field vocabulary is aligned across
   both mirrors, but the exact `records[].updates` sequence (LP rows especially) can
   only be confirmed by diffing a real localnet `local_data.json`.
4. **Settlement prefix** — the Python tree stays raw-strike-keyed; the contract uses
   tick-keyed `prefix_limit_tick = ceil(settlement/tick_size)`. On-chain settlement is
   stubbed (`is_settled()` always false), so this is not localnet-checkable until
   settlement-v2.
5. **`run.sh` publish flow is STALE (documented, not blindly rewired).** Before a
   localnet run it must: rename the `predict_math` publish phase to `fixed_math`; add
   publish phases for `block_scholes_oracle` and `propbook` (propbook needs the same
   pyth_lazer/wormhole dep-replacement linking as predict); capture the shared
   `OracleRegistry` id from propbook's init; rewrite the predict `Move.toml`
   dep-injection to inject `fixed_math`/`propbook`/`block_scholes_oracle`; and emit the
   new env vars (`FIXED_MATH_PACKAGE_ID`, `PROPBOOK_PACKAGE_ID`,
   `BLOCK_SCHOLES_ORACLE_PACKAGE_ID`, `ORACLE_REGISTRY_ID`, and
   `ORACLE_REGISTRY_ADMIN_CAP_ID` — the propbook `RegistryAdminCap` owned by the
   publisher, now needed for the `bindFeedsToUnderlyingTx` setup step that
   canonical-binds both feeds before `create_expiry_market`) that `env.ts` now requires.

**Bottom line:** the oracle/creation/mint/redeem/NAV/tick rewire is done and
mechanically verified; the async-LP flush economics and the run.sh localnet publish
flow are structurally rewired/documented but parity-unverified — a full localnet
`run.sh` run is required before the Python replay can be trusted to match the contract.
