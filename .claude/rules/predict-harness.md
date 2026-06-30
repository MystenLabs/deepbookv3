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
  blocking subagent** (long runs trip watchdogs). Clean instances between runs
  (`rm -rf harness/.localnets/instances/*`).

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

## Strategies & campaign
- **A strategy is a code module** `ts/strategies/<name>.ts` exporting a `Strategy` (`name`,
  `tickMs`, `maxOps` (0 = duration-only), `fund` (DUSDC the keeper grants its trader),
  `cadence`, `async tick(ctx)`). `traderService.ts` is a thin **runner**: reads the `STRATEGY`
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
  Per-strategy keeper config (cadence/fund) is read from `strategies/meta.ts` — keep that the
  single source (don't duplicate the numbers in Python).

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
- `harness/.env` (PYTH_PRO_API_KEY, BLOCK_SCHOLES_API_KEY) and per-instance `.env.localnet`
  (the local signer private key) are **gitignored and must never be committed or logged**. A
  pre-commit gate aborts on a staged `.env`. Never print a key or the `Bearer` header.

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
