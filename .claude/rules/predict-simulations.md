---
paths:
  - "packages/predict/simulations/**"
---

# Predict Simulation Rules

Before editing `packages/predict/simulations/**`, read:
- `packages/predict/simulations/README.md`
- `packages/predict/simulations/docs/ANALYSIS_NOTES.md` when touching economics, derived metrics, charts, liquidation policy, risk analysis, or interpretation of outputs.
- `packages/predict/simulations/docs/GAS_EXPERIMENTS.md` when analyzing gas/performance, comparing run gas, or proposing contract changes for gas reasons. It logs prior experiments (including dead ends) and the run-to-run noise caveat (scenarios differ per run, so action-level averages are not a controlled A/B by default).

## Gas Experiments

- **Before running or proposing a gas/performance experiment, read `packages/predict/simulations/docs/GAS_EXPERIMENTS.md` first** to avoid repeating logged dead ends.
- When you analyze a gas/performance experiment (a contract change measured for gas, a run-to-run gas comparison, or a perf hypothesis), ask the user **"should I add this to the experiments doc?"** before finishing. If yes, append a compact ~5-line entry to `GAS_EXPERIMENTS.md` in its existing format (date · change · decision, then hypothesis/method/result). Keep the doc tight — do not let entries bloat.
- Gas verdicts must respect the determinism caveat in that doc: different `run.sh` invocations use different generated scenarios, so treat per-action deltas below the run-to-run noise floor (watch an untouched action like `supply`/`withdraw`) as neutral. Only a pinned-scenario A/B gives a trustworthy signal.

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
