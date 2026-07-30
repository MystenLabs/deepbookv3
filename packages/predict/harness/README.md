# Predict localnet harness

A worktree-free, **real-data** Sui-localnet staging simulation of the Predict protocol. It
spins up a fresh localnet, publishes the full Predict stack, streams **live Pyth Pro + Block
Scholes** data onto the on-chain oracles, and runs the entire market lifecycle (creation,
trading, settlement, liquidation, PLP supply/withdraw) **in real time** — a self-sustaining
bug-finder and economics sim. Re-running against live data sweeps a broad set of real market
states; that breadth is the point, not deterministic replay.

Self-contained: Python orchestration (`harness/`) + a TypeScript actor package (`harness/ts`).

## Commands

Run as a module from `packages/predict/`:

```bash
cd packages/predict

python3 -m harness up [--traders N] [--replay FILE]  # the full running sim
python3 -m harness up-many N [--traders N]   # parallel: one shared hub -> N localnets
python3 -m harness campaign S1 S2 ... [--timeout S] [--concurrency N]  # parallel strategies, then analyze
python3 -m harness spike-mint                # one-shot: resolve + execute a semantic mint
python3 -m harness analyze                   # report the latest run's trace
python3 -m harness run                       # one localnet publish lifecycle (no sim)
python3 -m harness run-many N                # N publishes through a rolling pool
python3 -m harness status                    # the slot registry
python3 -m harness cleanup [--instances]     # reclaim stale slots + orphan dirs
```

Ports are auto-allocated (no port flags); instance state lives under `.localnets/`
(gitignored). Retention: `run` keeps-on-failure / deletes-on-success; `up`/`campaign` keep the
trace + last-state JSONs but trim the heavy scratch (validator DB + staged closure) on teardown,
so runs don't accumulate — `cleanup --instances` clears the leftover traces.

## How it works

**Two layers.** Python orchestrates (bring-up, slot/port registry, publish, oracle init,
process supervision, teardown); TypeScript actors drive the protocol. They coordinate via
on-chain state plus **atomically-written** shared JSON in the instance dir (`feeds.json`,
`snapshot.json`, `markets.json`).

**Bring-up** stages the Predict closure into a scratch workspace, compiles the canonical Testnet dependency graph, and records fresh localnet addresses in the workspace's `Pub.sim.toml` (no checkout mutation → N in parallel from one clone). It then initializes Wormhole + Pyth + account and registers local trusted signers for the disposable Pyth and Block Scholes verifier packages.

Upstream packages are exported from their exact commits. Their disposable lockfiles—and Block Scholes' copied explicit framework pins—are resolved against the localnet's Sui framework so normal dependency verification stays enabled; canonical upstream and repository files remain unchanged.

**Sui transport** uses gRPC for reads, transaction resolution, submission, and receipts. The adapter resolves only the transaction kind with checks disabled, attaches explicit sender/gas data, and submits signed bytes: the SDK's default checked full-PTB simulation is not execution-neutral on an idle localnet because `Clock` advances only when a transaction lands.

**Three actors, one stream:**
- **Updater** — the sole market-data consumer: streams the full `real_time` Pyth spot + Block
  Scholes per-expiry forward/SVI, clamps each timestamp to `≤ Clock−1` (monotonic), and pushes
  them onto the on-chain feeds ~1×/s. Writes `snapshot.json`.
- **Keeper** — the lifecycle driver: each ~15s tick it **reconciles the active markets from
  chain**, settles + flushes expired markets, liquidates live ones, and rolls new markets.
  Crash/restart-safe (chain-reconciled, supervised).
- **Traders** — each runs ONE pluggable **strategy** (selected by the `STRATEGY` env; default
  `fuzz`) against the shared files: mints / redeems / leverage / LP supply+withdraw, plus a
  fraction of deliberately-invalid orders to exercise the admission + slippage guards.

**Settlement** is production-faithful and independent of the live stream: at a market's expiry
the keeper fetches the **exact spot at that timestamp from the Pyth Lazer history endpoint**,
re-signs it locally, and inserts it at the expiry key so the flush settles the market.

**Scaling & reproducibility** — `up-many` runs N localnets off a single shared market-data hub
(one WS pair); the hub can record its stream and `up --replay <file>` re-plays it (no live WS).

**Analysis** — every actor appends a JSONL trace; `analyze` reports gas-vs-moneyness, the
pool-NAV trend (drain heuristic), and a **bug oracle** that flags any transaction abort not
coming from our own packages (arithmetic/framework errors are the contract-bug signal).

## Signed Block Scholes path

`DirectWsSource` requests SUI-signed Block Scholes batches for the public testnet v1 domain, reads that deployment's `SignerRegistry` over Sui gRPC, validates every subscription acknowledgement, reconstructs the exact BCS value or SVI payload from decimal strings, and recovers the registered secp256k1 key before admitting a value to the shared snapshot.

Block Scholes signatures bind the target verifier package address into the digest, so a testnet signature cannot verify in the freshly published local verifier package. The local harness therefore verifies the provider signature against the public testnet registry, preserves the exact fixed-point integers, SIDs, signs, and model timestamps, then signs the same payload for the disposable local package. The updater still submits the production-shaped atomic PTB: local `verify_and_create_{value,svi}_batch` followed by Predict ingest.

A testnet keeper must not use the local bridge. It should BCS-encode the provider `data`, normalize the split signature's recovery byte from 27/28 to 0/1, submit `r || s || recovery_id || payload` to the matching Block Scholes testnet verifier, and consume the returned gated batch in Predict ingest in the same PTB.

The current Predict stores derive packed Propbook SIDs from the underlying and expiry, so the harness supplies those IDs in the subscription and accepts data only after Block Scholes echoes the complete item, format, and signing domain. Moving to provider-derived SIDs requires an admin-updatable SID-to-feed mapping in the consumer; until that contract surface exists, computing or substituting provider-derived IDs would make the oracle write under keys Predict never reads.

## Strategies & campaigns

A **strategy** is a code module under `ts/strategies/<name>.ts` exporting a `Strategy` (`name`, `tickMs`, `maxOps`, `fund`, optional semantic `done`/`failure`, and an async `tick(ctx)`). The runner (`traderService.ts`) loads the one named by the `STRATEGY` env (default `fuzz`) and ticks it on its pace until semantic completion, `maxOps`, or the run's duration. `tick(ctx)` orchestrates via the `StrategyCtx`: state readers (`markets()`, `snapshot()`, `held`, `plpShares`) and actions that wrap the PTB builders plus bookkeeping (`mint`, partial-or-full `redeem`, `supply`, `withdraw`, and low-level `submitMint` for probes). Add one by dropping a module and registering it in `strategies/index.ts`.

Built-in: `fuzz` (default — random feasible trades + adversarial probes), `mint-only`
(high-frequency unleveraged mints into the nearest expiry, 10k run-to-completion), `mixed-churn`
(leveraged mints + partial/full redeems + LP supply/withdraw), `liq-churn` (high-leverage
near-the-money orders that knock out, so the liquidation pass + NAV-under-liquidation accounting
are exercised), `mint-batch` (batched leveraged mint scaling), `nav-stress` / `nav-stress-atm` /
`nav-stress-multi` (single-market, ATM-cost, and pool-total flush scaling), and
`batch-max-book` / `batch-max-markets` (fast batched fills toward the per-market leveraged cap and
the live-market pool total). Stress strategies that submit large mint PTBs should be run with
`SIM_GAS_BUDGET=50000000000` so the trader has headroom and the keeper flush is measured against
the protocol computation ceiling.

`campaign S1 S2 …` initializes each named strategy's isolated localnet concurrently, runs them from one shared signed-data hub, tears everything down, then prints a per-strategy `analyze` report and aggregate verdict. A semantic strategy exits successfully only after `done` and exits non-zero when `failure` is set; a strategy with neither a positive `maxOps` nor semantic `done` requires `--timeout S`, which bounds the actor without calling it completed. The default simultaneous-localnet capacity is derived from cores and RAM; campaigns above it are rejected unless the operator explicitly raises `--concurrency N` (up to the slot cap). Per-strategy trader funding and the production cadence set come from `strategies/meta.ts`.

Every campaign retains `<campaign-id>-report.json`, `<campaign-id>-hub-metrics.json`, the final hub snapshot, and the optional hub JSONL recording under `.localnets/`. The machine report records wall/setup durations, chain and package IDs, trader outcomes, support-process health, and signed-source acknowledgement/signature counters; per-instance traces remain the source for action, gas, NAV, guard, and capacity metrics.

## Extension backlog (enablers for planned campaigns)

| # | Extension | Enables | Status |
|---|---|---|---|
| 1 | Batched-mint PTB (`runtime.mintBatchTx` + `ctx.submitMintBatch`) | batch scaling probes | shipped |
| 2 | NAV / mark readback (`ctx.currentNav(market)` / `ctx.idleBalance()`) | LP-adversary observability | shipped |
| 3 | Scripted-oracle trajectory (updater follows a configured mark path; keeps the one-stream invariant) | the C-4 LP-adversary + dust-mark-window campaigns (plans on open-items C-4) | designed (approach a), not built |
| 4 | Raw liquidate builder (`ctx.submitLiquidate`) | the unbounded-liquidate-budget probe (open-items H-6) | not built |

## Requirements

- The `sui` CLI (resolved via `$SUI_BINARY`, `~/.local/bin/sui`, or `PATH`).
- A Sui CLI build whose client reads use gRPC; the harness does not call deprecated Sui JSON-RPC methods.
- Network access for any exact Pyth Lazer, Wormhole, or Block Scholes revision that is not already present in the `~/.move` cache; the staging publisher discovers these revisions from the canonical Predict/Propbook manifests and shallow-fetches only missing sources.
- `harness/.env` with `PYTH_PRO_API_KEY` + `BLOCK_SCHOLES_API_KEY` (gitignored; never commit).

## Note

The localnet `Clock` is the validator's real wall-clock and can't be warped, so the sim runs
in **real time** (a 1-minute market takes a real minute); throughput scales by running
localnets in parallel, not by compressing time.
