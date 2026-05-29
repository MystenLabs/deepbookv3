# Predict Simulations

This directory is a localnet and Python replay harness for the `predict`
package. It is built to simulate protocol behavior and economic activity, not
client latency.

The current scenario topology is intentionally small: one pool vault, one expiry
market, one oracle, one manager, and many orders. The CSV is the transaction
ledger. Each row is one transaction, including the existing PTB shape:

```text
update_block_scholes_prices + update_svi + mint
```

The main parity target is economic data. Localnet records raw gas/events and then
projects them into a cleaned economic file. Python reads the same CSV and emits
the same cleaned shape. Those cleaned files are compared directly.

## File Map

- `run.sh`: orchestrates fresh runs, resume runs, Python-only runs, localnet
  lifecycle, parity checks, and charts.
- `data/scenario_dataset.csv`: local-only paired oracle price/SVI snapshots used
  as source data for generated scenarios. This file is intentionally ignored so
  raw source data does not get committed.
- `data/scenario_config.json`: source expiry/settlement values, fee-ramp
  settings, and protocol knobs consumed by localnet setup, the generator, and
  Python replay.
- `data/generate_scenario.py`: random scenario generator for normal and long
  flows.
- `src/sim.ts`: localnet setup and CSV replay engine.
- `src/runtime.ts`: Sui transaction builders and execution helpers.
- `src/shared.ts`: CSV parsing, shared schemas, paths, and JSON helpers.
- `python_replay.py`: Python economic mirror and derived metric generator.
- `chart_market_overview.py`: source-window overview of BTC price, mint/redeem
  strikes, overall vault PnL, and live book risk.
- `chart_vault_pnl_fee_coverage.py`: fee components, net liquidation, and net
  risk-compensation mark chart.
- `chart_liquidation_coverage.py`: normalized liquidation pressure and
  liquidation trigger attribution chart.
- `chart_liquidation_priority_budget.py`: liquidation priority ordering,
  scanner policy capture, and head-versus-watermark contribution chart.
- `chart_liquidation_execution_quality.py`: liquidation execution quality chart.
  Chart scripts should be standalone: one script writes one chart file.
- `analyze_liquidation_priority_encodings.py`: standalone order-ID priority
  research tool. It is not called by `run.sh`.
- `analysis/`: ignored scratch directory for standalone research outputs such as
  analyzer CSV/JSON files.
- `runs/`: ignored output directory for local run instances.
- `data/generated/`: ignored temporary generated scenario files.

## How A Full Run Works

`bash run.sh` creates a new instance under `runs/<run-id>/` and runs the full
flow:

1. Generate localnet genesis.
2. Start localnet.
3. Publish DeepBook, DUSDC, the Pyth Lazer stub, and Predict.
4. Create the vault, expiry market, oracle, manager, and seed balances.
5. Generate `data/generated/normal_scenario.csv` from `scenario_dataset.csv`.
6. Run Python over the normal scenario to create `python_data.json`.
7. Replay the same normal scenario against localnet.
8. Write `local_trace.json` with digests, gas, and raw events.
9. Project localnet execution into `local_data.json`.
10. Compare `local_data.json` against `python_data.json`.
11. If parity holds, generate `data/generated/long_scenario.csv`.
12. Run Python over the long scenario to create `python_long_data.json` and
    `python_derived.json`.
13. Render charts from the long-run Python economic data.
14. Keep `economic_summary.json` and charts; delete raw long-run data unless
    `--keep-derived` is set.

`run.sh` installs an exit trap that restores temporary Move manifest edits,
removes generated `Pub.*.toml` files, and stops localnet. If a replay
transaction fails, the script exits and cleanup still runs. Python data may
exist because Python runs before localnet replay; local trace/data are only
written after the full localnet replay succeeds. Raw long-run Python outputs
are preserved on failure unless a successful path reaches the explicit raw-data
cleanup step.

## Run Modes

From the repo root:

```bash
bash packages/predict/simulations/run.sh
```

From this directory:

```bash
bash run.sh
```

Useful flags:

```bash
bash run.sh --setup
bash run.sh --resume <run-id>
bash run.sh --resume <run-id> --sim
bash run.sh --sim_max_rows=100
bash run.sh --python-only
bash run.sh --python-only --sim_max_rows=300
bash run.sh --keep-derived
bash run.sh --skip-charts
bash run.sh --skip-analysis
```

`--sim-max-rows` is also accepted as an alias for `--sim_max_rows`. The
`SIM_MAX_ROWS=100 bash run.sh` environment form is still supported.

`--skip-charts` suppresses chart rendering only. Localnet/Python parity, long
Python replay, and summary generation still run. `--skip-analysis` is the heavier
escape hatch: it skips post-localnet parity, long replay, and charts.

`--python-only` generates the long scenario, skips localnet, and runs only the
long Python economic replay. It writes `python_long_data.json` and
`python_derived.json`, then renders charts unless `--skip-charts` or
`--skip-analysis` is passed. Unless `--keep-derived` is set, raw long-run data is
removed after `economic_summary.json` and charts are written.

`--keep-derived` keeps the raw long-run `python_long_data.json` and
`python_derived.json` files after charts and `economic_summary.json` are written.
By default, the runner deletes those large raw files and keeps only compact
summary data plus charts.

Generate temporary executable scenarios from a local `data/scenario_dataset.csv`:

```bash
python3 data/generate_scenario.py --mode normal
python3 data/generate_scenario.py --mode long
python3 data/generate_scenario.py --mode both
```

Generated files are written under `data/generated/`, ignored by git, and removed
by `run.sh` cleanup.

The generator uses the same mix for normal and long scenarios: 60% mints, 30%
redeems, 5% supply, and 5% withdraw. It does not generate explicit `liquidate`
rows; liquidation coverage charts therefore measure passive liquidation from
normal user flows unless a hand-authored scenario adds manual liquidations.

## Scenario CSV

The CSV is the source of truth for transaction execution. The runner does not
infer grouped actions from neighboring rows, and it does not repair illegal
rows. A legal row must contain the full execution logic for one transaction.

Required columns:

```text
tx,action,spot,forward,a,b,rho,rho_negative,m,m_negative,sigma,risk_free_rate,strike,is_up,quantity,leverage,order_ref,close_quantity,replacement_order_ref,budget,amount,lp_ref
```

Generated scenarios also include `replay_timestamp_ms`, `source_timestamp_ms`,
and `price_source_timestamp_ms`. Localnet ignores those fields. The long Python
replay uses `replay_timestamp_ms` for exact-time floor-index and terminal
analysis; the source and price timestamps are kept as provenance. Normal
generated scenarios keep mint legality conservative for localnet parity by
checking terminal LTV against the flat localnet floor index. Long generated
scenarios check terminal LTV against the exact source replay timestamp.

Supported actions:

- `oracle_mint_ptb`: update Block Scholes prices, update SVI, and mint one
  order in one PTB.
- `update_prices`: standalone Block Scholes price update.
- `update_svi`: standalone SVI update.
- `mint`: mint against the current oracle state. It must not include oracle
  refresh fields; use `oracle_mint_ptb` for update+mint in one transaction.
- `redeem`: redeem the order referenced by `order_ref`.
- `liquidate`: run a bounded liquidation pass with `budget`.
- `supply`: supply DUSDC and bind the resulting PLP coin to `lp_ref`.
- `withdraw`: withdraw the full PLP coin referenced by `lp_ref`.

Quantities are exact on-chain quantities and must already be valid lot-size
multiples. Leverage codes are explicit:

```text
0 = 1x
1 = 1.5x
2 = 2x
3 = 2.5x
4 = 3x
```

`order_ref` and `lp_ref` are local aliases. They keep packed on-chain order IDs
and Sui object IDs out of comparable economic data while allowing later rows to
refer to earlier outputs.

## Outputs

Full localnet runs can produce:

- `artifacts/local_trace.json`: raw localnet trace with transaction digests,
  gas, raw Move events, and local execution context.
- `artifacts/local_data.json`: cleaned localnet economic projection.
- `artifacts/python_data.json`: cleaned Python economic projection.
- `artifacts/python_long_data.json`: cleaned Python economic projection for the
  50,000-row long scenario. Produced after normal localnet/Python parity holds,
  or directly by `--python-only`.
- `artifacts/python_derived.json`: Python-only derived valuation, flow, and
  liquidation-efficiency metrics from the long scenario.
- `artifacts/economic_summary.json`: compact persistent summary of canonical,
  gas, long-run PnL, and liquidation-efficiency metrics. This is kept even when
  raw long-run data is cleaned up.
- `artifacts/chart_market_overview.png`: BTC price and mint/redeem strikes,
  overall vault live MTM PnL, active book PnL, and live book risk.
- `artifacts/chart_vault_pnl_fee_coverage.png`: cumulative fees, net
  liquidation, and MTM risk-compensation mark.
- `artifacts/chart_liquidation_coverage.png`: normalized backlog pressure and
  liquidated value by trigger.
- `artifacts/chart_liquidation_priority_budget.png`: priority ordering quality,
  actual scanner-policy capture, and head-versus-watermark contribution.
- `artifacts/chart_liquidation_execution_quality.png`: liquidation execution
  price versus floor, bad-debt ratio distribution, and net liquidation surplus.
- `artifacts/state.json`: setup state used by resumed replay.

Charts are intentionally rebuilt one file at a time. In a full run, long-run
charts are gated on localnet/Python parity. In a Python-only run, there is no
localnet parity check, so Python data, derived data, and charts are produced
directly.

## Canonical Economic Data

Comparable economic files use schema `predict_economic_v1`:

```json
{
  "schema_version": "predict_economic_v1",
  "scenario": {
    "quantity_scale": "1"
  },
  "records": []
}
```

Each record is ordered by CSV `tx` and contains:

- `input`: normalized inputs for that transaction.
- `updates`: economic updates emitted by the transaction, such as oracle
  updates, mints, redeems, liquidations, supplies, and withdrawals.
- `state`: tracked economic state after the transaction.

All integers are decimal strings. Comparable data intentionally excludes object
IDs, transaction digests, gas, wall-clock latency, and execution timestamps.
Packed order IDs include on-chain timestamps, so canonical files normalize them
into deterministic `order_sequence` values and CSV aliases.

## Parity Contract

Localnet/Python parity is a confidence gate, not a proof of every possible
terminal state. The normal replay validates that Python and localnet agree on
the canonical live economics for the same CSV rows: oracle updates, mints,
redeems, liquidations, supply, withdraw, normalized event fields, and tracked
state deltas.

The long Python replay intentionally extends that validated live mirror with
features the localnet runner cannot model practically: exact replay timestamps,
real expiry/settlement inputs from `data/scenario_config.json`, exact-time
fee-ramp economics, and a direct terminal closeout. The normal localnet parity
market is far enough from expiry that configured fee ramps remain at 1x; the
long Python replay uses source timestamps near expiry, so the same ramp settings
affect mint/redeem fees there. The terminal closeout is Python-only, but it
includes internal checks such as indexed-versus-scanned terminal payout and final
closed state assertions. Use long-run outputs for tuning with this boundary in
mind: parity validates the shared live transaction engine; Python-specific
assertions guard the extra terminal analysis layer.

## Derived Data

`python_derived.json` uses schema `predict_derived_v1`. It is Python-only and is
never compared against localnet:

```json
{
  "step": 1,
  "action": "oracle_mint_ptb",
  "valuation": {
    "vault_value": "...",
    "total_plp_supply": "...",
    "idle": "...",
    "position_value": "...",
    "position_liability": "...",
    "lp_fee_surplus": "...",
    "lp_live_mtm_pnl": "...",
    "active_book_live_pnl": "..."
  },
  "flows": {
    "premium": "...",
    "trading_fee": "...",
    "borrow_fee_accrued": "...",
    "redeem_payout": "...",
    "counterparty_position_value": "...",
    "liquidation_gap": "...",
    "liquidation_surplus": "..."
  },
  "liquidation": {
    "active_count": "...",
    "liquidatable_count": "...",
    "liquidatable_value": "...",
    "liquidated_count": "...",
    "liquidated_value": "...",
    "interval_liquidated_count": "...",
    "interval_liquidated_value": "...",
    "interval_liquidated_value_by_action": {},
    "liquidation_pressure_value": "...",
    "all_passive_required_manual_topup_share": "...",
    "mint_redeem_required_manual_topup_share": "...",
    "rank_bucket_liquidatable_value": [],
    "budget_capture_share": {},
    "policy_capture_share_by_budget": {},
    "head_capture_share_by_budget": {},
    "watermark_capture_share_by_budget": {},
    "missed_share_by_budget": {},
    "budget_needed_for_1pct_value_pressure": "...",
    "budget": "...",
    "scan_active_count": "...",
    "scan_coverage": "...",
    "backlog_remaining_ratio": "..."
  }
}
```

`valuation` is a sampled mark-to-market view after transaction execution.
`lp_live_mtm_pnl` is LP cash above the initial expiry allocation plus LP fee
surplus, minus current live position liability under the replay's live liability
model. `active_book_live_pnl` isolates open-order contribution against current
live liability. Summary fields named `last_sampled_live_*` are the final sampled
live valuation before Python-only terminal closeout, not post-settlement final
state. `liquidatable_count` is the standing backlog of active orders that
satisfy the liquidation predicate after that step's bounded scan.
`liquidatable_value` currently sums liquidatable floor amounts, so read it as a
backlog size signal, not exact vault loss.
`flows.liquidation_gap` is bad debt only (`max(floor - gross, 0)`), and
`flows.liquidation_surplus` is execution surplus above the floor. Comparable
`order_liquidated` updates include the snapshotted `liquidation_ltv`; charts
derive the liquidation threshold as `ceil(floor_amount * 1e9 / liquidation_ltv)`.

`scan_coverage` is `budget / active_leveraged_orders`, capped at `1.0`.
`interval_liquidated_value` is the floor value liquidated since the previous
sampled checkpoint. `backlog_remaining_ratio` is `liquidatable_value /
(liquidatable_value + interval_liquidated_value)` at sampled checkpoints; it is
a coarse interval backlog pressure signal, not a pre/post pass efficiency proof.
`interval_liquidated_value_by_action` is the same interval liquidation value
split by triggering transaction type. `liquidation_pressure_value` estimates new
plus cleared interval liquidation pressure. The required-manual-top-up shares
estimate the portion of that pressure not cleared by either all passive flows or
mint/redeem-only passive flows. Priority fields are sampled once per global
observability checkpoint: `rank_bucket_liquidatable_value` buckets standing
liquidatable value by position in the mirrored liquidation vector, and
`budget_capture_share` preserves the older prefix-only capture metric.
The `policy/head/watermark/missed` budget maps simulate the actual scanner
policy without mutating replay state: `ceil(budget / liquidation_head_scan_divisor)`
head candidates plus the remaining budget from the passive watermark domain.
`budget_needed_for_1pct_value_pressure` is the vector-prefix budget needed to
leave no more than 1% of live liability as standing liquidatable floor value.
`scan_active_count` is sampled before that transaction's liquidation pass, so
`scan_coverage` uses the same denominator the scanner actually saw.
Liquidation attribution summary fields normalize `oracle_mint_ptb` to `mint`,
then classify `mint`, `redeem`, `supply`, and `withdraw` as passive liquidation
triggers and explicit `liquidate` rows as manual triggers.

`flows.borrow_fee_accrued` is modeled in Python. Long generated scenarios use
`replay_timestamp_ms`; older/manual scenarios without exact replay timestamps
fall back to synthetic per-step time. This metric is useful for derived analysis
and future charts but is not parity-validated.

## Current Caveats

- `data/scenario_config.json` mirrors the Move defaults, localnet setup knobs,
  and source settlement inputs used by the long Python replay. If Move defaults,
  admin setup, or fee-ramp policy changes, update this file at the same time.
- The fixture CSV preserves old oracle/SVI row ordering. Some adjacent rows have
  large forward/spot jumps, so current economics are useful for stress testing
  but not a realistic chronological market path.
- Full localnet replay can be gas-heavy when supply/withdraw valuation finds a
  liquidation backlog. The runner default transaction gas budget is currently
  `1_000_000_000` MIST.
- Live leveraged NAV still depends on bounded liquidation plus aggregate floor
  accounting in the Move implementation. That is the core protocol risk being
  explored by this harness, not something the simulator hides.
