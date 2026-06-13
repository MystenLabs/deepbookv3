// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use crate::error::PredictError;
use crate::metrics::RpcMetrics;
use diesel::dsl::{count_star, sum};
use diesel::{ExpressionMethods, OptionalExtension, QueryDsl, SelectableHelper};
use predict_schema::models::order_status;
use predict_schema::models::{
    BlockScholesPricesUpdated, BlockScholesSVIUpdated, BuilderCodeSet, BuilderFeesClaimed,
    DeepStaked, DeepUnstaked, EwmaConfigUpdated, ExpiryCashRebalanced, ExpiryCashReceived,
    ExpiryCashTemplateConfigUpdated, ExpiryMarketMintPausedUpdated, ExpiryMaxFundingUpdated,
    ExpiryProfitMaterialized, FeeConfigUpdated, LiquidatedOrderRedeemed, LiquidationStats1h,
    LiveOrderRedeemed, MarketActivity1h, MarketConfigSnapshot, MarketCreated, MarketOracleSettled,
    MarketOracleTemplateConfigUpdated, OraclePrices1m, OrderLiquidated, OrderMinted, OrderState,
    PositionCashflow, PredictManagerCreated, PricingConfigUpdated, PythSourceUpdated,
    RiskConfigUpdated, SettledOrderRedeemed, StakeConfigUpdated,
    StrikeExposureTemplateConfigUpdated, SupplyExecuted, TradingLossRebateClaimed,
    TradingPausedUpdated, VaultFlows1h, WithdrawExecuted,
};
use predict_schema::schema;
use serde_json::{json, Value};
use std::collections::{BTreeSet, HashMap};

use diesel_async::RunQueryDsl;
use prometheus::Registry;
use std::sync::Arc;
use sui_indexer_alt_metrics::db::DbConnectionStatsCollector;
use sui_pg_db::{Db, DbArgs};
use url::Url;

/// Windowed-feed sort key `(checkpoint_timestamp_ms, checkpoint, tx_index,
/// event_index)`. Checkpoint timestamps are only NON-DECREASING — two
/// different checkpoints can share a `checkpoint_timestamp_ms` — so the
/// timestamp alone is not a total order, and `tx_index` (a per-checkpoint
/// position) is meaningless across checkpoints. `(checkpoint, tx_index,
/// event_index)` is the deterministic tiebreak within a timestamp.
type SortKey = (i64, i64, i64, i64);

/// Loads one table's timestamp-window page: rows filtered to `[start, end]`
/// (and to `$filter_col = id` when `$id` is `Some`), ordered newest-first by
/// `(checkpoint_timestamp_ms, checkpoint, tx_index, event_index)`, capped at
/// `limit`. The single home of the windowed-feed ordering contract;
/// `feed_page!` / `feed_page_opt!` only project its rows.
macro_rules! window_rows {
    ($conn:expr, $table:ident, $model:ty, $filter_col:ident, $id:expr, $start:expr, $end:expr, $limit:expr) => {{
        let mut query = schema::$table::table
            .filter(schema::$table::checkpoint_timestamp_ms.between($start, $end))
            .order_by((
                schema::$table::checkpoint_timestamp_ms.desc(),
                schema::$table::checkpoint.desc(),
                schema::$table::tx_index.desc(),
                schema::$table::event_index.desc(),
            ))
            .limit($limit)
            .select(<$model>::as_select())
            .into_boxed();
        if let Some(id) = $id {
            query = query.filter(schema::$table::$filter_col.eq(id));
        }
        query
            .load::<$model>(&mut $conn)
            .await
            .map_err(|e| PredictError::database(e.to_string()))
    }};
}

/// Runs a single-table timestamp-window query (`window_rows!`, mandatory id
/// filter) and projects each row into a `(SortKey, serde_json::Value)` feed
/// item, injecting a `"kind"` field naming the event. `$model` must be the
/// table's `Selectable` model; `$table` is its schema module and
/// (stringified) the `"kind"`.
macro_rules! feed_page {
    ($conn:expr, $table:ident, $model:ty, $filter_col:ident, $id:expr, $start:expr, $end:expr, $limit:expr) => {{
        let rows: Vec<$model> = window_rows!(
            $conn,
            $table,
            $model,
            $filter_col,
            Some($id),
            $start,
            $end,
            $limit
        )?;
        rows.into_iter()
            .map(|row| {
                let key: SortKey = (
                    row.checkpoint_timestamp_ms,
                    row.checkpoint,
                    row.tx_index,
                    row.event_index,
                );
                let value = project_row(row, stringify!($table))?;
                Ok((key, value))
            })
            .collect::<Result<Vec<(SortKey, Value)>, PredictError>>()
    }};
}

/// Single-table window feed: runs `feed_page!` (mandatory id filter) and strips
/// the `SortKey` to a finished page. The DB already returns rows newest-first,
/// so `merge_feed`'s re-sort is a no-op here; it only enforces the `limit`. Used
/// by every single-table `*_PATH` endpoint, making each reader method one line.
macro_rules! single_feed {
    ($conn:expr, $table:ident, $model:ty, $filter_col:ident, $id:expr, $start:expr, $end:expr, $limit:expr) => {{
        let items = feed_page!(
            $conn,
            $table,
            $model,
            $filter_col,
            $id,
            $start,
            $end,
            $limit
        )?;
        Ok(merge_feed(items, $limit))
    }};
}

/// Merges per-table feed items into one page: sorts by `SortKey` DESC and
/// truncates to `limit`.
fn merge_feed(mut items: Vec<(SortKey, Value)>, limit: i64) -> Vec<Value> {
    items.sort_by(|(a, _), (b, _)| b.cmp(a));
    items.truncate(limit as usize);
    items.into_iter().map(|(_, v)| v).collect()
}

/// Runs a single-table timestamp-window query (`window_rows!`) with an
/// OPTIONAL id filter and returns a finished page (`Vec<Value>`, each row
/// carrying its `"kind"`). When `$id` is `Some`, filters `$filter_col.eq(id)`;
/// when `None`, windows the whole table. Used by the optional-filter list
/// endpoints (`/managers`, `/markets`).
macro_rules! feed_page_opt {
    ($conn:expr, $table:ident, $model:ty, $filter_col:ident, $id:expr, $start:expr, $end:expr, $limit:expr) => {{
        let rows: Vec<$model> = window_rows!(
            $conn,
            $table,
            $model,
            $filter_col,
            $id,
            $start,
            $end,
            $limit
        )?;
        project_rows(rows, stringify!($table))
    }};
}

/// Projects loaded rows into finished feed `Value`s, injecting `"kind"`. Shared
/// by the optional-filter list endpoints; the merge feeds reuse `feed_page!` +
/// `merge_feed` instead (they need the `SortKey` to interleave tables).
fn project_rows<T: serde::Serialize>(rows: Vec<T>, kind: &str) -> Result<Vec<Value>, PredictError> {
    rows.into_iter().map(|row| project_row(row, kind)).collect()
}

/// Single-row variant of `project_rows`.
fn project_row<T: serde::Serialize>(row: T, kind: &str) -> Result<Value, PredictError> {
    let mut value =
        serde_json::to_value(row).map_err(|e| PredictError::deserialization(e.to_string()))?;
    if let Value::Object(map) = &mut value {
        map.insert("kind".to_string(), Value::String(kind.to_string()));
    }
    Ok(value)
}

/// Typed latest row of a raw event table: a bounded top-1 index scan ordered
/// by `(checkpoint, tx_index, event_index)` — the only total event order
/// (`checkpoint_timestamp_ms` is unnecessary for top-1 and ties across
/// checkpoints). With `$filter_col`/`$id`, scopes to one id; without, scans
/// the whole table (only for the tiny admin-config tables, one row per admin
/// update). The single home of the top-1 ordering contract.
macro_rules! latest_row_typed {
    ($conn:expr, $table:ident, $model:ty) => {
        latest_row_typed!(@query $conn, $table, $model, schema::$table::table)
    };
    ($conn:expr, $table:ident, $model:ty, $filter_col:ident, $id:expr) => {
        latest_row_typed!(@query $conn, $table, $model,
            schema::$table::table.filter(schema::$table::$filter_col.eq($id)))
    };
    (@query $conn:expr, $table:ident, $model:ty, $query:expr) => {
        $query
            .order_by((
                schema::$table::checkpoint.desc(),
                schema::$table::tx_index.desc(),
                schema::$table::event_index.desc(),
            ))
            .select(<$model>::as_select())
            .first::<$model>(&mut $conn)
            .await
            .optional()
            .map_err(|e| PredictError::database(e.to_string()))?
    };
}

/// Projected latest row (`latest_row_typed!` + `project_row`). This is the
/// Predict "current state" read for everything except the open order set
/// (which the indexer maintains in `order_state`): the raw table stays the
/// source of truth and there is no upsert machinery to get wrong.
macro_rules! latest_row {
    ($conn:expr, $table:ident, $model:ty $(, $filter_col:ident, $id:expr)?) => {{
        let row: Option<$model> = latest_row_typed!($conn, $table, $model $(, $filter_col, $id)?);
        row.map(|r| project_row(r, stringify!($table)))
            .transpose()?
    }};
}

/// Timestamp-window page over a time-bucketed materialized view, newest bucket
/// first. Same `start/end/limit` contract as the raw feeds, with `bucket_ms`
/// as the window key.
macro_rules! bucket_feed {
    ($conn:expr, $table:ident, $model:ty, $filter_col:ident, $id:expr, $start:expr, $end:expr, $limit:expr) => {{
        let rows: Vec<$model> = schema::$table::table
            .filter(schema::$table::$filter_col.eq($id))
            .filter(schema::$table::bucket_ms.between($start, $end))
            .order_by(schema::$table::bucket_ms.desc())
            .limit($limit)
            .select(<$model>::as_select())
            .load(&mut $conn)
            .await
            .map_err(|e| PredictError::database(e.to_string()))?;
        project_rows(rows, stringify!($table))
    }};
}

#[derive(Clone)]
pub struct Reader {
    db: Db,
    metrics: Arc<RpcMetrics>,
}

impl Reader {
    pub(crate) async fn new(
        database_url: Url,
        db_args: DbArgs,
        metrics: Arc<RpcMetrics>,
        registry: &Registry,
    ) -> Result<Self, anyhow::Error> {
        let db = Db::for_read(database_url, db_args).await?;
        registry.register(Box::new(DbConnectionStatsCollector::new(
            Some("predict_api_db"),
            db.clone(),
        )))?;

        // Try to open a read connection to verify we can
        // connect to the DB on startup.
        let _ = db.connect().await?;

        Ok(Self { db, metrics })
    }

    pub async fn get_watermarks(&self) -> Result<Vec<(String, i64, i64, i64)>, PredictError> {
        let mut connection = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();

        let res = schema::watermarks::table
            .select((
                schema::watermarks::pipeline,
                schema::watermarks::checkpoint_hi_inclusive,
                schema::watermarks::timestamp_ms_hi_inclusive,
                schema::watermarks::epoch_hi_inclusive,
            ))
            .load::<(String, i64, i64, i64)>(&mut connection)
            .await
            .map_err(|_| PredictError::database("Error fetching watermarks"));

        if res.is_ok() {
            self.metrics.db_requests_succeeded.inc();
        } else {
            self.metrics.db_requests_failed.inc();
        }
        res
    }

    /// Interleaved order feed for a single market: merges all 5 order tables
    /// filtered by `expiry_market_id` within `[start_time_ms, end_time_ms]`,
    /// newest first by `(checkpoint_timestamp_ms, checkpoint, tx_index,
    /// event_index)`.
    pub async fn get_market_orders(
        &self,
        expiry_market_id: String,
        start_time_ms: i64,
        end_time_ms: i64,
        limit: i64,
    ) -> Result<Vec<Value>, PredictError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();
        let mut merged: Vec<(SortKey, Value)> = Vec::new();
        merged.extend(feed_page!(
            conn,
            order_minted,
            OrderMinted,
            expiry_market_id,
            expiry_market_id.clone(),
            start_time_ms,
            end_time_ms,
            limit
        )?);
        merged.extend(feed_page!(
            conn,
            live_order_redeemed,
            LiveOrderRedeemed,
            expiry_market_id,
            expiry_market_id.clone(),
            start_time_ms,
            end_time_ms,
            limit
        )?);
        merged.extend(feed_page!(
            conn,
            settled_order_redeemed,
            SettledOrderRedeemed,
            expiry_market_id,
            expiry_market_id.clone(),
            start_time_ms,
            end_time_ms,
            limit
        )?);
        merged.extend(feed_page!(
            conn,
            liquidated_order_redeemed,
            LiquidatedOrderRedeemed,
            expiry_market_id,
            expiry_market_id.clone(),
            start_time_ms,
            end_time_ms,
            limit
        )?);
        merged.extend(feed_page!(
            conn,
            order_liquidated,
            OrderLiquidated,
            expiry_market_id,
            expiry_market_id.clone(),
            start_time_ms,
            end_time_ms,
            limit
        )?);

        Ok(merge_feed(merged, limit))
    }

    /// Interleaved order feed for a single manager: merges the 4 order tables
    /// that carry `predict_manager_id` (excludes `order_liquidated`, which has
    /// no manager column) within `[start_time_ms, end_time_ms]`, newest first
    /// by `(checkpoint_timestamp_ms, checkpoint, tx_index, event_index)`.
    pub async fn get_manager_orders(
        &self,
        predict_manager_id: String,
        start_time_ms: i64,
        end_time_ms: i64,
        limit: i64,
    ) -> Result<Vec<Value>, PredictError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();
        let mut merged: Vec<(SortKey, Value)> = Vec::new();
        merged.extend(feed_page!(
            conn,
            order_minted,
            OrderMinted,
            predict_manager_id,
            predict_manager_id.clone(),
            start_time_ms,
            end_time_ms,
            limit
        )?);
        merged.extend(feed_page!(
            conn,
            live_order_redeemed,
            LiveOrderRedeemed,
            predict_manager_id,
            predict_manager_id.clone(),
            start_time_ms,
            end_time_ms,
            limit
        )?);
        merged.extend(feed_page!(
            conn,
            settled_order_redeemed,
            SettledOrderRedeemed,
            predict_manager_id,
            predict_manager_id.clone(),
            start_time_ms,
            end_time_ms,
            limit
        )?);
        merged.extend(feed_page!(
            conn,
            liquidated_order_redeemed,
            LiquidatedOrderRedeemed,
            predict_manager_id,
            predict_manager_id.clone(),
            start_time_ms,
            end_time_ms,
            limit
        )?);

        Ok(merge_feed(merged, limit))
    }

    /// `predict_manager_created` list, newest-first. Optionally filtered by
    /// `owner` when present.
    pub async fn get_managers(
        &self,
        owner: Option<String>,
        start_time_ms: i64,
        end_time_ms: i64,
        limit: i64,
    ) -> Result<Vec<Value>, PredictError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();
        feed_page_opt!(
            conn,
            predict_manager_created,
            PredictManagerCreated,
            owner,
            owner,
            start_time_ms,
            end_time_ms,
            limit
        )
    }

    /// `market_created` list (no id filter), newest-first.
    pub async fn get_markets(
        &self,
        start_time_ms: i64,
        end_time_ms: i64,
        limit: i64,
    ) -> Result<Vec<Value>, PredictError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();
        feed_page_opt!(
            conn,
            market_created,
            MarketCreated,
            expiry_market_id,
            None::<String>,
            start_time_ms,
            end_time_ms,
            limit
        )
    }

    /// `block_scholes_prices_updated` feed for one oracle, newest-first.
    pub async fn get_oracle_prices(
        &self,
        market_oracle_id: String,
        start_time_ms: i64,
        end_time_ms: i64,
        limit: i64,
    ) -> Result<Vec<Value>, PredictError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();
        single_feed!(
            conn,
            block_scholes_prices_updated,
            BlockScholesPricesUpdated,
            market_oracle_id,
            market_oracle_id.clone(),
            start_time_ms,
            end_time_ms,
            limit
        )
    }

    /// `block_scholes_svi_updated` feed for one oracle, newest-first.
    pub async fn get_oracle_svi(
        &self,
        market_oracle_id: String,
        start_time_ms: i64,
        end_time_ms: i64,
        limit: i64,
    ) -> Result<Vec<Value>, PredictError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();
        single_feed!(
            conn,
            block_scholes_svi_updated,
            BlockScholesSVIUpdated,
            market_oracle_id,
            market_oracle_id.clone(),
            start_time_ms,
            end_time_ms,
            limit
        )
    }

    /// `pyth_source_updated` feed for one pyth source, newest-first.
    pub async fn get_pyth_source_updates(
        &self,
        pyth_source_id: String,
        start_time_ms: i64,
        end_time_ms: i64,
        limit: i64,
    ) -> Result<Vec<Value>, PredictError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();
        single_feed!(
            conn,
            pyth_source_updated,
            PythSourceUpdated,
            pyth_source_id,
            pyth_source_id.clone(),
            start_time_ms,
            end_time_ms,
            limit
        )
    }

    /// `market_oracle_settled` feed for one oracle, newest-first.
    pub async fn get_oracle_settlements(
        &self,
        market_oracle_id: String,
        start_time_ms: i64,
        end_time_ms: i64,
        limit: i64,
    ) -> Result<Vec<Value>, PredictError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();
        single_feed!(
            conn,
            market_oracle_settled,
            MarketOracleSettled,
            market_oracle_id,
            market_oracle_id.clone(),
            start_time_ms,
            end_time_ms,
            limit
        )
    }

    /// `supply_executed` feed for one vault, newest-first.
    pub async fn get_vault_supplies(
        &self,
        pool_vault_id: String,
        start_time_ms: i64,
        end_time_ms: i64,
        limit: i64,
    ) -> Result<Vec<Value>, PredictError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();
        single_feed!(
            conn,
            supply_executed,
            SupplyExecuted,
            pool_vault_id,
            pool_vault_id.clone(),
            start_time_ms,
            end_time_ms,
            limit
        )
    }

    /// `withdraw_executed` feed for one vault, newest-first.
    pub async fn get_vault_withdrawals(
        &self,
        pool_vault_id: String,
        start_time_ms: i64,
        end_time_ms: i64,
        limit: i64,
    ) -> Result<Vec<Value>, PredictError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();
        single_feed!(
            conn,
            withdraw_executed,
            WithdrawExecuted,
            pool_vault_id,
            pool_vault_id.clone(),
            start_time_ms,
            end_time_ms,
            limit
        )
    }

    /// `expiry_profit_materialized` feed for one vault, newest-first.
    pub async fn get_vault_profit(
        &self,
        pool_vault_id: String,
        start_time_ms: i64,
        end_time_ms: i64,
        limit: i64,
    ) -> Result<Vec<Value>, PredictError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();
        single_feed!(
            conn,
            expiry_profit_materialized,
            ExpiryProfitMaterialized,
            pool_vault_id,
            pool_vault_id.clone(),
            start_time_ms,
            end_time_ms,
            limit
        )
    }

    /// `expiry_max_funding_updated` feed for one vault, newest-first.
    pub async fn get_vault_funding(
        &self,
        pool_vault_id: String,
        start_time_ms: i64,
        end_time_ms: i64,
        limit: i64,
    ) -> Result<Vec<Value>, PredictError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();
        single_feed!(
            conn,
            expiry_max_funding_updated,
            ExpiryMaxFundingUpdated,
            pool_vault_id,
            pool_vault_id.clone(),
            start_time_ms,
            end_time_ms,
            limit
        )
    }

    /// `expiry_cash_rebalanced` feed for one vault, newest-first.
    pub async fn get_vault_cash_rebalances(
        &self,
        pool_vault_id: String,
        start_time_ms: i64,
        end_time_ms: i64,
        limit: i64,
    ) -> Result<Vec<Value>, PredictError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();
        single_feed!(
            conn,
            expiry_cash_rebalanced,
            ExpiryCashRebalanced,
            pool_vault_id,
            pool_vault_id.clone(),
            start_time_ms,
            end_time_ms,
            limit
        )
    }

    /// `expiry_cash_received` feed for one vault, newest-first.
    pub async fn get_vault_cash_receipts(
        &self,
        pool_vault_id: String,
        start_time_ms: i64,
        end_time_ms: i64,
        limit: i64,
    ) -> Result<Vec<Value>, PredictError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();
        single_feed!(
            conn,
            expiry_cash_received,
            ExpiryCashReceived,
            pool_vault_id,
            pool_vault_id.clone(),
            start_time_ms,
            end_time_ms,
            limit
        )
    }

    /// Interleaved DEEP staking feed for one manager: merges `deep_staked` +
    /// `deep_unstaked` filtered by `predict_manager_id` within the window,
    /// newest-first by `(checkpoint_timestamp_ms, checkpoint, tx_index,
    /// event_index)`.
    pub async fn get_manager_staking(
        &self,
        predict_manager_id: String,
        start_time_ms: i64,
        end_time_ms: i64,
        limit: i64,
    ) -> Result<Vec<Value>, PredictError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();
        let mut merged: Vec<(SortKey, Value)> = Vec::new();
        merged.extend(feed_page!(
            conn,
            deep_staked,
            DeepStaked,
            predict_manager_id,
            predict_manager_id.clone(),
            start_time_ms,
            end_time_ms,
            limit
        )?);
        merged.extend(feed_page!(
            conn,
            deep_unstaked,
            DeepUnstaked,
            predict_manager_id,
            predict_manager_id.clone(),
            start_time_ms,
            end_time_ms,
            limit
        )?);
        Ok(merge_feed(merged, limit))
    }

    /// `trading_loss_rebate_claimed` feed for one manager, newest-first.
    pub async fn get_manager_rebates(
        &self,
        predict_manager_id: String,
        start_time_ms: i64,
        end_time_ms: i64,
        limit: i64,
    ) -> Result<Vec<Value>, PredictError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();
        single_feed!(
            conn,
            trading_loss_rebate_claimed,
            TradingLossRebateClaimed,
            predict_manager_id,
            predict_manager_id.clone(),
            start_time_ms,
            end_time_ms,
            limit
        )
    }

    /// `builder_fees_claimed` feed for one builder code, newest-first.
    pub async fn get_builder_code_fees(
        &self,
        builder_code_id: String,
        start_time_ms: i64,
        end_time_ms: i64,
        limit: i64,
    ) -> Result<Vec<Value>, PredictError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();
        single_feed!(
            conn,
            builder_fees_claimed,
            BuilderFeesClaimed,
            builder_code_id,
            builder_code_id.clone(),
            start_time_ms,
            end_time_ms,
            limit
        )
    }

    /// Composed current state for one market: the creation row, the latest
    /// config snapshot, the latest mint-pause flag, and (through the market's
    /// oracle) the latest prices/SVI/settlement. Every component is a top-1
    /// index scan; missing components are `null`.
    pub async fn get_market_state(&self, expiry_market_id: String) -> Result<Value, PredictError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();

        let market = latest_row!(
            conn,
            market_created,
            MarketCreated,
            expiry_market_id,
            expiry_market_id.clone()
        );
        let config = latest_row!(
            conn,
            market_config_snapshot,
            MarketConfigSnapshot,
            expiry_market_id,
            expiry_market_id.clone()
        );
        let mint_paused = latest_row!(
            conn,
            expiry_market_mint_paused_updated,
            ExpiryMarketMintPausedUpdated,
            expiry_market_id,
            expiry_market_id.clone()
        );

        let market_oracle_id = market
            .as_ref()
            .and_then(|m| m["market_oracle_id"].as_str())
            .map(str::to_string);
        let (oracle_prices, oracle_svi, settlement) = match market_oracle_id {
            Some(oracle_id) => (
                latest_row!(
                    conn,
                    block_scholes_prices_updated,
                    BlockScholesPricesUpdated,
                    market_oracle_id,
                    oracle_id.clone()
                ),
                latest_row!(
                    conn,
                    block_scholes_svi_updated,
                    BlockScholesSVIUpdated,
                    market_oracle_id,
                    oracle_id.clone()
                ),
                latest_row!(
                    conn,
                    market_oracle_settled,
                    MarketOracleSettled,
                    market_oracle_id,
                    oracle_id
                ),
            ),
            None => (None, None, None),
        };

        Ok(json!({
            "expiry_market_id": expiry_market_id,
            "market": market,
            "config": config,
            "mint_paused": mint_paused,
            "oracle_prices": oracle_prices,
            "oracle_svi": oracle_svi,
            "settlement": settlement,
        }))
    }

    /// Latest prices, SVI surface, and settlement for one oracle.
    pub async fn get_oracle_latest(&self, market_oracle_id: String) -> Result<Value, PredictError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();

        let prices = latest_row!(
            conn,
            block_scholes_prices_updated,
            BlockScholesPricesUpdated,
            market_oracle_id,
            market_oracle_id.clone()
        );
        let svi = latest_row!(
            conn,
            block_scholes_svi_updated,
            BlockScholesSVIUpdated,
            market_oracle_id,
            market_oracle_id.clone()
        );
        let settlement = latest_row!(
            conn,
            market_oracle_settled,
            MarketOracleSettled,
            market_oracle_id,
            market_oracle_id.clone()
        );

        Ok(json!({
            "market_oracle_id": market_oracle_id,
            "prices": prices,
            "svi": svi,
            "settlement": settlement,
        }))
    }

    /// Composed current state for one vault. The vault events all carry
    /// `*_after` snapshot fields, so "current" is the newest event — by the
    /// typed `(checkpoint, tx_index, event_index)` triple, compared before
    /// projecting to JSON — among the tables that carry each field.
    pub async fn get_vault_state(&self, pool_vault_id: String) -> Result<Value, PredictError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();

        let supply: Option<SupplyExecuted> = latest_row_typed!(
            conn,
            supply_executed,
            SupplyExecuted,
            pool_vault_id,
            pool_vault_id.clone()
        );
        let withdraw: Option<WithdrawExecuted> = latest_row_typed!(
            conn,
            withdraw_executed,
            WithdrawExecuted,
            pool_vault_id,
            pool_vault_id.clone()
        );
        let rebalance: Option<ExpiryCashRebalanced> = latest_row_typed!(
            conn,
            expiry_cash_rebalanced,
            ExpiryCashRebalanced,
            pool_vault_id,
            pool_vault_id.clone()
        );
        let receipt: Option<ExpiryCashReceived> = latest_row_typed!(
            conn,
            expiry_cash_received,
            ExpiryCashReceived,
            pool_vault_id,
            pool_vault_id.clone()
        );
        let profit: Option<ExpiryProfitMaterialized> = latest_row_typed!(
            conn,
            expiry_profit_materialized,
            ExpiryProfitMaterialized,
            pool_vault_id,
            pool_vault_id.clone()
        );

        // `$field` of `$row`, keyed by the row's typed event triple.
        macro_rules! keyed {
            ($row:expr, $field:ident) => {
                $row.as_ref()
                    .map(|r| ((r.checkpoint, r.tx_index, r.event_index), r.$field.clone()))
            };
        }
        // Newest (by typed event triple) among `keyed!` candidates.
        fn newest<T>(
            candidates: impl IntoIterator<Item = Option<((i64, i64, i64), T)>>,
        ) -> Option<T> {
            candidates
                .into_iter()
                .flatten()
                .max_by_key(|(triple, _)| *triple)
                .map(|(_, v)| v)
        }

        // idle_balance_after is carried by all five tables; total_supply_after
        // only by supply/withdraw; reserve/profit-basis only by profit.
        let idle = newest([
            keyed!(supply, idle_balance_after),
            keyed!(withdraw, idle_balance_after),
            keyed!(rebalance, idle_balance_after),
            keyed!(receipt, idle_balance_after),
            keyed!(profit, idle_balance_after),
        ]);
        let total_supply = newest([
            keyed!(supply, total_supply_after),
            keyed!(withdraw, total_supply_after),
        ]);
        let current = json!({
            "idle_balance_after": idle,
            "total_supply_after": total_supply,
            "protocol_reserve_balance_after":
                profit.as_ref().map(|r| r.protocol_reserve_balance_after.clone()),
            "profit_basis_after": profit.as_ref().map(|r| r.profit_basis_after.clone()),
        });

        Ok(json!({
            "pool_vault_id": pool_vault_id,
            "current": current,
            "latest_supply": supply.map(|r| project_row(r, "supply_executed")).transpose()?,
            "latest_withdrawal": withdraw.map(|r| project_row(r, "withdraw_executed")).transpose()?,
            "latest_cash_rebalance":
                rebalance.map(|r| project_row(r, "expiry_cash_rebalanced")).transpose()?,
            "latest_cash_receipt":
                receipt.map(|r| project_row(r, "expiry_cash_received")).transpose()?,
            "latest_profit":
                profit.map(|r| project_row(r, "expiry_profit_materialized")).transpose()?,
        }))
    }

    /// Latest value of every protocol-config event (tiny admin-update tables;
    /// whole-table top-1 each).
    pub async fn get_protocol_config(&self) -> Result<Value, PredictError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();

        Ok(json!({
            "pricing": latest_row!(conn, pricing_config_updated, PricingConfigUpdated),
            "fee": latest_row!(conn, fee_config_updated, FeeConfigUpdated),
            "risk": latest_row!(conn, risk_config_updated, RiskConfigUpdated),
            "expiry_cash_template": latest_row!(
                conn,
                expiry_cash_template_config_updated,
                ExpiryCashTemplateConfigUpdated
            ),
            "strike_exposure_template": latest_row!(
                conn,
                strike_exposure_template_config_updated,
                StrikeExposureTemplateConfigUpdated
            ),
            "market_oracle_template": latest_row!(
                conn,
                market_oracle_template_config_updated,
                MarketOracleTemplateConfigUpdated
            ),
            "ewma": latest_row!(conn, ewma_config_updated, EwmaConfigUpdated),
            "stake": latest_row!(conn, stake_config_updated, StakeConfigUpdated),
            "trading_paused": latest_row!(
                conn,
                trading_paused_updated,
                TradingPausedUpdated
            ),
        }))
    }

    /// Composed current state for one manager: the creation row plus the
    /// latest builder-code assignment.
    pub async fn get_manager_state(
        &self,
        predict_manager_id: String,
    ) -> Result<Value, PredictError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();

        let created = latest_row!(
            conn,
            predict_manager_created,
            PredictManagerCreated,
            predict_manager_id,
            predict_manager_id.clone()
        );
        let builder_code = latest_row!(
            conn,
            builder_code_set,
            BuilderCodeSet,
            predict_manager_id,
            predict_manager_id.clone()
        );

        Ok(json!({
            "predict_manager_id": predict_manager_id,
            "manager": created,
            "builder_code": builder_code,
        }))
    }

    /// `order_state` rows for one manager filtered by status, windowed by
    /// `opened_at_ms` within `[start_time_ms, end_time_ms]`, newest-opened
    /// first with the expiry-local mint `sequence` as the deterministic
    /// tiebreak (`opened_at_ms` is checkpoint-quantized, so ties are common).
    /// Each row carries a `"root"` object with the root order's entry facts
    /// when the row is a replacement (entry facts live on the root row; see
    /// the order_state pipeline), `null` when the row is its own root.
    pub async fn get_manager_positions(
        &self,
        predict_manager_id: String,
        status: String,
        start_time_ms: i64,
        end_time_ms: i64,
        limit: i64,
    ) -> Result<Vec<Value>, PredictError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();

        let rows: Vec<OrderState> = schema::order_state::table
            .filter(schema::order_state::predict_manager_id.eq(predict_manager_id))
            .filter(schema::order_state::status.eq(status))
            .filter(schema::order_state::opened_at_ms.between(start_time_ms, end_time_ms))
            .order_by((
                schema::order_state::opened_at_ms.desc(),
                schema::order_state::sequence.desc(),
            ))
            .limit(limit)
            .select(OrderState::as_select())
            .load(&mut conn)
            .await
            .map_err(|e| PredictError::database(e.to_string()))?;

        // Packed order ids are expiry-local, so roots are keyed by
        // (expiry_market_id, position_root_id). Fetch a superset by id and
        // resolve exact pairs in the map.
        let root_keys: BTreeSet<(String, String)> = rows
            .iter()
            .filter_map(|row| {
                row.position_root_id
                    .clone()
                    .filter(|root| *root != row.order_id)
                    .map(|root| (row.expiry_market_id.clone(), root))
            })
            .collect();
        let roots: Vec<OrderState> = if root_keys.is_empty() {
            Vec::new()
        } else {
            let markets: BTreeSet<String> =
                root_keys.iter().map(|(market, _)| market.clone()).collect();
            let ids: BTreeSet<String> = root_keys.iter().map(|(_, id)| id.clone()).collect();
            schema::order_state::table
                .filter(schema::order_state::expiry_market_id.eq_any(markets))
                .filter(schema::order_state::order_id.eq_any(ids))
                .select(OrderState::as_select())
                .load(&mut conn)
                .await
                .map_err(|e| PredictError::database(e.to_string()))?
        };
        let entry_by_root: HashMap<(String, String), Value> = roots
            .into_iter()
            .map(|root| {
                (
                    (root.expiry_market_id.clone(), root.order_id.clone()),
                    json!({
                        "order_id": root.order_id,
                        "lower_strike": root.lower_strike,
                        "higher_strike": root.higher_strike,
                        "leverage": root.leverage,
                        "entry_probability": root.entry_probability,
                        "net_premium": root.net_premium,
                    }),
                )
            })
            .collect();

        rows.into_iter()
            .map(|row| {
                let root = row
                    .position_root_id
                    .clone()
                    .filter(|root| *root != row.order_id)
                    .and_then(|root| {
                        entry_by_root
                            .get(&(row.expiry_market_id.clone(), root))
                            .cloned()
                    })
                    .unwrap_or(Value::Null);
                let mut value = project_row(row, "order_state")?;
                if let Value::Object(map) = &mut value {
                    map.insert("root".to_string(), root);
                }
                Ok(value)
            })
            .collect()
    }

    /// Open interest for one market: count and sums over the open rows in
    /// `order_state` (bounded by the market's open-order count via the
    /// `(expiry_market_id, status)` index).
    pub async fn get_market_open_interest(
        &self,
        expiry_market_id: String,
    ) -> Result<Value, PredictError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();

        let (open_count, open_quantity, open_floor_shares): (
            i64,
            Option<bigdecimal::BigDecimal>,
            Option<bigdecimal::BigDecimal>,
        ) = schema::order_state::table
            .filter(schema::order_state::expiry_market_id.eq(expiry_market_id.clone()))
            .filter(schema::order_state::status.eq(order_status::OPEN))
            .select((
                count_star(),
                sum(schema::order_state::quantity),
                sum(schema::order_state::floor_shares),
            ))
            .first(&mut conn)
            .await
            .map_err(|e| PredictError::database(e.to_string()))?;

        Ok(json!({
            "expiry_market_id": expiry_market_id,
            "open_order_count": open_count,
            "open_quantity": open_quantity.map(|q| q.to_string()).unwrap_or_else(|| "0".to_string()),
            "open_floor_shares": open_floor_shares.map(|f| f.to_string()).unwrap_or_else(|| "0".to_string()),
        }))
    }

    /// `market_activity_1h` buckets for one market, newest bucket first.
    pub async fn get_market_activity(
        &self,
        expiry_market_id: String,
        start_time_ms: i64,
        end_time_ms: i64,
        limit: i64,
    ) -> Result<Vec<Value>, PredictError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();
        bucket_feed!(
            conn,
            market_activity_1h,
            MarketActivity1h,
            expiry_market_id,
            expiry_market_id.clone(),
            start_time_ms,
            end_time_ms,
            limit
        )
    }

    /// `liquidation_stats_1h` buckets for one market, newest bucket first.
    pub async fn get_market_liquidation_stats(
        &self,
        expiry_market_id: String,
        start_time_ms: i64,
        end_time_ms: i64,
        limit: i64,
    ) -> Result<Vec<Value>, PredictError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();
        bucket_feed!(
            conn,
            liquidation_stats_1h,
            LiquidationStats1h,
            expiry_market_id,
            expiry_market_id.clone(),
            start_time_ms,
            end_time_ms,
            limit
        )
    }

    /// `vault_flows_1h` buckets for one vault, newest bucket first.
    pub async fn get_vault_flows(
        &self,
        pool_vault_id: String,
        start_time_ms: i64,
        end_time_ms: i64,
        limit: i64,
    ) -> Result<Vec<Value>, PredictError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();
        bucket_feed!(
            conn,
            vault_flows_1h,
            VaultFlows1h,
            pool_vault_id,
            pool_vault_id.clone(),
            start_time_ms,
            end_time_ms,
            limit
        )
    }

    /// `oracle_prices_1m` candles for one oracle, newest bucket first.
    pub async fn get_oracle_prices_sampled(
        &self,
        market_oracle_id: String,
        start_time_ms: i64,
        end_time_ms: i64,
        limit: i64,
    ) -> Result<Vec<Value>, PredictError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();
        bucket_feed!(
            conn,
            oracle_prices_1m,
            OraclePrices1m,
            market_oracle_id,
            market_oracle_id.clone(),
            start_time_ms,
            end_time_ms,
            limit
        )
    }

    /// `position_cashflow` point lookup for one `(market, position root)` —
    /// root ids are expiry-local, so the market scopes the lookup. `null` when
    /// the root mint is unknown (or the view has not refreshed yet).
    pub async fn get_position_cashflow(
        &self,
        expiry_market_id: String,
        position_root_id: String,
    ) -> Result<Value, PredictError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();

        let row: Option<PositionCashflow> = schema::position_cashflow::table
            .filter(schema::position_cashflow::expiry_market_id.eq(expiry_market_id))
            .filter(schema::position_cashflow::position_root_id.eq(position_root_id))
            .select(PositionCashflow::as_select())
            .first(&mut conn)
            .await
            .optional()
            .map_err(|e| PredictError::database(e.to_string()))?;
        Ok(row
            .map(|r| project_row(r, "position_cashflow"))
            .transpose()?
            .unwrap_or(Value::Null))
    }
}
