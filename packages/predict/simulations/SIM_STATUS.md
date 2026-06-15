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

## Done + LOCALNET-verified
- **`run.sh` multi-package publish flow (was item 5).** Rewired and confirmed by a
  real localnet run: publishes deepbook, dusdc, **fixed_math**, **block_scholes_oracle**,
  wormhole, pyth_lazer, **propbook**, predict — all link, and `.env.localnet` is written
  with `FIXED_MATH_PACKAGE_ID`, `BLOCK_SCHOLES_ORACLE_PACKAGE_ID`, `PROPBOOK_PACKAGE_ID`,
  `ORACLE_REGISTRY_ID`, `ORACLE_REGISTRY_ADMIN_CAP_ID`. Key mechanics learned:
  - Local deps resolve via the shared `--pubfile-path` ledger (no dep-replacement
    needed); only the **git** deps (pyth_lazer/wormhole) get `[dep-replacements.sim]`
    source+address redirection. The old `predict_math` injection was stale debris and
    is gone.
  - propbook is **new-style** (no `[addresses]`), so when predict builds it from source
    for `--build-env sim` it must keep its injected `[environments] sim` +
    `[dep-replacements.sim]`. Its `Move.toml` restore is therefore **deferred to
    `cleanup()`**, not done inline (old-style deps like deepbook can restore inline).
  - propbook init creates+shares `OracleRegistry` and mints `RegistryAdminCap` to the
    publisher — both extracted from the publish `objectChanges`.
- **Generator absolute-tick migration (was item 0).** `generate_scenario.py` dropped
  `configure_oracle_grid` + the grid-centering assert and uses `align_strike_to_tick`.
  Both normal (1000) and long (12827) scenarios generate and Python-replay clean.
- **Async-LP bootstrap + batched flush + supply + withdraw (was items 1–2).** Verified
  end-to-end on a full 1000-row localnet run (`bash run.sh --skip-analysis`):
  600/600 mints, 50/50 supplies, 50/50 withdraws, 0 skips, 2 flushes (rows 300 & 999),
  no aborts. Key facts:
  - Bootstrap (`setupSimulation`): `request_supply(vaultSeed)` → privileged flush
    (mints PLP 1:1 via the accumulator) → `rebalance_expiry_cash`. Market is registered
    active at `create_expiry_market` (0 cash), so the bootstrap flush DOES value it.
  - Flush cadence is **batched**, synthesized by the runner after the rows in
    `flushCheckpoints()` (default 300, 999; override with `SIM_FLUSH_AFTER`).
  - Withdraw materializes PLP from the manager's accumulator via
    `withdraw_settled<PLP>(@0xacc, shares)` then `request_withdraw` in one PTB.
    **`enable_object_funds_withdraw` IS enabled in localnet genesis** (probed live —
    withdraws executed, didn't abort).
  - Withdraw policy is conservative: shares are drawn only against the bootstrap PLP
    (`availableSettledPlp = vaultSeed`), never crediting batched-flush supplies, so it
    can never over-withdraw; rows that would exceed it skip-and-log (0 skips at current
    sizing). Fixed many stale runtime.ts builders along the way (missing
    `ORACLE_REGISTRY_ID` in mint/redeem/value_expiry; extra `QUOTE_ASSET_ID` in bind;
    missing `config`/`propbook_registry`/`pyth`/`clock` in request/rebalance).

- **Canonical per-row parity (was item 3) — DONE + verified (`Parity OK`).** Full
  `bash run.sh` over a fresh 1000-row scenario passes the gate end-to-end:
  `local_data.json == python_data.json`, then long replay + all charts render. Two
  HEAD regressions from the parallel agent's commits were fixed first:
  - `b646cef8` added `create_expiry_market` grid assert (`expiry % 60_000 == 0`); the
    sim's `EXPIRY_MS = Date.now()+400d` wasn't aligned → setup aborted (MoveAbort 14).
    Now floored to a 60s multiple (`RESOLUTION_PERIOD_MS`).
  - `94160f6d` folded `PoolValued` into `FlushExecuted` and replaced
    `Supply/WithdrawRefunded` with `RequestCancelled`. Dropped the 3 dead sim.ts
    normalizers; folded the valuation fields into `normalizeFlushExecuted`.
  - Parity divergence was **LP-only** (all 26 mint/redeem records matched untouched —
    mint/redeem parity already held). `python_replay` now **bifurcates** the LP path on
    `exact_time`: the parity path (`exact_time=False`) emits request-only records
    (`supply_requested`/`withdraw_requested`) mirroring the localnet runner's indices
    (bootstrap took supply-queue 0) + the conservative withdraw-skip; the long path
    (`exact_time=True`) keeps the synchronous fill model so the economic charts are
    unchanged. The flush is runner machinery (not a CSV row) and is not a parity record.
- **Flush gas on the gas chart.** `runFlush` records a synthetic `flush` trace step
  (via `execute()` for a gas receipt); `chart_gas.py` has a third flush panel.
  Flushes are often gas-**negative** (draining queue rows reclaims storage rebate).

## Remaining
4. **Settlement prefix** — the Python tree stays raw-strike-keyed; the contract uses
   tick-keyed `prefix_limit_tick = ceil(settlement/tick_size)`. On-chain settlement is
   now implemented (passive, exact-ms Pyth at `market.expiry`), but the sim's far-future
   expiry is never reached in a run, so `MarketSettled` never fires and this stays
   un-exercised until a settlement-reaching scenario / settlement-v2.

**Bottom line:** the full simulation pipeline — multi-package publish, generator
absolute-tick migration, async-LP bootstrap/flush/supply/withdraw, AND the normal
localnet/Python parity gate — is localnet-verified end to end at current HEAD. Only the
settlement-prefix parity (item 4) remains, gated on a settlement-reaching scenario.
