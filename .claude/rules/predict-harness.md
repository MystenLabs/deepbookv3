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
- `analyze.py`'s bug oracle is **abort-only**: it flags transaction aborts not from our own
  packages (arithmetic/framework). It will NOT catch a wrong-but-*successful* tx (a
  mis-settlement or NAV error that does not abort). `KNOWN_MODULES` aborts = expected guards;
  consensus/equivocation strings = transient. Adversarial probes wrongly accepted are traced
  as `adversarial-accepted` (a guard gap).
