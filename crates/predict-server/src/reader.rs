// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use crate::error::PredictError;
use crate::metrics::RpcMetrics;
use diesel::{ExpressionMethods, QueryDsl, SelectableHelper};
use predict_schema::models::{
    LiquidatedOrderRedeemed, LiveOrderRedeemed, OrderLiquidated, OrderMinted, SettledOrderRedeemed,
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

/// Merges per-table feed items into one page: sorts by `SortKey` DESC and
/// truncates to `limit`.
fn merge_feed(mut items: Vec<(SortKey, Value)>, limit: i64) -> Vec<Value> {
    items.sort_by(|(a, _), (b, _)| b.cmp(a));
    items.truncate(limit as usize);
    items.into_iter().map(|(_, v)| v).collect()
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
}
