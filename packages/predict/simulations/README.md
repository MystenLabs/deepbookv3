# Predict Simulations

This directory is a localnet and Python replay harness for the `predict`
package. It simulates protocol behavior and economic activity, not client
latency.

The current topology is intentionally narrow: one pool vault, one expiry market,
one oracle, one manager, and many orders. The generated CSV is the transaction
ledger. Each row is one executable transaction, and only these row actions are
supported:

-   `oracle_mint_ptb`: update Block Scholes prices, update SVI, and mint one
    order in one PTB.
-   `redeem`: refresh oracle data and redeem one referenced order.
-   `supply`: refresh oracle data, value the active expiry, and supply DUSDC.
-   `withdraw`: refresh oracle data, value the active expiry, and withdraw one
    referenced PLP coin.

Explicit manual liquidation rows are not generated or replayed. Liquidations are
measured as passive liquidation work performed inside mint/redeem/supply/withdraw
transactions.

## Commands

From this directory:

```bash
bash run.sh
bash run.sh --python-only
bash run.sh --sim_max_rows=100
bash run.sh --python-only --keep-derived
```

Those are the only supported manual runner forms. Unknown manual flags fail
loudly.

`bash run.sh` creates a fresh localnet instance, runs the normal generated
scenario against both localnet and Python, checks canonical economic parity, and
then runs the long Python scenario for economic charts.

`bash run.sh --python-only` skips localnet, generates a long scenario, runs only
the long Python replay, writes summary/charts, and deletes the raw long-run JSON
after charting.

`bash run.sh --sim_max_rows=N` runs the full localnet/Python flow but truncates
the generated normal and long scenarios to the first `N` executable rows. This is
for short manual smoke runs.

`bash run.sh --python-only --keep-derived` keeps
`artifacts/python_long_data.json` and `artifacts/python_derived.json` so charts
can be iterated quickly inside the latest run folder.

The gas benchmark Docker entrypoint uses an internal compatibility mode to run
localnet only and write the legacy `artifacts/results.json` consumed by the
benchmark service. That CI path may read `SCENARIO_PATH` and `SIM_MAX_ROWS` from
the job environment. `SCENARIO_PATH` is treated as source market data in the
same shape as `data/scenario_dataset.csv`; the runner still generates a
temporary executable scenario before replay. This is not a manual simulation
interface.

## File Map

-   `run.sh`: orchestrates fresh full runs and Python-only runs.
-   `data/scenario_dataset.csv`: ignored local source data with paired SVI/price
    snapshots.
-   `data/scenario_config.json`: source expiry/settlement values, normal/long
    capital sizing, mint spend ranges, fee-ramp settings, cadence allocation,
    normal-run terminal-floor setup, and protocol knobs. Localnet setup applies
    the normal capital sizing, cadence allocation, Pyth fee-ramp settings, and
    flat normal-run terminal floor; other protocol values in this file mirror
    Move defaults for parity and are consumed directly by the generator and
    Python replay.
-   `data/generate_scenario.py`: random normal/long scenario generator.
-   `docs/ANALYSIS_NOTES.md`: current simulation interpretation notes and
    follow-up analysis questions (economics).
-   `docs/GAS_EXPERIMENTS.md`: running log of gas/performance experiments on the
    Predict contracts — hypothesis, change, measurement, and keep/revert decision.
-   `charts/chart_*.py`: standalone chart scripts; one script writes one chart
    file.
-   `charts/chart_common.py`: shared chart styling and timeline helpers.
-   `tools/analyze_liquidation_priority_encodings.py`: standalone research tool,
    not called by `run.sh`. It evaluates static order-id priority layouts against
    kept long-run data; the current protocol layout is quantity first, then
    floor shares, then stable encoded order terms with sequence last.
-   `src/sim.ts`: localnet setup and generated CSV replay engine.
-   `src/runtime.ts`: Sui transaction builders and execution helpers.
-   `src/localPyth.ts`: local Wormhole/Pyth key and signed update helpers used
    only by the localnet harness.
-   `src/shared.ts`: CSV parsing, shared schemas, paths, and JSON helpers.
-   `python_replay.py`: Python economic mirror and derived metric generator.
    Pricing values used by replay, such as base fee, min fee, and ask bounds,
    are read from `data/scenario_config.json` with Python defaults as fallback.
-   `sim_artifacts.py`: shared JSON, unit-conversion, and summary helpers.
-   `write_benchmark_results.py`: CI helper that converts `local_trace.json` into
    the legacy gas benchmark `results.json`.
-   `runs/`: ignored output directory for local run instances.
-   `data/generated/`: ignored temporary generated scenario files.

## Full Run Flow

`bash run.sh`:

1. Generates fresh localnet genesis.
2. Starts localnet.
3. Publishes DeepBook, DUSDC, Fixed Math, Block Scholes Oracle, upstream
   Wormhole, upstream Pyth Lazer, Propbook, and Predict. Propbook's package init
   creates and shares the `OracleRegistry` and mints the `RegistryAdminCap` to the
   publisher.
4. Configures a local Wormhole guardian and Pyth Lazer signer, creates the
   vault, registers the Propbook underlying + feeds, binds the feeds, applies
   the expiry-fee template config, applies the flat normal-run terminal floor,
   enables the one-month market cadence, creates the next cadence expiry market,
   then seeds the Propbook Pyth/Block Scholes feeds for the emitted market
   expiry. Market creation reads no spot; a setup-only rebalance then funds the
   expiry to the protocol cash floor before scenario rows start.
5. Generates `data/generated/normal_scenario.csv` and copies it into the run
   artifacts.
6. Runs Python over the normal scenario to create `python_data.json`.
7. Replays the same normal scenario against localnet.
8. Writes `local_trace.json` and `local_data.json`.
9. Renders gas charts from `local_trace.json`.
10. Compares `local_data.json` against `python_data.json`.
11. If parity holds, generates `data/generated/long_scenario.csv`.
12. Runs long Python replay with exact source timestamps and terminal closeout.
13. Writes `economic_summary.json` and renders charts.
14. Deletes generated scenarios and raw long-run JSON.

The exit trap restores temporary Move manifest edits, removes generated
`Pub.*.toml` files, removes generated scenarios, and stops localnet. If a
transaction or chart step fails, the script exits and cleanup still runs.

## Scenario CSV

Required columns:

```text
tx,action,spot,forward,a,b,rho,rho_negative,m,m_negative,sigma,risk_free_rate,strike,is_up,quantity,leverage,order_ref,close_quantity,replacement_order_ref,amount,lp_ref,replay_timestamp_ms,source_timestamp_ms,price_source_timestamp_ms
```

The CSV is the source of truth for transaction execution. The runner does not
infer grouped actions from neighboring rows and does not repair illegal rows.

Quantities are exact on-chain quantities and must already be valid lot-size
multiples. Leverage is the same 1e9-scaled multiplier used by the contracts:

```text
1_000_000_000 = 1x
1_500_000_000 = 1.5x
2_000_000_000 = 2x
2_500_000_000 = 2.5x
3_000_000_000 = 3x
```

Leverage is tiered by entry probability. Rows with entry probability below
`100_000_000` must use 1x. Rows from `100_000_000` up to but not including
`200_000_000` may use at most 2x. Rows at or above `200_000_000` may use the
protocol max of 3x. Leveraged mint rows must also be above their liquidation
threshold at entry and below their terminal liquidation-LTV floor.

`order_ref` and `lp_ref` are local aliases. They keep packed on-chain order IDs
and Sui object IDs out of comparable economic data while allowing later rows to
refer to earlier outputs.

The generator uses the same composition for normal and long scenarios: 60%
mints, 30% redeems, 5% supply, and 5% withdraw. Normal scenarios contain 1,000
rows evenly spaced through `scenario_dataset.csv`; long scenarios contain one
row per source snapshot so exact-time replay does not reuse source timestamps.
Mint quantities are spend-sized: the generator samples a target cash spend from
`data/scenario_config.json`, then derives a valid lot quantity from entry
probability, leverage contribution, and trading fee. This keeps cheap contracts
economically represented without making the CSV runner infer anything after
generation. Generated mint rows are checked against the Python replay mirror for
lot sizing, fee bounds, leverage tier, entry liquidation threshold, and terminal
floor LTV before they are written. Hand-authored illegal rows are not repaired
by the runner; they fail loudly in localnet and Python.

## Timestamp Model

The harness intentionally uses two time models.

Normal localnet/Python parity uses synthetic localnet time. The localnet runner
cannot advance the Sui `Clock` through a 24-hour source window without waiting
in real time, so it creates the next one-month cadence expiry and submits oracle
updates with monotonic source timestamps derived from the localnet `Clock`. It
does not use CSV source timestamps for localnet oracle freshness. To keep this
single-market parity path focused on live transaction accounting rather than
near-expiry floor growth, localnet setup snapshots a flat terminal floor index
for the market and the normal Python replay mirrors that value. The cadence
expiry sits outside the normal fee-ramp window, so normal replay leaves the fee
ramp inactive rather than using exact source timestamps.

Long Python replay uses the source timestamps. The scenario generator writes
`replay_timestamp_ms` from `price_checkpoint_timestamp_ms`,
`source_timestamp_ms` from `svi_checkpoint_timestamp_ms`, and
`price_source_timestamp_ms` from `price_checkpoint_timestamp_ms`. It rejects
source data where the selected price timestamp is older than the SVI timestamp
or where replay timestamps move backward. The long Python replay path then uses
`replay_timestamp_ms`, `data/scenario_config.json` expiry/settlement values,
exact-time floor indexes, exact-time fee ramps, and Python-only terminal
closeout.

The practical rule is:

```text
normal localnet/Python = parity under synthetic localnet time
long Python = real timestamp economic analysis
```

Expiry market creation goes through the registry's cadence config. The localnet
setup enables the one-month cadence with `tick_size`, `max_expiry_allocation`,
and `window_size`, then snapshots the configured tick size and allocation into
the created market. It does not derive a centered grid from the first spot. The
generator, Python replay, and localnet runner all use absolute ticks
(`raw_strike = tick * tick_size`) and the finite tick domain
`1..pos_inf_tick - 1`. To cover a higher spot or wider strike set, raise the
cadence tick size in localnet setup and both replay mirrors together so the
three layers stay on the same absolute tick scale.

## Outputs

Full localnet runs can produce:

-   `artifacts/normal_scenario.csv`: the exact generated normal scenario replayed
    by both localnet and Python.
-   `artifacts/local_trace.json`: compact localnet transaction trace with digests,
    gas, and normalized Move event payloads.
-   `artifacts/local_data.json`: cleaned localnet economic projection.
-   `artifacts/python_data.json`: cleaned Python economic projection for parity.
-   `artifacts/python_long_data.json`: long-run Python canonical data. Deleted by
    default after charts unless `--python-only --keep-derived` is used.
-   `artifacts/python_derived.json`: long-run Python derived valuation, flow, and
    liquidation-efficiency metrics. Deleted by default after charts unless
    `--python-only --keep-derived` is used.
-   `artifacts/economic_summary.json`: compact persistent summary of canonical,
    gas, PnL, and liquidation-efficiency metrics. The artifact list only includes
    files that exist for that run.
-   `artifacts/chart_gas.png`: mint/redeem and supply/withdraw gas costs.
-   `artifacts/chart_market_overview.png`: BTC price, mint/redeem strikes,
    live pre-terminal vault MTM PnL, active book PnL, and live book risk.
-   `artifacts/chart_vault_pnl_fee_coverage.png`: cumulative fees, net
    liquidation, and live pre-terminal MTM risk-compensation mark.
-   `artifacts/chart_vault_risk_profile.png`: PnL, fees, liquidation losses, and
    backlog normalized against expiry funding and active liability.
-   `artifacts/chart_liquidation_coverage.png`: normalized backlog pressure and
    liquidated value by passive trigger.
-   `artifacts/chart_liquidation_execution_quality.png`: liquidation execution
    price versus floor, bad-debt ratio distribution, and net liquidation surplus.
-   `artifacts/state.json`: localnet setup state snapshot.
-   `artifacts/results.json`: legacy gas-benchmark payload written only by the CI
    benchmark compatibility path.

## Parity Contract

Localnet/Python parity is a confidence gate, not a proof of every possible
terminal state. The normal replay validates that Python and localnet agree on
canonical live economics for the same generated CSV rows: oracle refreshes,
mints, redeems, passive liquidations, supply, withdraw, normalized event fields,
and tracked state deltas.

Live pool-sync sweeps increase aggregate pricing credits but do not materialize
protocol profit. Protocol reserves move only when terminal expiry accounting
materializes profit after that expiry's terminal losses and watermarks are
applied.

The long Python replay intentionally extends that validated live mirror with
features the localnet runner cannot model practically: exact replay timestamps,
real expiry/settlement inputs from `data/scenario_config.json`, exact-time
fee-ramp economics, and direct terminal closeout. The parity path assumes the
localnet manager has no active stake and therefore no terminal rebate payout.
The long Python closeout intentionally applies the full eligible rebate after
the protocol's gross-profit offset as a worst-case vault-risk assumption. Use
long-run outputs for tuning with this boundary in mind: parity validates the
shared live transaction engine; Python-specific assertions guard the extra
terminal analysis layer.

Read long-run outputs in two layers:

-   `python_long_data.json` / `economic_summary.long_canonical`: canonical
    transaction economics plus Python-only terminal closeout.
-   `python_derived.json` / `economic_summary.derived`: live per-transaction
    observability sampled before terminal closeout. The market overview, fee
    coverage, and liquidation coverage charts use this live/pre-terminal layer.
    The liquidation execution quality chart reads canonical liquidation events,
    but still plots only liquidation events that occurred before terminal closeout.

Do not use the normal localnet parity run to tune near-expiry economics. Use it
to detect implementation drift between Move events/accounting and the Python
mirror, then use the long Python run for economic tuning.

## Derived Data

`python_derived.json` uses schema `predict_derived_v2`. It is Python-only and is
never compared against localnet.

Important fields:

-   `valuation.lp_live_mtm_pnl`: active expiry value after pending protocol-profit
    exclusion, minus current expiry funding basis.
-   `valuation.active_book_live_pnl`: open-order contribution minus current live
    liability.
-   `flows.trading_fee`: trading fee collected in that transaction.
-   `flows.borrow_fee_accrued`: current open-order floor growth modeled with the
    same floor-share rounding as Move; this is an MTM/accrual view, not realized
    cash.
-   `flows.liquidation_gap`: bad debt, `max(floor - gross, 0)`.
-   `flows.liquidation_surplus`: execution surplus above the liquidation floor.
-   `liquidation.liquidatable_value`: standing liquidatable floor value after the
    step.
-   `liquidation.interval_liquidated_value_by_action`: interval liquidation value
    split across mint/redeem/supply/withdraw triggers.
-   `liquidation.all_passive_required_manual_topup_share`: estimated share of
    interval liquidation pressure not cleared by all passive flows. This means
    active/operator intervention beyond the generated passive user flows, not an
    explicit generated `liquidate` transaction.
-   `liquidation.mint_redeem_required_manual_topup_share`: same estimate using
    only mint/redeem passive flows.
-   `scan_active_count` is sampled before that transaction's liquidation pass, so
    `scan_coverage` uses the same denominator the scanner saw.
-   `risk.expiry_funding_basis`: current net pool funding basis for the expiry.
    This starts at zero after market creation and rises only when PLP pool sync
    sends cash into the expiry; it falls when that same expiry returns cash.
-   `risk.position_liability_over_funding`: live liability divided by expiry
    funding basis.
-   `risk.lp_live_mtm_pnl_over_funding`: live LP MTM PnL divided by expiry
    funding basis.
-   `risk.active_book_live_pnl_over_funding`: active open-book PnL divided by
    expiry funding basis.
-   `risk.liquidatable_value_over_liability`: standing liquidatable floor value
    divided by live liability.

## Maintenance Rules

-   Keep `run.sh` limited to the four documented manual command forms. The hidden
    benchmark compatibility path exists only for the Docker benchmark worker and
    should not grow into a second manual runner interface.
-   Keep generated scenarios on the current CSV shape only. Do not add
    backwards-compatible support for standalone oracle updates, plain mint rows,
    or explicit liquidation rows.
-   Preserve the invariant that one CSV row is one PTB. Do not infer transaction
    behavior from adjacent rows.
-   Keep localnet timestamp-synthetic. Do not add sleeps or wall-clock waiting to
    simulate the 24-hour source window.
-   Treat `data/scenario_config.json` as the simulation mirror of protocol knobs,
    capital sizing, generation sizing, and source settlement inputs. When Move
    defaults, admin setup, fee policy, liquidation policy, or settlement
    assumptions change, update the Python mirror and this config in the same PR.
    Localnet does not run admin setters for every mirrored protocol field; fields
    such as pricing config, liquidation budgets, protocol reserve profit share,
    LTV, and floor premium should remain equal to Move defaults unless localnet
    setup is intentionally extended. Upgrade-only constants are mirrored directly
    in Python, and small fixed pricing defaults are intentionally mirrored
    manually in `python_replay.py` to keep the harness lightweight.
-   Keep raw long-run data temporary by default. Use
    `bash run.sh --python-only --keep-derived` only when iterating on charts or
    inspecting raw records.
-   Keep charts in `charts/` and standalone: one `charts/chart_*.py` script writes
    one chart file. Every chart should include a one-sentence subtitle describing
    what it measures.

## Current Caveats

-   `data/scenario_config.json` mirrors Move defaults, localnet-replayable setup
    knobs, normal/long capital sizing, generation spend ranges, and source
    settlement inputs used by the long Python replay. If Move defaults, admin
    setup, fee-ramp policy, liquidation policy, capital sizing, or settlement
    assumptions change, update this file at the same time.
-   Long-run vault and manager seeds can be larger than normal mode, but expiry
    cash starts at zero and reaches the protocol cash floor only through existing
    PLP pool-sync rebalancing.
-   Full localnet replay can be gas-heavy when supply/withdraw valuation finds a
    liquidation backlog. The runner default transaction gas budget is currently
    `1_000_000_000` MIST.
-   Live leveraged NAV still depends on bounded liquidation plus aggregate floor
    accounting in the Move implementation. That is the core protocol risk being
    explored by this harness, not something the simulator hides.
