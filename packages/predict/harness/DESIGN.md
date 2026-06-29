# Predict Localnet Harness — Design

Status: substrate built + validated; Predict layer next.
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
   semantic mint resolver, keepers, and analyzers run as separate actors against
   the held substrate. This is next.

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

## Commands
```
python3 -m harness run                 # one localnet publish lifecycle
python3 -m harness run-many N [--concurrency K]   # N publishes through a rolling pool
python3 -m harness up [--seconds N]    # the oracle substrate, held alive
python3 -m harness status              # slot registry
python3 -m harness cleanup [--instances]
```
Ports auto-allocated; retention = keep-on-failure / delete-on-success.

## Implementation
- **Python** (`harness/`): CLI, slot/port registry, scratch staging, localnet
  lifecycle, publish, oracle/account init, updater-address provisioning, hold.
- **TypeScript** (currently reused from `simulations/src`): `oracleService.ts`
  (setup + the streaming updater, behind `MarketSource`) on top of `runtime.ts`
  builders + `localPyth.ts` re-sign. Porting this into a self-contained
  `harness/ts` is a tracked follow-up.

## Remaining
- **Substrate hardening** (for multi-hour / parallel holds): rolling grid (roll
  boundary expiries as they pass), updater gas auto-refill, process-group teardown.
- **Predict layer**: mint resolver (devInspect strike search for "2x UP @ ~5c" +
  admission check), keepers (cadence/market-create/rebalance/flush/settlement/
  cleanup), analyzers (gas-vs-moneyness, structure shape, PLP-drain, invariant
  probes).
- **Parallel scaling**: one shared market-data hub (single WS pair) → N
  per-localnet updaters via a shared snapshot; record/replay from the hub stream.
- **Clean TS port** into `harness/ts` (decouple from the legacy `simulations`).

## Non-goals
- No economic/parity replay in the harness (that lives off-chain).
- No localnet Clock fast-forward (real-time only; short expiries observed live).
- No git worktrees for parallelism.
- Do not modify the Predict contracts.
