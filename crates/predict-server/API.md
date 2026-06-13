# Predict Server API

HTTP API over the Predict indexer's Postgres tables. All endpoints are `GET`
and return JSON.

## Conventions

- **NUMERIC values serialize as JSON strings** (DUSDC amounts, quantities,
  strikes, shares — anything stored as Postgres `NUMERIC`). Bounded values
  (timestamps, 1e9-scaled ratios, leverage, counts, indices) are JSON numbers.
  Parse string-typed numerics with a decimal library, never `parseFloat`.
- **Every event row carries the ordering triple** `checkpoint`, `tx_index`,
  `event_index` plus `checkpoint_timestamp_ms`. Feeds are ordered newest-first
  by `(checkpoint_timestamp_ms, tx_index, event_index)`; merge rows from
  different feeds client-side with the same triple. Never order by a domain
  timestamp (`source_timestamp_ms`) — a stale oracle update can land later with
  an older source timestamp.
- **Every row carries `kind`** naming its source table (e.g. `"order_minted"`,
  `"market_activity_1h"`), so interleaved feeds are self-describing.
- **Window params** (all list endpoints): `?start_time` / `?end_time` in unix
  **seconds** (defaults: 0 / now), `?limit` (default 50, cap 500).
- IDs (`0x…` object ids, addresses) are full-length hex strings; `order_id` /
  `position_root_id` / `replacement_order_id` are **decimal** u256 strings.
  Packed order/root ids are **expiry-local** (unique per market, not
  globally): always treat `(expiry_market_id, order_id)` as the key.
- Unknown ids return `null` components (state endpoints), `[]` (feeds), or
  `null` (point lookups) — never 404.

## Status

| Path | Returns |
|---|---|
| `/` | health check (200) |
| `/status` | per-pipeline watermark lag vs latest on-chain checkpoint |

## Raw event feeds (timestamp-windowed)

| Path | Source table(s) |
|---|---|
| `/markets` | `market_created` |
| `/markets/:expiry_market_id/orders` | all 5 order tables, interleaved |
| `/managers?owner=` | `predict_manager_created` |
| `/managers/:predict_manager_id/orders` | 4 manager-scoped order tables, interleaved (excludes `order_liquidated`, which carries no manager) |
| `/managers/:predict_manager_id/staking` | `deep_staked` + `deep_unstaked`, interleaved |
| `/managers/:predict_manager_id/rebates` | `trading_loss_rebate_claimed` |
| `/oracles/:market_oracle_id/prices` | `block_scholes_prices_updated` |
| `/oracles/:market_oracle_id/svi` | `block_scholes_svi_updated` |
| `/oracles/:market_oracle_id/settlements` | `market_oracle_settled` |
| `/pyth-sources/:pyth_source_id/updates` | `pyth_source_updated` |
| `/vaults/:pool_vault_id/supplies` | `supply_executed` |
| `/vaults/:pool_vault_id/withdrawals` | `withdraw_executed` |
| `/vaults/:pool_vault_id/profit` | `expiry_profit_materialized` |
| `/vaults/:pool_vault_id/funding` | `expiry_max_funding_updated` |
| `/vaults/:pool_vault_id/cash-rebalances` | `expiry_cash_rebalanced` |
| `/vaults/:pool_vault_id/cash-receipts` | `expiry_cash_received` |
| `/builder-codes/:builder_code_id/fees` | `builder_fees_claimed` |

## Current-state lookups (composed top-1 reads)

These compose latest-by-triple rows from the raw tables; each component is a
bounded top-1 index scan.

- `/markets/:expiry_market_id/state` →
  `{market, config, mint_paused, oracle_prices, oracle_svi, settlement}`
  (`market` = `market_created` row; oracle components resolved through
  `market.market_oracle_id`).
- `/oracles/:market_oracle_id/latest` → `{prices, svi, settlement}`.
- `/vaults/:pool_vault_id/state` → `{current, latest_supply,
  latest_withdrawal, latest_cash_rebalance, latest_cash_receipt,
  latest_profit}`. `current` picks each `*_after` field from the newest event
  (by triple) among the tables that carry it.
- `/managers/:predict_manager_id/state` → `{manager, builder_code}`.
- `/config` → latest row of each protocol-config event:
  `{pricing, fee, risk, expiry_cash_template, strike_exposure_template,
  market_oracle_template, ewma, stake, trading_paused}`.

## Positions (`order_state`, indexer-maintained)

`order_state` keeps one row per packed order id. `status` is one of `open`,
`replaced` (partial close minted a replacement), `closed`, `liquidated`
(awaiting redemption), `liquidated_redeemed`, `settled_redeemed`. Each row
carries the terms decoded from the packed id (`opened_at_ms`, boundary
indices, `floor_shares`, `quantity`, `sequence`). Entry facts (strikes,
leverage, `entry_probability`, `net_premium`) live on the **root** row only;
replacement rows have them `null`.

- `/managers/:predict_manager_id/positions?status=open&limit=` → rows ordered
  by `opened_at_ms` desc. Each row carries `"root"`: the root order's entry
  facts when the row is a replacement, else `null`.
  Note: "claimable after settlement" is **derived**, not a status — an `open`
  position in a market whose `/markets/:id/state` shows a `settlement` is
  redeemable for its terminal payout.
- `/markets/:expiry_market_id/open-interest` →
  `{open_order_count, open_quantity, open_floor_shares}` (sums over `open`
  rows; string-typed).
- `/markets/:expiry_market_id/positions/:position_root_id/cashflow` → one
  `position_cashflow` row aggregating the whole replacement chain:
  `net_premium` + `mint_fees` in, `live_redeem_amount` / `settled_payout` out,
  quantities closed per exit path. `null` for unknown roots.

## Aggregated feeds (materialized views, refreshed every 60s)

Same window params; the window key is `bucket_ms` (bucket start, unix ms).
Views cover a 30-day trailing window (except `position_cashflow`); older
history is out of scope for Postgres (ClickHouse).

- `/markets/:expiry_market_id/activity` — hourly `market_activity_1h`: mint /
  live-redeem / settled-redeem counts, quantities, premium, fees, payout,
  unique minters.
- `/markets/:expiry_market_id/liquidation-stats` — hourly
  `liquidation_stats_1h`: liquidated count/quantity, `gross_value`,
  `floor_amount`, per-order `surplus` (gross − floor, floored at 0) and `gap`
  (floor − gross, floored at 0).
- `/vaults/:pool_vault_id/flows` — hourly `vault_flows_1h`: supply/withdraw
  counts and amounts, shares minted/burned, withdraw fees, end-of-bucket
  `total_supply_after` / `idle_balance_after` (share price =
  pool value / total supply is left to the consumer; both components are
  reported, no ratio is precomputed).
- `/oracles/:market_oracle_id/prices/sampled` — 1-minute `oracle_prices_1m`
  OHLC candles over the Block Scholes spot, plus last `forward`/`basis` and
  `update_count` per bucket. Roll up to coarser candles client-side; the raw
  `/prices` feed is for tail inspection, not charting.

Data freshness: MV-backed endpoints lag up to the refresh interval
(`--mv-refresh-interval-secs`, default 60); everything else is as fresh as the
indexer watermark (see `/status`).
