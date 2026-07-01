---
paths:
  - "packages/predict/harness/**"
---

# Predict Localnet Harness

Read this before editing anything under `packages/predict/harness/**`. The harness is a
worktree-free, real-data Sui-localnet staging sim for Predict (Python orchestration +
self-contained `harness/ts` TypeScript). `packages/predict/harness/README.md` is the
user-facing overview; this file is the editing-critical knowledge.

## Build & verify
- TypeScript: `cd packages/predict/harness/ts && npx tsc --noEmit` (0 errors before done).
- Python: `python3 -m py_compile harness/*.py` from `packages/predict/`.
- Validate behavior with a real localnet run (`python3 -m harness up --traders N --seconds S`)
  then `python3 -m harness analyze`. Run these in the **main loop or background, never a
  blocking subagent** (long runs trip watchdogs). `up`/`campaign` auto-trim the heavy scratch
  (validator DB `localnet/` + staged closure `workspace/`) on teardown and keep only the trace +
  last-state JSONs, so instances don't accumulate; `python3 -m harness cleanup --instances`
  clears the leftover traces.
- **Never blind-`rm` `.localnets/instances/` while a run may be live.** A bare `rm -rf` deletes a
  *running* campaign's dir out from under it — its keeper/updater then `ENOENT` on every write and
  the trace is lost. Check `python3 -m harness status` first (non-empty slots = a live run), then
  use the **slot-aware** `cleanup --instances`, which skips any dir whose run-id is an active slot.

## Architecture invariants (don't break these)
- **One stream.** Only the updater (`oracleService.ts`) consumes provider WS data; the keeper
  and traders read the updater-maintained on-chain feed + `snapshot.json`. Do not add a second
  provider stream to the keeper or traders.
- **Keeper reconciles from chain.** `keeperService.ts` builds its flush/settlement set each
  tick from `readActiveMarketIds()` (devInspect `plp::active_expiry_markets`), never an
  in-memory authority. The flush values EVERY active market — an on-chain market the keeper
  fails to value bricks `finish_flush` permanently. Never reintroduce an in-memory market
  list as the source of truth.
- **Settlement = Pyth history endpoint.** Settle each expiry by fetching the exact-timestamp
  spot from the Pyth Lazer history endpoint (`fetchExactSpot1e9`, `POST /v1/price`), re-signing
  it locally, and `insert_at` at the expiry key — independent of the live stream. The contract
  requires an observation at EXACTLY the expiry ms (`ensure_settled` → `read_at(expiry)`); do
  not settle with a "latest"/streamed spot.
- **Live stream = `real_time`** Pyth channel (freshest push), clamped to `≤ Clock−1` and
  strictly monotonic (`clampedSourceTimestampMs`) or the on-chain freshness gate aborts.
- **MarketSource seam** — DirectWs / Hub / Replay behind one interface; keep new data sources
  behind it.
- **Oracle grid mirrors the prod cadence set.** The keeper enables + rolls {1m, 5m, 1h} (cadences
  0/1/2, `windowSize` 3 — testnet `deployment.testnet.json`); `GRID_SPEC` warms each cadence's
  `windowSize` boundaries, built from `CADENCES` via `meta.ts`. **Don't widen the grid past BS's
  surface availability** (e.g. the old `60000:6` = 6 consecutive 1m expiries): BS rejects `mark.px`
  for an unmodeled/expired entry and a single bad entry **poisons the whole replace-wholesale BS
  batch**, so the grid silently drains. The cadence partition (1h owns `:00:00`, 5m owns 5-min marks
  off the hour, 1m the rest) makes `keeperService.cadenceOf(expiry)` exact.

## Strategies & campaign
- **A strategy is a code module** `ts/strategies/<name>.ts` exporting a `Strategy` (`name`,
  `tickMs`, `maxOps` (0 = duration-only), `fund` (DUSDC the keeper grants its trader), and an
  `async tick(ctx)`). `traderService.ts` is a thin **runner**: reads the `STRATEGY`
  env (default `fuzz`), loads the module from `strategies/index.ts`, builds the `StrategyCtx`,
  and ticks until `maxOps` (run-to-completion) or `DURATION_MS`. Add a strategy = drop a module
  + register it in `index.ts`; `meta.ts` exposes it to the campaign automatically.
- **Strategies only touch the `StrategyCtx`** (`strategy.ts`) — never call builders/`submit`
  directly. The ctx wraps them with bookkeeping: `mint` (resolve+submit+track+trace), `redeem`
  (partial or full — tracks the replacement order id on a partial close), `supply`/`withdraw`,
  low-level `submitMint` (adversarial probes), `refreshPlp`, `pruneSettled`, `resolve`, utils.
  Every traced record is auto-tagged with the strategy (analyze labels blocks by it).
- **Supply is custody-only; withdraw must read first.** `supply()` uses
  `requestSupplyFromCustodyTx` (pulls from the trader's funded account balance) — NOT
  `requestSupplyTx`, which mints fresh DUSDC and needs the publisher's TreasuryCap (keeper-only; a
  trader signing it aborts "not signed by the correct sender"). `withdraw(shares)` needs `shares ≤`
  the on-chain PLP balance (`refreshPlp()` → `runtime.readPlpBalance`); an over-draw aborts in
  `lp_book` and the bug oracle would flag it as a false positive. Supply/withdraw are **queued**
  (realized only by the keeper flush), so a strategy supplies, then withdraws on a LATER tick.
- **One op per tick, `tickMs ≥ ~1s`** — the open+close same-`Clock`-ms guard
  (`EMintRedeemSameTimestamp`) aborts a mint+redeem of one order in the same ms; pacing avoids it.
- **`campaign S1 S2 …`** (`live.campaign`) runs each strategy on its OWN localnet (named by the
  strategy → `analyze` labels each block) off ONE shared hub, run-to-completion (waits for the
  trader procs to self-exit at `maxOps`, or `--timeout`), then tears down + auto-runs `analyze`.
  Per-strategy trader funding is read from `strategies/meta.ts`, which also emits the prod cadence
  set (1m/5m/1h, window 3) every keeper runs — keep that the single source (don't duplicate in Python).

## Units & clock
- Tick size `$0.01` = `1e7` (NOT 1e9). Quantity / cash / payouts are **DUSDC-native `1e6`**
  (NOT 1e9). Leverage and probability are `1e9`-scaled. Mixing these is the #1 scaling bug.
- The localnet `Clock` is the validator's **real wall-clock — not warpable**. The sim is
  real-time; markets expire at real boundaries; throughput scales via parallel localnets, not
  time compression.
- Testnet oracle freshness is 10s (vs the contract's 2s/3s default) — the one config divergence.

## Resilience invariants
- Shared files (`snapshot/feeds/markets.json`, `hub-snapshot.json`) are written with
  `io.ts atomicWriteFile` (temp+rename). Use it for any new shared file, and guard every
  cross-process JSON parse (a torn read must not throw out of a loop).
- Keeper tick steps are individually isolated (a transient sub-step abort defers that step,
  not the whole tick); liquidate re-filters `live` against a fresh clock.
- Restart-safe: `setupFeedsAndConfig` re-attaches an existing `feeds.json`, `bootstrapPool`
  skips when `plp_total_supply > 0`, and `live.py` supervises the keeper/updater (restart →
  re-attach). Keep setup idempotent.

## Secrets
- `harness/.env` (PYTH_PRO_API_KEY, BLOCK_SCHOLES_API_KEY) is gitignored via `.env`/`*.env`. The
  per-instance `.env.localnet` (local signer private key) + `local_pyth.json` are written at the
  instance-dir root and gitignored via `.localnets/` — note `*.env` does NOT match `.env.localnet`,
  so the `.localnets/` rule is what covers it, and the teardown trim keeps them inside `.localnets/`
  (never exposed). **Never commit or log any of them** — a pre-commit gate aborts on a staged
  `.env`; never print a key or the `Bearer` header.

## Don't
- Don't modify the Predict Move contracts or `dusdc.move` (deployed to testnet) to suit the
  harness — the harness re-signs oracle updates with a local trusted signer instead.

## Bug oracle caveat
- `analyze.py`'s bug oracle is **abort-only**: it flags transaction aborts, NOT a wrong-but-
  *successful* tx (a mis-settlement / NAV error that does not abort). Classification: an abort in
  an INVARIANT module, or ANY `module:code` abort from a non-GUARD module, is **flagged** (likely
  bug); GUARD-module aborts are expected preconditions; HTTP/RPC/consensus strings are transient.
  A `module:code` tag is matched BEFORE the transient substrings, so a numeric abort code (e.g.
  `dynamic_field:500`) is never mis-read as an HTTP status. Adversarial probes wrongly accepted are
  traced as `adversarial-accepted` (a guard gap).
- **The non-zero exit gates on more than flagged aborts**: also `adversarial-accepted`,
  `no-keeper-trace` and (campaign) `missing-trace:<name>` (an instance/strategy that never produced
  a trace), `keeper-stuck` (operational fails with zero successful flush — a bricked settlement/LP
  lifecycle), and `fatal-crash` (a top-level actor crash, a `{fatal:true}` trace).
- **nav-stress measures the per-tx COMPUTATION cap, not the gas budget.** The keeper flush OOGs when
  its `computationCost` hits `max_gas_computation_bucket = 5M units × RGP` (localnet/testnet 5e9 MIST,
  mainnet 5e8 — a protocol constant, so the OOG book size is network-independent), NOT the 50,000-SUI
  `max_tx_gas` budget. `analyze.py` compares `compGas` (the flush trace's computation cost, not net
  `gasOf`) against that cap; the flush's `InsufficientGas` deferral at that book size is the
  nav-stress BREAKPOINT (the measurement) and is excluded from the oracle — don't reintroduce a
  gas-budget ceiling (it both mis-reports the breakpoint and false-flags the OOGs as bugs). See
  `.claude/predict-design/NAV_STRESS_FINDINGS_2026-06-30.md`.
