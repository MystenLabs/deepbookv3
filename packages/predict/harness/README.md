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
python3 -m harness campaign S1 S2 ... [--timeout S]  # run named strategies in parallel, then analyze
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

**Bring-up** stages the Predict closure into a scratch workspace and publishes it into a
fresh localnet (no checkout mutation → N in parallel from one clone), initializes Wormhole +
Pyth + account, and registers a **local trusted signer** — the harness re-signs the real
Pyth data with its own key (real signatures don't verify on localnet; the data is real, the
signature is local).

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

## Strategies & campaigns

A **strategy** is a code module under `ts/strategies/<name>.ts` exporting a `Strategy`
(`name`, `tickMs`, `maxOps`, `fund`, and an async `tick(ctx)`). The runner
(`traderService.ts`) loads the one named by the `STRATEGY` env (default `fuzz`) and ticks it on
its pace until `maxOps` (run-to-completion) or the run's duration. `tick(ctx)` orchestrates via
the `StrategyCtx`: state readers (`markets()`, `snapshot()`, `held`, `plpShares`) and actions
that wrap the PTB builders + bookkeeping (`mint`, `redeem` partial-or-full, `supply`, `withdraw`,
plus low-level `submitMint` for probes). Add one by dropping a module and registering it in
`strategies/index.ts`.

Built-in: `fuzz` (default — random feasible trades + adversarial probes), `mint-only`
(high-frequency unleveraged mints into the nearest expiry, 10k run-to-completion), `mixed-churn`
(leveraged mints + partial/full redeems + LP supply/withdraw), `liq-churn` (high-leverage
near-the-money orders that knock out, so the liquidation pass + NAV-under-liquidation accounting
are exercised), and `nav-stress` (piles a low-leverage book into ONE 1h market to measure the max
leverage-book size the keeper flush can value in one PTB; `analyze` plots flush gas vs book size and
finds the breakpoint — run with `SIM_GAS_BUDGET=50000000000` so the trader has headroom and the
flush is measured against the protocol gas ceiling).

`campaign S1 S2 …` runs each named strategy on its **own** localnet (all off one shared hub) to
completion, tears everything down, then prints a **per-strategy** `analyze` report + an aggregate
verdict (non-zero exit if the bug oracle flags anything). `--timeout S` caps the run. Per-strategy
trader funding (plus the prod cadence set — 1m/5m/1h, window 3 — every keeper runs) comes from
`strategies/meta.ts`, the single source of truth.

## Requirements

- The `sui` CLI (resolved via `$SUI_BINARY`, `~/.local/bin/sui`, or `PATH`).
- The `~/.move` cache primed with the Pyth Lazer / Wormhole `sui-testnet` branches (a normal
  `sui move build` of predict does this).
- `harness/.env` with `PYTH_PRO_API_KEY` + `BLOCK_SCHOLES_API_KEY` (gitignored; never commit).

## Note

The localnet `Clock` is the validator's real wall-clock and can't be warped, so the sim runs
in **real time** (a 1-minute market takes a real minute); throughput scales by running
localnets in parallel, not by compressing time.
