---
paths:
  - "packages/predict/simulations/**"
---

# Predict Simulation Rules

Before editing `packages/predict/simulations/**`, read:
- `packages/predict/simulations/README.md`
- `packages/predict/simulations/docs/ANALYSIS_NOTES.md` when touching economics, derived metrics, charts, liquidation policy, risk analysis, or interpretation of outputs.

## Gas / Performance Analysis

- Gas verdicts must respect the simulation determinism caveat: different `run.sh` invocations use different generated scenarios, so treat per-action deltas below the run-to-run noise floor (watch an untouched action like `supply`/`withdraw`) as neutral. Only a pinned-scenario A/B gives a trustworthy signal.
- **The wall is computation, not gas budget.** A tx over `max_gas_computation_bucket` (~5,000,000 computation units on localnet protocol v127; `computationCost_MIST = units × RGP(1000)`) fails with `InsufficientGas` regardless of `--gas-budget`. Capacity OOGs are this wall, not the budget.
- **Per-op gas can be data-dependent.** `range_price`→`normal_cdf` (fixed_math) has cheap (`|d2|>8` constant, `|d2|<SMALL` ~6 Horner) vs expensive (`SMALL..MEDIUM` d2 → `exp_series`) branches, so the SAME pricing eval costs materially more at some strike/forward/SVI than others. The landed NAV price memo removed the pre-memo single-market flush OOG cliff: one market at 5,000 leveraged orders measured ~47-54% of the wall. The remaining capacity question is pool-total and moneyness-sensitive — sweep multiple random scenarios (`stress/`) before trusting a per-op gas number.
- **Multi-command PTBs amplify per-command work.** Batched mint/redeem PTBs are much more expensive than standalone ops, but the 2026-07-01 `mint-batch` discriminator refuted the earlier dirtied-liquidation-book-page explanation: a leveraged mint appended after many 1x mints (which never write the liquidation book) is amplified too. Treat this as command-position / accumulated-transaction-state metering, measure batched ops separately, and never extrapolate from a single-op number.

## Parallel localnet + stress sweeps

- `stress/` holds the parallel-localnet stress/fuzz infra (built during the 2026-06 capacity audit). Read `stress/README.md` before using or editing it.
- `run.sh` honours `SIM_PORT_OFFSET` (→ `--fullnode-rpc-port`/`--with-faucet` + a `client.yaml`-only rewrite) so multiple localnets coexist. **One localnet per git worktree** — `run.sh` mutates `Move.toml` in its packages dir during publish, so concurrent runs must not share a checkout. **Never rewrite the genesis `.blob` / swarm ports** (genesis-disjoint already; rewriting desyncs config from the baked committee). `stress/setup_pool.sh <N>` provisions the worktree pool.
- `src/sim.ts` stress knobs (env-gated, default = current parity behaviour): `SIM_STRESS_MINT_DUPLICATES` (enable + target N mints), `SIM_STRESS_MINT_BATCH_SIZE` (1..100), `SIM_STRESS_LEVERAGE` (force leverage), `SIM_STRESS_SINGLE_STRIKE=1` (isolate `correction_value` from `walk_linear`). Stress runs need `--skip-analysis`.
- `SIM_STRESS_LEVERAGE>1` on a random strike aborts often via `assert_mint_probability_and_leverage_policy` (leverage is moneyness-capped) — correct behaviour, not a harness bug; classify it, don't treat it as failure.

## Common Commands

- Shell syntax check: `bash -n run.sh`
- TypeScript check: `npx tsc --noEmit`
- Small localnet/Python smoke test: `bash run.sh --sim_max_rows=1 --skip-analysis`
- Python-only analysis run: `bash run.sh --python-only`

## Simulation Layers

- Normal localnet/Python replay is the canonical parity path. It uses synthetic localnet time and compares localnet economic events/state against the Python mirror for the same generated normal CSV rows.
- `--sim_max_rows=N` is only a truncated version of the full localnet/Python parity flow for smoke testing. Do not treat it as a separate economic mode.
- Long Python replay is Python-only exact-time economic analysis. It uses source timestamps, settlement inputs, terminal closeout, and derived chart data that localnet does not practically model.
- `python_derived.json` is Python-only observability. It is never compared against localnet parity output.

## Change Boundaries

- Do not add unit tests for `packages/predict/simulations/**`. Make direct implementation changes and verify them with the relevant typecheck, replay, or localnet smoke command instead.
- Do not broadly apply `data/scenario_config.json` values to localnet setup unless the setup intentionally changes. Some values are parity mirrors of Move defaults, some are localnet-replayable setup inputs, and some are long-run Python/economic knobs.
- Keep one CSV row equal to one PTB. Do not infer behavior from adjacent rows or add unsupported row types casually.
- If Move mint admission or pricing changes, update the relevant mirrors deliberately: generator, Python replay, config values, and localnet transaction setup only when localnet behavior actually needs that setup change.
- If a Move entrypoint used by the simulation changes generic parameters or signature, audit `src/runtime.ts` for stale `typeArguments` or argument lists. Otherwise benchmark CI may fail only as an external `sim exited with code 1` error.
- Upgrade-required constants may be mirrored directly in Python. Admin-tunable defaults in `scenario_config.json` should match Move defaults unless the localnet setup is intentionally extended to set them.
- Localnet oracle freshness must use timestamps derived from the localnet Sui `Clock`, not CSV `source_timestamp_ms`, `price_source_timestamp_ms`, or `replay_timestamp_ms`. Those CSV timestamps belong to long Python replay and source-data analysis.
- Market creation is cadence-managed and reads no live spot. Create the market first, read the emitted expiry, then seed Propbook Pyth/Block Scholes data for that actual expiry before the first priced operation or flush.
- Predict strikes are absolute ticks (`raw = tick * tick_size`) snapshotted from cadence config. Keep the generator, Python replay, and localnet runner on the same tick size and finite tick domain.

## Verification

- Shell changes: run `bash -n run.sh` from `packages/predict/simulations`.
- TypeScript-only changes: run `npx tsc --noEmit` from `packages/predict/simulations`.
- Generator or Python replay changes: generate normal and long scenarios, then replay both with `python_replay.py`.
- Runtime/localnet transaction changes: run a small `bash run.sh --sim_max_rows=N --skip-analysis` smoke test from `packages/predict/simulations`.
- Parity-sensitive changes should run the full simulation flow when practical.
