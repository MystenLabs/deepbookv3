# DeepBook Incentives — Scoring Engine

Rust crate that computes per-maker reward scores from on-chain order book events.
Runs inside a Nautilus secure enclave, signs results with an ephemeral Ed25519 key,
and returns them for on-chain verification by the `maker_incentives` Move contract.

## Crate Structure

```
src/
├── lib.rs              # AppState, IncentiveError, module re-exports
├── main.rs             # Axum server: /health_check, /get_attestation, /process_data
├── dry_run.rs          # Simulation binary for testing against real data
├── data_validation.rs  # Indexer health checks before scoring
├── scoring.rs          # Lifecycle-based scoring algorithm (symlink → nautilus)
└── types.rs            # Shared types: BCS-compatible, API, scoring config (symlink → nautilus)
```

`scoring.rs` and `types.rs` are symlinks into the Nautilus enclave app directory
so that the same source is used both in the standalone crate and the enclave build.

## How the Formula Works

The incentive formula rewards makers who provide the most concentrated,
two-sided liquidity during the busiest trading periods. The score has three
layers:

```
score = [capital] × [commitment] × [quality]^(1/p)
         depth        loyalty       spread × time
```

| Layer            | What it measures                                              |
| ---------------- | ------------------------------------------------------------- |
| **Capital**      | How much two-sided depth is being quoted (effective size)     |
| **Commitment**   | Loyalty multiplier from consecutive prior scored epochs       |
| **Quality**      | How tight the spread is and how long orders are resting       |

The `p` parameter (default 3) compresses the quality term so that depth remains
the primary differentiator — a maker with 10× the depth but average quality
still scores well.

Trading activity is not scored per-maker. Instead it is captured at the window
level: each hourly window is weighted by its share of total epoch fill volume,
so makers who are present during busy hours earn proportionally more. This is
equivalent to computing a **volume-weighted average** of per-window scores
across the epoch.

### Per-Maker, Per-Window Score

Each epoch (default 24h) is divided into hourly windows. Within each window,
every maker's resting book state is reconstructed from the `order_updates` and
`order_fills` database tables.

**Effective size** — geometric mean of bid and ask depth. Penalises one-sided
quoting (e.g. $1 asks with $10k bids score near zero):

```
effective_size = sqrt( avg_bid_quantity × avg_ask_quantity )
```

**Spread factor** — rewards makers who quote tighter than the pool median. The
pool-wide median is weighted by each maker's effective size so dust placements
can't distort it. `alpha` (default 0.5) controls how aggressively tight spreads
are rewarded. Capped at 10× to prevent any single maker from dominating purely
via spread:

```
maker_spread       = size-weighted average spread across all the maker's resting orders
pool_median_spread = effective-size-weighted median of all makers' spreads in this window

spread_factor = min( (pool_median_spread / maker_spread) ^ alpha, 10 )
```

**Time fraction** — rewards continuous presence. Active duration is the union
of all intervals where the maker had at least one resting order (no double-
counting for multiple simultaneous orders):

```
time_fraction = active_duration / window_duration
```

**Loyalty multiplier** — rewards makers who participate in consecutive epochs.
The multiplier is `min(prior_consecutive_epochs + 1, 3)`, so a new maker starts
at 1× and reaches the 3× cap after 2 consecutive prior epochs:

```
loyalty = min(consecutive_prior_epochs + 1, 3)
```

The per-maker per-window score combines all components:

```
quality            = spread_factor × time_fraction
maker_window_score = effective_size × loyalty × quality^(1/p)
```

### Window Weighting (Activity)

Rather than scoring per-maker fill activity, the system captures trading demand
at the **window level**. Windows with more fill volume are weighted more heavily
in the epoch aggregation, incentivising makers to stay present during busy
periods. A floor prevents quiet-hour windows from being completely worthless:

```
floor = 1 / (2 × num_windows)
window_weight = max( window_volume / total_epoch_volume, floor )
```

This means a maker's epoch score is effectively a **volume-weighted average** of
their per-window scores. A maker who pulls quotes during a high-volume window
earns zero for that window, and since high-volume windows carry the most weight,
this penalises ghosting during volatile periods.

### Epoch Aggregation

```
maker_epoch_score = Σ (maker_window_score × window_weight)   across all windows
maker_share       = maker_epoch_score / Σ all_maker_epoch_scores
payout            = pool_allocation × maker_share
```

### Multi-Layer Quoting

Makers who quote at multiple price levels are handled correctly:

- Quantities across all bid (or ask) orders **sum** into total bid/ask depth
- Spread is a **size-weighted average** across all price levels
- Active duration uses **interval merging** — overlapping orders don't inflate
  the time fraction
- Fills are joined by `maker_order_id`, so a fill on one layer only reduces that
  order's quantity

### Order Lifecycle Reconstruction

Each order's full lifecycle is reconstructed by merging two database tables:

1. **`order_updates`** — `Placed`, `Modified`, `Canceled`, `Expired` events with
   the remaining quantity after each event
2. **`order_fills`** — fill events joined to the maker's order via
   `maker_order_id`, each reducing the resting quantity

The merged timeline gives the exact resting quantity at every point in time. No
sampling or approximation — the time-weighted metrics are computed directly from
the event stream.

## Eligibility (Stake Requirement)

Not every maker with resting orders gets scored. To be eligible for maker
incentives in a pool, a maker must meet the **same stake requirement** that
DeepBook uses for its volume-based maker rebate system. For example, the
SUI/USDC pool on mainnet requires 100,000 DEEP staked.

### How it works

1. A maker calls `pool::stake()` on a DeepBook pool, locking DEEP against their
   `BalanceManager`. This is the same action used for volume-based rebate
   eligibility — no separate registration needed.
2. The DeepBook indexer records `StakeEvent`s in the `stakes` database table
   with `balance_manager_id`, `amount`, `pool_id`, and whether it was a stake
   or unstake.
3. The pool's `stake_required` threshold is fetched from the `trade_params_update`
   table (set by pool governance).
4. When the enclave computes scores, it fetches all stake events for the pool
   up to the epoch end time and computes the net stake per maker
   (`Σ stakes - Σ unstakes`).
5. Only makers with **net stake >= stake_required** have their orders scored.
   Makers below the threshold are excluded entirely — their orders are filtered
   out before lifecycle reconstruction.

### Edge cases

- A maker who stakes then fully unstakes before the epoch ends gets excluded.
- A maker who stakes mid-epoch is still eligible — the stake check is
  cumulative up to epoch end, not per-window.
- If no stake data exists (e.g. the `stakes` table is empty for the pool),
  all makers are scored (backwards-compatible fallback).
- If `stake_required` is 0 in the governance params, any positive net stake
  qualifies.

## Scoring Constants

| Constant                    | Value            | Description |
| --------------------------- | ---------------- | ----------- |
| `SCORE_SCALE`               | 1 000 000 000    | Scores are multiplied by this before converting to u64 for BCS |
| `MIN_SPREAD_BPS`            | 1 (0.01 %)       | Spread floor to prevent VWAP convergence artifacts from inflating spread_factor |
| `MAX_SPREAD_FACTOR`         | 10               | Cap on `spread_factor` — prevents domination purely via tight spread |
| `loyalty cap`               | 3                | `min(consecutive_prior_epochs + 1, 3)` — new makers start at 1×, max 3× |
| `floor` (window weight)     | 1 / (2 × windows) | Minimum window weight so quiet hours still count |

## Tuning Guide

- **`alpha` = 0** — spread doesn't matter, only size and duration count
- **`alpha` = 0.5** (default) — moderate spread advantage, balanced competition
- **`alpha` = 1.5** — aggressive spread competition, strongly rewards tight quotes
- **`quality_p` = 1** — quality has full weight, quality differences dominate over depth
- **`quality_p` = 3** (default) — depth is the primary differentiator; a maker with
  10× the depth but average quality still scores well
- **`quality_p` = 5** — quality is heavily compressed, almost purely depth-driven
- **`reward_per_epoch`** — higher rewards attract more makers; can be adjusted
  without redeploying
- **`window_duration`** — shorter windows (e.g. 15min) give more granular
  activity weighting but increase computation cost

Note: regardless of `alpha`, `spread_factor` is capped at `MAX_SPREAD_FACTOR`
(10×) so no single maker can dominate purely via an extremely tight spread.

## Data Validation

Before scoring begins, two layers of validation run to ensure the input data
is complete and trustworthy. Both are implemented in `data_validation.rs`.

### 1. Indexer Readiness (`validate_indexer_readiness`)

Queries the deepbook-server `GET /status` endpoint (sui-indexer-alt style) and
enforces that the indexer has fully ingested the epoch being scored.

| Check | Fails when |
| --- | --- |
| **HTTP health** | `/status` returns a non-2xx response or unparseable JSON |
| **Top-level status** | `/status` reports anything other than `"OK"` (checkpoint or time lag exceeded) |
| **Required pipelines exist** | A pipeline listed in `required_pipelines` is missing or is a backfill pipeline |
| **Per-pipeline checkpoint lag** | A required pipeline's `checkpoint_lag` exceeds `max_checkpoint_lag` (default 100) |
| **Per-pipeline time lag** | A required pipeline's `time_lag_seconds` exceeds `max_time_lag_seconds` (default 60) |
| **Timestamp coverage** | A required pipeline's `indexed_timestamp_ms` is below the epoch end time, meaning the indexer hasn't ingested all events in the epoch |
| **Configuration consistency** | `min_indexed_timestamp_ms` is set but `required_pipelines` is empty (ambiguous config) |

When `required_pipelines` is configured and no explicit
`min_indexed_timestamp_ms` is provided, `indexer_validation_for_epoch`
automatically sets the minimum to the epoch end timestamp so all required
pipelines must have indexed up to or past the epoch boundary.

### 2. Pool Data Structural Checks (`validate_pool_data`)

Validates the decoded `PoolDataResponse` JSON payload before it enters the
scoring pipeline. Every event row is checked individually.

**Epoch range**
- `epoch_start_ms` must be strictly less than `epoch_end_ms`.

**Pool metadata** (when present)
- `base_symbol` and `quote_symbol` must be non-empty.

**Order events** — each row must satisfy:
- `pool_id` matches the expected pool.
- `order_id` is non-empty.
- `balance_manager_id` is non-empty.
- `checkpoint_timestamp_ms` falls within `[epoch_start_ms, epoch_end_ms]`.
- `original_quantity` and `quantity` are non-negative.

**Fill events** — each row must satisfy:
- `pool_id` matches the expected pool.
- `maker_order_id` is non-empty.
- `checkpoint_timestamp_ms` falls within `[epoch_start_ms, epoch_end_ms]`.
- `base_quantity` and `quote_quantity` are strictly positive.

**Stake events** — each row must satisfy:
- `balance_manager_id` is non-empty.
- `amount` is strictly positive.

**Global**
- `stake_required` must be non-negative.

## Testing

```bash
# Unit tests (scoring algorithm)
cargo test -p deepbook-incentives

# Dry-run simulation against real production data (no enclave needed)
cargo run --bin incentives-dry-run -- \
  --server-url http://your-deepbook-server:8080 \
  --pool-id 0x... \
  --alpha 0.5 \
  --reward-per-epoch 1000
```
