# Predict Simulations

This directory is a localnet and Python replay harness for the `predict`
package. It simulates protocol behavior and economic activity, not client
latency.

The current topology is intentionally narrow: one pool vault, one expiry market,
one Propbook source set, one manager, and many orders. The generated CSV is the
transaction ledger. Each row is one executable transaction, and only these row
actions are supported:

-   `oracle_mint_ptb`: update Pyth plus Block Scholes spot/forward/SVI data and
    mint one order in one PTB.
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

For ad hoc localnet-only NAV stress runs, reuse the benchmark path:

```bash
SIM_STRESS_MINT_DUPLICATES=24000 SIM_GAS_BUDGET=5000000000 bash run.sh --skip-analysis
```

`SIM_STRESS_MINT_DUPLICATES=N` rewrites the in-memory workload to replay only
generated mint rows, appending 100 duplicate mint calls to each stress mint PTB.
The flag value is the target total mint count; the runner rounds it up to a full
100-mint PTB. The generated CSV is left unchanged, so stress mode requires
`--skip-analysis` and defaults its synthetic flush to the final mint PTB unless
`SIM_FLUSH_AFTER` is set. To keep the run focused on mint growth plus the final
NAV walk, stress mode scales normal capital from the rounded stress mint count,
front-loads the scaled expiry allocation as initial expiry cash, and suppresses
the normal every-100-row expiry-cash rebalances. Stress mint PTBs use a fixed
high gas budget because this mode does not benchmark individual mint gas;
`SIM_GAS_BUDGET` still controls the final NAV flush transaction.

## Algebra And Dust Proof Bundle

A source-pinned Python proof bundle establishes the money-math dust, algebra, and
saturation properties of the `predict` package. It is anchored to contract
baseline commit `eaab2d89` and reads the Move sources directly. The SHA-256
content digest of `packages/predict/sources/**` is a freshness gate, while stable
call-site identities and exact operator bindings independently connect each
rounding certificate to the implemented Move expression. A source edit, digest
mismatch, new unclassified arithmetic, or rounding-direction mutation breaks the
checks even if the expected digest is refreshed. Run the modules and their proof
runners from this directory:

```bash
python3 algebra_trace.py
python3 dust_invariants.py
python3 money_math_inventory.py
python3 math_dust_proofs.py
python3 algebra_minimality.py
python3 economic_lifecycle_proofs.py
python3 payout_tree_proofs.py
python3 saturation_proofs.py
python3 partial_close_proofs.py
python3 -m unittest discover -v -s . -p "test_*.py"
```

Each module prints a structured JSON bundle; the paired `test_*.py` files are the
deterministic proof runners that assert it. `algebra_trace.py` writes an operation
DAG and a knot report under `runs/algebra-trace/`; `dust_invariants.py` writes its
typed collapse ledger, NAV bid/ask mutation matrix, and stateful lifecycle checks
beside them, and its source census classifies fixed-point, raw-integer, clamp,
`Approx`, and custody arithmetic in every Predict Move source. `math_dust_proofs.py`
gives each money-collapse function an exact-rational rounding-direction certificate,
names its residual owner, and verifies its exact source operator bindings; its
negative-control test flips the trading-fee direction and requires the aggregate
proof to turn red. `economic_lifecycle_proofs.py` and `payout_tree_proofs.py`
reconcile cash-state lifecycles and bounded live/settled aggregation, including the
current one-product signed shared-boundary valuation. `saturation_proofs.py`
classifies every remaining `saturating_sub`/`saturating_add` site and retains the
source-complete induction that justified the now-landed removal in
`pool_accounting::available_expiry_funding`; the induction covers every writer of
the funding fields with a fail-closed writer scan and transition lemmas, not the
bounded state search alone. `partial_close_proofs.py`
proves per-close floor conservation and survivor bias, shows the live-close
`saturating_sub` is semantically required, and exposes the reachable,
sequence-dependent discounted-proceeds dust (splitting a close is not net-proceeds
path-independent under stake discount and builder fees) as an open policy question:
the aggregate stays red while any reachable trader-favored split remains, the
advantage is small and non-monotone in slice count, and no universal maximum is
claimed. Every reported result carries a `result_strength` tag — universal
proof, exhaustive search over a stated finite domain, or concrete reachable
witness.

External availability corpora are not embedded in this public repository. Pass an
ignored aggregate JSON with `python3 dust_invariants.py --availability-evidence
<path>` to attach separately reproduced availability results and their corpus and
runner digests to a generated proof bundle.

## File Map

-   `run.sh`: orchestrates fresh full runs and Python-only runs.
-   `data/scenario_dataset.csv`: ignored local source data with paired SVI/price
    snapshots.
-   `data/scenario_config.json`: source expiry/settlement values, normal/long
    capital sizing, mint spend ranges, fee-ramp settings, cadence allocation,
    initial expiry cash, admission-leverage setup, and protocol knobs. Localnet
    setup applies the normal capital sizing, cadence allocation, initial expiry
    cash, Pyth fee-ramp settings, and max admission leverage; other protocol
    values in this file mirror Move defaults for parity and are consumed directly
    by the generator and Python replay.
-   `data/generate_scenario.py`: random normal/long scenario generator.
-   `docs/ANALYSIS_NOTES.md`: current simulation interpretation notes and
    follow-up analysis questions (economics).
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
-   `python_replay.py`: Python economic mirror and derived metric generator,
    including the Move-parity signed shared-boundary NAV center. Pricing values
    used by replay, such as base fee, min fee, and ask bounds, are read from
    `data/scenario_config.json` with Python defaults as fallback.
-   `algebra_trace.py`: mint-centered algebra DAG and knot analyzer covering
    pricing certificates, stored mint atoms, partial close, liquidation,
    settlement, NAV, and LP supply/withdraw.
-   `dust_invariants.py`: typed money-collapse registry, double-entry dust
    ledger, NAV bid/ask proof and mutation matrix, and stateful lifecycle
    invariant analyzer pinned to the tracer's contract baseline.
-   `money_math_inventory.py`: fail-closed, digest-pinned source census with
    exact directed-operator recognition and stable call-site identities for
    fixed-point, raw-integer, clamp, `Approx`, guard, and custody arithmetic.
-   `math_dust_proofs.py`: exact-rational rounding and residual certificates for
    every inventoried money-collapse function.
-   `algebra_minimality.py`: per-function minimality dispositions,
    bit-equivalence counterexamples for candidate rewrites, and the folded
    partial-close and saturation conclusions.
-   `economic_lifecycle_proofs.py`: independent cash-state reconciliation for
    mint fees, live redeem deductions, rebate claims, and exact-amount sizing.
-   `payout_tree_proofs.py`: bounded-exhaustive containment of the fused signed
    boundary center against exact-rational live liability, plus settled
    redemption conservation checks.
-   `saturation_proofs.py`: classification of every `saturating_*` site and the
    source-complete induction proving the one removable outer saturation.
-   `partial_close_proofs.py`: partial-close floor conservation and survivor
    bias, the live-close saturation requirement, and the reachable
    sequence-dependent discounted-proceeds dust with its strength-tagged bounds.
-   `test_*.py`: the deterministic, SHA-pinned proof runners for the modules
    above (see the Maintenance Rules exception).
-   `compare_parity.py`: canonical parity projection and first-difference reporter for localnet/Python economic data.
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
   the expiry-fee template config and max admission leverage, enables the
   one-month market cadence, creates the next cadence expiry market, then seeds
   the Propbook Pyth/Block Scholes feeds for the emitted market
   expiry. Market creation reads no spot; a setup-only rebalance then funds the
   expiry to the configured initial expiry cash target before scenario rows start.
5. Generates `data/generated/normal_scenario.csv` and copies it into the run
   artifacts.
6. Runs Python over the normal scenario to create `python_data.json`.
7. Replays the same normal scenario against localnet. The runner also synthesizes privileged maintenance transactions: standalone expiry-cash rebalances every 100 rows and LP flushes at the configured flush checkpoints. These are real localnet transactions recorded in `local_trace.json` and `local_data.json`, but they are not CSV row actions.
8. Writes `local_trace.json` and `local_data.json`.
9. Renders gas charts from `local_trace.json`.
10. Compares the canonical parity projections of `local_data.json` and `python_data.json`.
11. If parity holds, generates `data/generated/long_scenario.csv`.
12. Runs long Python replay with exact source timestamps and terminal closeout.
13. Writes `economic_summary.json` and renders charts.
14. Deletes generated scenarios and raw long-run JSON.

The exit trap restores temporary Move manifest edits, removes generated
`Pub.*.toml` files, removes generated scenarios, and stops localnet. If a
transaction or chart step fails, the script exits and cleanup still runs.

## Failure Debugging

Every transaction helper writes a full failure artifact before surfacing the
error. Artifacts live under `artifacts/failed_transactions/` and include the
runner label, attempt number, gas budget, sender, raw RPC response or exception,
effects status and gas when available, transaction bytes, a dry-run result or
dry-run error, and the fetched transaction block when the failed response
contains a digest.

If localnet replay aborts after some rows have succeeded, the runner also writes
`artifacts/local_trace.partial.json` and `artifacts/local_data.partial.json`.
These contain the successful transaction prefix in the same schema as the final
trace/data files.

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

Leverage is capped by a smooth admission curve over entry probability. With the
default 3x max admission leverage and `k = 0.2`, the cap is:

```text
1x + (3x - 1x) * p * (1 + k) / (p + k)
```

Leveraged mint rows must also open strictly above their liquidation threshold.

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
lot sizing, fee bounds, dynamic admission leverage, and entry liquidation
threshold before they are written. Hand-authored illegal rows are not repaired by
the runner; they fail loudly in localnet and Python.

## Timestamp Model

The harness intentionally uses two time models.

Normal localnet/Python parity uses synthetic localnet time. The localnet runner
cannot advance the Sui `Clock` through a 24-hour source window without waiting
in real time, so it creates the next one-month cadence expiry and submits oracle
updates with monotonic source timestamps derived from the localnet `Clock`. It
does not use CSV source timestamps for localnet oracle freshness. Contract floors
are static `floor_shares`, so normal replay does not need a separate floor-time
model. The cadence expiry sits outside the normal fee-ramp window, so normal
replay leaves the fee ramp inactive rather than using exact source timestamps.

Long Python replay uses the source timestamps. The scenario generator writes
`replay_timestamp_ms` from `price_checkpoint_timestamp_ms`,
`source_timestamp_ms` from `svi_checkpoint_timestamp_ms`, and
`price_source_timestamp_ms` from `price_checkpoint_timestamp_ms`. It rejects
source data where the selected price timestamp is older than the SVI timestamp
or where replay timestamps move backward. The long Python replay path then uses
`replay_timestamp_ms`, `data/scenario_config.json` expiry/settlement values,
exact-time fee ramps, and Python-only terminal closeout.

The practical rule is:

```text
normal localnet/Python = parity under synthetic localnet time
long Python = real timestamp economic analysis
```

Expiry market creation goes through the registry's cadence config. The localnet
setup enables the one-month cadence with `tick_size`, `admission_tick_size`,
`max_expiry_allocation`, `initial_expiry_cash`, and `window_size`, then snapshots
the configured tick sizes, allocation, and initial cash target into the created
market. It does not derive a centered grid from the first spot. The
generator, Python replay, and localnet runner all use absolute ticks
(`raw_strike = tick * tick_size`) and the finite tick domain
`1..pos_inf_tick - 1`. To cover a higher spot or wider strike set, raise the
cadence tick size and admission tick size in localnet setup and both replay
mirrors together so the three layers stay on the same absolute tick scale.

## Outputs

Full localnet runs can produce:

-   `artifacts/normal_scenario.csv`: the exact generated normal scenario replayed
    by both localnet and Python.
-   `artifacts/local_trace.json`: compact localnet transaction trace with digests,
    gas, and normalized Move event payloads, including runner-synthesized
    maintenance transactions such as LP flushes and expiry-cash rebalances.
-   `artifacts/local_data.json`: cleaned localnet economic projection.
-   `artifacts/local_trace.partial.json`: successful localnet trace prefix
    written when replay aborts.
-   `artifacts/local_data.partial.json`: successful localnet economic projection
    prefix written when replay aborts.
-   `artifacts/failed_transactions/*.json`: full debug payloads for failed setup,
    replay, flush, and rebalance transactions.
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

Localnet/Python parity is a confidence gate, not a proof of every possible terminal state. The normal replay validates that Python and localnet agree on canonical live economics for the same generated CSV rows and runner-synthesized maintenance transactions: oracle refreshes, mints, redeems, passive liquidations, supply, withdraw, queue drains, expiry-cash rebalances, normalized event fields, and tracked state deltas.

`compare_parity.py` removes chain-clock landing timestamps and oracle source timestamps because localnet rebases feed timestamps onto its live `Clock` while Python replays the economic inputs without reproducing that wall clock. It also removes the Move `FlushExecuted` bid/ask certificate fields and Python's independently aggregated center: those diagnostic values can differ by fixed-point dust, while the priced fill outputs and resulting state must still match exactly. Both artifacts retain their full fields; queue depths, pre/post LP supply, fill amounts, maintenance records, and every tracked state value remain parity-gated.

Live pool-sync sweeps increase aggregate pricing credits and can also realize
previously carried protocol profit into the reserve when returned idle cash is
available. Fresh protocol profit materializes only after terminal expiry
accounting applies that expiry's terminal losses and watermarks.

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

-   `valuation.lp_live_mtm_pnl`: active expiry value after the protocol-profit
    exclusion (unmaterialized reserve share plus carried pending protocol
    profit), minus current expiry funding basis.
-   `valuation.active_book_live_pnl`: open-order contribution minus current live
    liability.
-   `flows.trading_fee`: trading fee collected in that transaction.
-   `flows.borrow_fee_accrued`: retained for chart compatibility. It is always
    zero under the current static-floor model.
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

-   Do not grow ordinary product or unit-test coverage under
    `packages/predict/simulations/**`. Verify harness changes with
    `npx tsc --noEmit`, `bash -n run.sh`, a Python replay, or a small
    `bash run.sh --sim_max_rows=N --skip-analysis` smoke run instead. The single
    exception is the deterministic, SHA-pinned algebra/dust/saturation proof
    bundle (see "Algebra And Dust Proof Bundle"): its `test_*.py` files ARE the
    proof runners for the bundle and are kept and run via `python3 -m unittest`.
-   If a Move entrypoint used by the simulation changes generic parameters or its
    signature, audit `src/runtime.ts` for stale `typeArguments` or argument
    lists; otherwise benchmark CI fails only as an external
    `sim exited with code 1`.
-   Gas verdicts must respect run-to-run noise: different `run.sh` invocations
    use different generated scenarios, so treat per-action deltas below the noise
    floor (watch an untouched action like `supply`/`withdraw`) as neutral — only
    a pinned-scenario A/B is a trustworthy signal. Per-op gas is also
    data-dependent (`normal_cdf` has cheap and expensive branches by moneyness)
    and multi-command PTBs amplify per-command cost, so sweep scenarios and
    measure batched ops separately; measured capacity numbers live in
    `../predeploy/evidence/` and the open-items C-1 capacity model.
-   The capacity wall is per-tx computation (`max_gas_computation_bucket`), not
    the gas budget: a tx over it fails `InsufficientGas` regardless of
    `--gas-budget`.
-   One localnet per git worktree: `run.sh` mutates `Move.toml` during publish,
    so concurrent runs must not share a checkout. `SIM_PORT_OFFSET` gives each
    run its own ports; never rewrite the genesis `.blob`/swarm ports (that
    desyncs config from the baked committee). `stress/` holds the parallel
    stress/fuzz infra (read `stress/README.md` first, including the
    `SIM_STRESS_*` knobs in `src/sim.ts`); stress runs need `--skip-analysis`,
    and `SIM_STRESS_LEVERAGE>1` aborting via
    `assert_mint_probability_and_leverage_policy` is correct moneyness-capping,
    not a harness bug.

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
    `1_000_000_000` MIST; set `SIM_GAS_BUDGET` to override it for local stress
    runs.
-   Live leveraged NAV still depends on bounded liquidation plus aggregate floor
    accounting in the Move implementation. That is the core protocol risk being
    explored by this harness, not something the simulator hides.
