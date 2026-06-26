# Service API Reference

The data plane the SDK reads from. Two HTTP services, both keyed in `config.servers`:

| Key (`config.server_url`) | Service | Role |
|---|---|---|
| `predict` | predict-server | protocol / market / vault / position data |
| `propbook` | oracle-server | oracle freshness (pyth + block-scholes) |

**Status of this doc.** Hand-maintained and **expected to drift** — the services evolve
and this is an internal, short-term SDK. It is *not* generated or verified by anything;
the SDK source (`indexer.py`, `observability.py`, `portfolio.py`) is the caller of
record. If a call starts failing or returns unexpected shapes, fix the SDK and update
this file by hand. Each entry lists only the fields the **SDK reads** — responses carry
more. Base URLs live in `config._TESTNET_SERVERS` (an SDK overlay; the deploy manifest
carries no URLs, and the oracle host in particular is unconfirmed against deployment).

All endpoints are `GET`, fail open (transport error / wrong type → empty), and use the
server's window pagination where noted: `limit` (default 50, cap 500), `start_time` /
`end_time` in **unix seconds** (server multiplies by 1000).

## predict-server (`predict`)

| Endpoint | SDK method | Fields the SDK reads |
|---|---|---|
| `/status` | `PredictIndexerClient.health` | `status`, `pipelines[].checkpoint_lag`, `pipelines[].time_lag_seconds`, `max_lag_pipeline`, `latest_onchain_checkpoint` |
| `/markets?limit=&start_time=` | `.markets` | per row: `expiry_market_id`, `expiry`, `propbook_underlying_id`, `tick_size` (and for the `markets` command: `checkpoint_timestamp_ms`, `initial_expiry_cash`, `max_admission_leverage`) |
| `/markets/{expiry_market_id}/state` | `.market_state` | `market.{expiry,tick_size,propbook_underlying_id}`, `mint_paused.paused`, `settlement` (null when unsettled) → `settlement.settlement_price` |
| `/vaults/{pool_vault_id}/state` | `.vault_state` | `current.idle_balance_after`, `current.protocol_reserve_balance_after`, `current.total_supply` |
| `/config` | `.protocol_config` | `trading_paused.paused`, `pricing.pyth_spot_freshness_ms`, `pricing.block_scholes_surface_freshness_ms` |
| `/managers?owner=&limit=` | `.managers` | newest row's `predict_manager_id` (the AccountWrapper id, used to query positions/orders) |
| `/managers/{predict_manager_id}/orders?limit=&end_time=` | `.manager_orders` | see order-feed table below |

### `/managers/{id}/orders` feed

Interleaved, newest-first; each row carries a `kind` discriminator plus the common
fields `event_digest`, `checkpoint_timestamp_ms`, `position_root_id`,
`expiry_market_id`, `order_id`, `owner`. Per `kind` (amounts are 6-dp DUSDC base units):

| `kind` | Additional fields the SDK reads |
|---|---|
| `order_minted` | `lower_tick`, `higher_tick`, `leverage`, `entry_probability`, `quantity`, `net_premium`, `trading_fee`, `builder_fee`, `penalty_fee` |
| `live_order_redeemed` | `quantity_closed`, `redeem_amount`, `trading_fee`, `builder_fee`, `penalty_fee` |
| `settled_order_redeemed` | `quantity_closed`, `payout_amount` |
| `liquidated_order_redeemed` | `quantity_closed` |

## oracle-server (`propbook`)

Keyed by `propbook_oracle_id`, resolved from the asset's `propbook_underlying_id`.

| Endpoint | SDK method | Fields the SDK reads |
|---|---|---|
| `/underlyings/{propbook_underlying_id}/binding` | `OracleClient.underlying_binding` | `propbook_oracle_id` |
| `/oracles/{propbook_oracle_id}/pyth/latest` | `.pyth_latest` | `source_timestamp_ms` |
| `/oracles/{propbook_oracle_id}/block-scholes?limit=1` | `.block_scholes_latest` | newest row's `source_timestamp_ms` |
