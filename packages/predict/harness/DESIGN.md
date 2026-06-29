# Predict Localnet Harness — Design

Status: substrate + Predict layer (mint resolver + lifecycle keeper) built + validated; analyzers + multi-actor scaling next.
Location: `packages/predict/harness/`

## Purpose

A worktree-free Sui **localnet** harness for running the Predict protocol against
**real market data** as a realistic, short-lived **staging simulation**. It spins
up a fresh localnet, deploys the Predict stack, streams live Pyth Pro + Block
Scholes data onto the on-chain oracle, and lets the protocol run. Re-running
against live data sweeps a broad set of real market states — that breadth is the
point, not deterministic replay.

Downstream consumers (analyzers) read a run's trace to answer questions like
"how does moneyness affect gas", "what does the data-structure shape look like
under realistic flow", or "can a strategy drain the PLP" — these are pluggable and
not part of the core.

Non-determinism is a feature; for reproducibility we record the data window and
(later) replay it.

## Two layers

1. **Substrate (`harness up`) — everything up to propbook.** Predict-independent
   (propbook is predict-unaware): a localnet with live, continuously-updated
   propbook oracles. This is built.
2. **Predict layer — builds on top, independently.** Markets/cadences, the
   semantic mint resolver, and the lifecycle keeper run as separate actors against
   the substrate. Resolver + keeper are built; analyzers are next.

## Substrate (`harness up`) — built

```
python3 -m harness up [--seconds N]
```
1. Reserve a slot (file-locked port registry) and stage the Predict package
   closure into a **scratch workspace** — publish from copies so the checkout is
   never mutated (no git worktrees; N localnets run in parallel from one clone).
2. Genesis + start the localnet; publish the closure (`token, dusdc, fixed_math,
   block_scholes_oracle, wormhole, pyth_lazer, propbook, predict(+account)`).
   `deepbook` is not in predict's closure.
3. Init Wormhole (`setup::complete`) + Pyth Lazer (`init_lazer`) + authorize the
   Predict app; write a `run.sh`-format `.env.localnet`.
4. Register the local Pyth trusted signer; create + bind the propbook feeds.
5. Mint + fund a **dedicated updater address**; launch the oracle service.
6. Hold the localnet + updater alive until Ctrl-C (or `--seconds N`).

### Oracle injection
- **Pyth**: pull the decoded price from Pyth Lazer, **re-sign it with the
  localnet's local signer** (`localPyth.ts`; the trusted-signer VAA registers our
  key), submit to `pyth_feed::update`. Real signatures don't verify on localnet —
  the data is real, the signature is local.
- **Block Scholes**: no signing — `block_scholes_oracle::update::new_*` are public
  stub constructors; submit to the BS spot/forward/SVI feeds.
- Each update is stamped with the **provider's real publish timestamp**, clamped to
  `Clock-1` and monotonic ("as if trading the real protocol").

### Continuous updater
A freshness-gated hot loop (~1/s) pushes one combined refresh PTB (Pyth spot + BS
spot + per-expiry forward/SVI) over a **pre-warmed grid of boundary expiries**,
signed by the dedicated updater address (sequential submission = equivocation-safe).
BS serves SVI for any expiry — boundary-aligned expiries are warm (~1s), a cold
off-grid expiry warms up in ~30–60s — so no surface extrapolation is needed.

Behind a `MarketSource` interface so the data source can later become a shared hub
or a recorded stream without touching the updater.

### Providers (keys in `harness/.env`)
- Pyth Lazer `wss://pyth-lazer.dourolabs.app/v1/stream` (`PYTH_PRO_API_KEY`, feed 1 = BTC)
- Block Scholes `wss://prod-websocket-api.blockscholes.com/` (`BLOCK_SCHOLES_API_KEY`, BTC)

## Predict layer — built

Separate actors that attach to the substrate.

### Semantic mint resolver (`spike-mint`)
Turn an instruction like "2x UP @ ~30c, spend $100" into concrete mint args off-chain:
`pricer.ts` ports the on-chain SVI total-variance Black-Scholes tail
(`pricing::compute_nd2`) in float; `resolver.ts` probability-searches the strike,
enforces the moneyness-capped admission curve, and DUSDC-sizes the quantity. Because
the harness pushes the oracle, the resolver prices against exactly the inputs the mint
will see — only math-port drift.

### Lifecycle keeper (`keeper`)
An off-chain-decided tick loop (the "conditional cron"): each tick reads state (an
in-memory market list + the on-chain clock) and assembles the due PTBs — roll the
cadence (create + fund), flush + settle + compact expired markets (one flush values
every active market; settled ones are swept, cash returns to the pool), and liquidate.
Each priced PTB folds in its own oracle refresh so reads are fresh within the same tx.

## Commands
```
python3 -m harness run                 # one localnet publish lifecycle
python3 -m harness run-many N [--concurrency K]   # N publishes through a rolling pool
python3 -m harness up [--seconds N]    # the oracle substrate, held alive
python3 -m harness spike-mint          # B1: resolve + execute one semantic mint
python3 -m harness keeper [--seconds N] [--cadence ID]   # market lifecycle keeper
python3 -m harness status              # slot registry
python3 -m harness cleanup [--instances]
```
Ports auto-allocated; retention = keep-on-failure / delete-on-success.

## Implementation
- **Python** (`harness/`): CLI, slot/port registry, scratch staging, localnet
  lifecycle, publish, oracle/account init, updater-address provisioning, hold.
- **TypeScript** (`harness/ts`, self-contained): `runtime.ts` (PTB builders +
  re-sign), `oracleService.ts` (streaming updater behind `MarketSource`),
  `predictSetup.ts` (shared bring-up + bootstrap), `pricer.ts` / `resolver.ts`
  (off-chain pricing + admission for semantic mints), `mintSpike.ts` (B1),
  `keeperService.ts` (lifecycle keeper), `predictConfig.ts` (testnet-aligned config),
  `localPyth.ts` (local re-sign).

## Remaining
- **Keeper ← shared updater feed**: the keeper currently self-refreshes (per-tick
  `fetchSnapshot`), which duplicates the WS and can time out. Fold it onto the running
  updater's always-fresh feed (one stream) — this also removes the snapshot-timeout
  fragility seen on fast cadences.
- **Substrate hardening** (for multi-hour / parallel holds): rolling grid (roll
  boundary expiries as they pass), updater gas auto-refill, process-group teardown.
- **Trade generator**: many semantic mints/redeems at volume, to drive the keeper +
  liquidation paths with real leveraged orders (today they run with none).
- **Analyzers**: gas-vs-moneyness, structure shape, PLP-drain, invariant probes.
- **Parallel scaling**: one shared market-data hub (single WS pair) → N
  per-localnet updaters via a shared snapshot; record/replay from the hub stream.
- **Slippage guards**: thread a `max_probability` / `max_cost` cap from the resolver
  into the mint (today the mint uses `U64_MAX` — unguarded; deferred with drift).

## Non-goals
- No economic/parity replay in the harness (that lives off-chain).
- No localnet Clock fast-forward (real-time only; short expiries observed live).
- No git worktrees for parallelism.
- Do not modify the Predict contracts.
