// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use crate::error::PredictError;
use crate::metrics::RpcMetrics;
use diesel::{ExpressionMethods, QueryDsl, SelectableHelper};
use predict_schema::models::{
    BlockScholesPricesUpdated, BlockScholesSVIUpdated, BuilderFeesClaimed, DeepStaked,
    DeepUnstaked, ExpiryCashRebalanced, ExpiryCashReceived, ExpiryMaxFundingUpdated,
    ExpiryProfitMaterialized, LiquidatedOrderRedeemed, LiveOrderRedeemed, MarketCreated,
    MarketOracleSettled, OrderLiquidated, OrderMinted, PredictManagerCreated, PythSourceUpdated,
    SettledOrderRedeemed, SupplyExecuted, TradingLossRebateClaimed, WithdrawExecuted,
};
use predict_schema::schema;
use serde_json::Value;

use diesel_async::RunQueryDsl;
use prometheus::Registry;
use std::sync::Arc;
use sui_indexer_alt_metrics::db::DbConnectionStatsCollector;
use sui_pg_db::{Db, DbArgs};
use url::Url;

/// Total intra-checkpoint ordering triple `(checkpoint_timestamp_ms, tx_index,
/// event_index)`. The timestamp is the page filter/sort key; `tx_index` and
/// `event_index` break ties within a checkpoint (all events in one checkpoint
/// share a timestamp).
type SortKey = (i64, i64, i64);

/// Runs a single-table timestamp-window query and projects each row into a
/// `(SortKey, serde_json::Value)` feed item, injecting a `"kind"` field naming
/// the event. Rows are filtered to `[start_time_ms, end_time_ms]`, ordered
/// newest-first, and capped at `limit`. `$model` must be the table's
/// `Selectable` model; `$table` is its schema module and (stringified) the
/// `"kind"`.
macro_rules! feed_page {
    ($conn:expr, $table:ident, $model:ty, $filter_col:ident, $id:expr, $start:expr, $end:expr, $limit:expr) => {{
        let rows: Vec<$model> = schema::$table::table
            .filter(schema::$table::$filter_col.eq($id))
            .filter(schema::$table::checkpoint_timestamp_ms.between($start, $end))
            .order_by((
                schema::$table::checkpoint_timestamp_ms.desc(),
                schema::$table::tx_index.desc(),
                schema::$table::event_index.desc(),
            ))
            .limit($limit)
            .select(<$model>::as_select())
            .load(&mut $conn)
            .await
            .map_err(|e| PredictError::database(e.to_string()))?;

        rows.into_iter()
            .map(|row| {
                let key: SortKey = (row.checkpoint_timestamp_ms, row.tx_index, row.event_index);
                let mut value = serde_json::to_value(row)
                    .map_err(|e| PredictError::deserialization(e.to_string()))?;
                if let Value::Object(map) = &mut value {
                    map.insert(
                        "kind".to_string(),
                        Value::String(stringify!($table).to_string()),
                    );
                }
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

/// Runs a single-table timestamp-window query with an OPTIONAL id filter and
/// returns a finished page (`Vec<Value>`, each row carrying its `"kind"`). When
/// `$id` is `Some`, filters `$filter_col.eq(id)`; when `None`, windows the whole
/// table. Otherwise identical to `feed_page!`: windowed to `[start, end]`,
/// newest-first, capped at `limit`. Used by the optional-filter list endpoints
/// (`/managers`, `/markets`).
macro_rules! feed_page_opt {
    ($conn:expr, $table:ident, $model:ty, $filter_col:ident, $id:expr, $start:expr, $end:expr, $limit:expr) => {{
        let mut query = schema::$table::table
            .filter(schema::$table::checkpoint_timestamp_ms.between($start, $end))
            .order_by((
                schema::$table::checkpoint_timestamp_ms.desc(),
                schema::$table::tx_index.desc(),
                schema::$table::event_index.desc(),
            ))
            .limit($limit)
            .select(<$model>::as_select())
            .into_boxed();
        if let Some(id) = $id {
            query = query.filter(schema::$table::$filter_col.eq(id));
        }
        let rows: Vec<$model> = query
            .load(&mut $conn)
            .await
            .map_err(|e| PredictError::database(e.to_string()))?;
        project_rows(rows, stringify!($table))
    }};
}

/// Projects loaded rows into finished feed `Value`s, injecting `"kind"`. Shared
/// by the optional-filter list endpoints; the merge feeds reuse `feed_page!` +
/// `merge_feed` instead (they need the `SortKey` to interleave tables).
fn project_rows<T: serde::Serialize>(rows: Vec<T>, kind: &str) -> Result<Vec<Value>, PredictError> {
    rows.into_iter()
        .map(|row| {
            let mut value = serde_json::to_value(row)
                .map_err(|e| PredictError::deserialization(e.to_string()))?;
            if let Value::Object(map) = &mut value {
                map.insert("kind".to_string(), Value::String(kind.to_string()));
            }
            Ok(value)
        })
        .collect()
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
    /// newest first by `(checkpoint_timestamp_ms, tx_index, event_index)`.
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
    /// by `(checkpoint_timestamp_ms, tx_index, event_index)`.
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
    /// newest-first by `(checkpoint_timestamp_ms, tx_index, event_index)`.
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
}
