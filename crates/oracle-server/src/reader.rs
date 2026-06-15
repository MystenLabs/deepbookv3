// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use crate::error::OracleError;
use crate::metrics::RpcMetrics;
use diesel::{ExpressionMethods, OptionalExtension, QueryDsl, SelectableHelper};
use predict_schema::models::{
    BlockScholesObservation, OracleBound, OracleSourceRegistered, OracleSpot1m, PythObservation,
};
use predict_schema::schema;
use serde_json::Value;

use diesel_async::RunQueryDsl;
use prometheus::Registry;
use std::sync::Arc;
use sui_indexer_alt_metrics::db::DbConnectionStatsCollector;
use sui_pg_db::{Db, DbArgs};
use url::Url;

/// Loads one table's timestamp-window page: rows filtered to `[start, end]`
/// (and to `$filter_col = id` when `$id` is `Some`), ordered newest-first by
/// `(checkpoint_timestamp_ms, checkpoint, tx_index, event_index)`, capped at
/// `limit`. The single home of the windowed-feed ordering contract. NEVER order
/// an oracle series by a domain timestamp (`source_timestamp_ms`): a
/// stale-but-later-landing update can carry an older source timestamp.
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
            .map_err(|e| OracleError::database(e.to_string()))
    }};
}

/// Runs a single-table timestamp-window query (`window_rows!`) with an
/// OPTIONAL id filter and returns a finished page (`Vec<Value>`, each row
/// carrying its `"kind"`). Used by the optional-filter list endpoints.
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

/// Projects loaded rows into finished feed `Value`s, injecting `"kind"`.
fn project_rows<T: serde::Serialize>(rows: Vec<T>, kind: &str) -> Result<Vec<Value>, OracleError> {
    rows.into_iter().map(|row| project_row(row, kind)).collect()
}

/// Single-row variant of `project_rows`.
fn project_row<T: serde::Serialize>(row: T, kind: &str) -> Result<Value, OracleError> {
    let mut value =
        serde_json::to_value(row).map_err(|e| OracleError::deserialization(e.to_string()))?;
    if let Value::Object(map) = &mut value {
        map.insert("kind".to_string(), Value::String(kind.to_string()));
    }
    Ok(value)
}

/// Typed latest row of a raw event table: a bounded top-1 index scan ordered
/// by `(checkpoint, tx_index, event_index)` — the only total event order. With
/// `$filter_col`/`$id`, scopes to one id; without, scans the whole table.
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
            .map_err(|e| OracleError::database(e.to_string()))?
    };
}

/// Projected latest row (`latest_row_typed!` + `project_row`).
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
            .map_err(|e| OracleError::database(e.to_string()))?;
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
            Some("oracle_api_db"),
            db.clone(),
        )))?;

        // Try to open a read connection to verify we can
        // connect to the DB on startup.
        let _ = db.connect().await?;

        Ok(Self { db, metrics })
    }

    pub async fn get_watermarks(&self) -> Result<Vec<(String, i64, i64, i64)>, OracleError> {
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
            .map_err(|_| OracleError::database("Error fetching watermarks"));

        if res.is_ok() {
            self.metrics.db_requests_succeeded.inc();
        } else {
            self.metrics.db_requests_failed.inc();
        }
        res
    }

    /// `pyth_observation` window for one oracle, newest-first. `is_exact`
    /// optionally restricts to the live (false) or exact-ms (true) lane.
    pub async fn get_oracle_pyth(
        &self,
        propbook_oracle_id: String,
        is_exact: Option<bool>,
        start_time_ms: i64,
        end_time_ms: i64,
        limit: i64,
    ) -> Result<Vec<Value>, OracleError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();

        let mut query = schema::pyth_observation::table
            .filter(schema::pyth_observation::propbook_oracle_id.eq(propbook_oracle_id))
            .filter(
                schema::pyth_observation::checkpoint_timestamp_ms
                    .between(start_time_ms, end_time_ms),
            )
            .order_by((
                schema::pyth_observation::checkpoint_timestamp_ms.desc(),
                schema::pyth_observation::checkpoint.desc(),
                schema::pyth_observation::tx_index.desc(),
                schema::pyth_observation::event_index.desc(),
            ))
            .limit(limit)
            .select(PythObservation::as_select())
            .into_boxed();
        if let Some(exact) = is_exact {
            query = query.filter(schema::pyth_observation::is_exact.eq(exact));
        }
        let rows = query
            .load::<PythObservation>(&mut conn)
            .await
            .map_err(|e| OracleError::database(e.to_string()))?;
        project_rows(rows, "pyth_observation")
    }

    /// Latest live Pyth spot observation for one oracle (top-1 over the live
    /// lane, `is_exact = false`).
    pub async fn get_oracle_pyth_latest(
        &self,
        propbook_oracle_id: String,
    ) -> Result<Value, OracleError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();

        let row: Option<PythObservation> = schema::pyth_observation::table
            .filter(schema::pyth_observation::propbook_oracle_id.eq(propbook_oracle_id))
            .filter(schema::pyth_observation::is_exact.eq(false))
            .order_by((
                schema::pyth_observation::checkpoint.desc(),
                schema::pyth_observation::tx_index.desc(),
                schema::pyth_observation::event_index.desc(),
            ))
            .select(PythObservation::as_select())
            .first(&mut conn)
            .await
            .optional()
            .map_err(|e| OracleError::database(e.to_string()))?;
        Ok(row
            .map(|r| project_row(r, "pyth_observation"))
            .transpose()?
            .unwrap_or(Value::Null))
    }

    /// `block_scholes_observation` window for one oracle, newest-first.
    /// Optionally restricted by `expiry_ms` and/or `is_exact`.
    pub async fn get_oracle_block_scholes(
        &self,
        propbook_oracle_id: String,
        expiry_ms: Option<i64>,
        is_exact: Option<bool>,
        start_time_ms: i64,
        end_time_ms: i64,
        limit: i64,
    ) -> Result<Vec<Value>, OracleError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();

        let mut query = schema::block_scholes_observation::table
            .filter(schema::block_scholes_observation::propbook_oracle_id.eq(propbook_oracle_id))
            .filter(
                schema::block_scholes_observation::checkpoint_timestamp_ms
                    .between(start_time_ms, end_time_ms),
            )
            .order_by((
                schema::block_scholes_observation::checkpoint_timestamp_ms.desc(),
                schema::block_scholes_observation::checkpoint.desc(),
                schema::block_scholes_observation::tx_index.desc(),
                schema::block_scholes_observation::event_index.desc(),
            ))
            .limit(limit)
            .select(BlockScholesObservation::as_select())
            .into_boxed();
        if let Some(expiry) = expiry_ms {
            query = query.filter(schema::block_scholes_observation::expiry_ms.eq(expiry));
        }
        if let Some(exact) = is_exact {
            query = query.filter(schema::block_scholes_observation::is_exact.eq(exact));
        }
        let rows = query
            .load::<BlockScholesObservation>(&mut conn)
            .await
            .map_err(|e| OracleError::database(e.to_string()))?;
        project_rows(rows, "block_scholes_observation")
    }

    /// `oracle_spot_1m` buckets for one oracle, newest bucket first. The view is
    /// keyed by `(propbook_oracle_id, expiry_ms, bucket_ms)`; this filters by
    /// `propbook_oracle_id` only and returns all expiries' buckets in the
    /// window.
    pub async fn get_oracle_block_scholes_sampled(
        &self,
        propbook_oracle_id: String,
        start_time_ms: i64,
        end_time_ms: i64,
        limit: i64,
    ) -> Result<Vec<Value>, OracleError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();
        bucket_feed!(
            conn,
            oracle_spot_1m,
            OracleSpot1m,
            propbook_oracle_id,
            propbook_oracle_id.clone(),
            start_time_ms,
            end_time_ms,
            limit
        )
    }

    /// `oracle_source_registered` list, newest-first.
    pub async fn get_oracle_sources(
        &self,
        start_time_ms: i64,
        end_time_ms: i64,
        limit: i64,
    ) -> Result<Vec<Value>, OracleError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();
        feed_page_opt!(
            conn,
            oracle_source_registered,
            OracleSourceRegistered,
            propbook_oracle_id,
            None::<String>,
            start_time_ms,
            end_time_ms,
            limit
        )
    }

    /// `oracle_bound` list, newest-first. Optionally filtered by
    /// `propbook_underlying_id`.
    pub async fn get_oracle_bindings(
        &self,
        propbook_underlying_id: Option<i64>,
        start_time_ms: i64,
        end_time_ms: i64,
        limit: i64,
    ) -> Result<Vec<Value>, OracleError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();
        feed_page_opt!(
            conn,
            oracle_bound,
            OracleBound,
            propbook_underlying_id,
            propbook_underlying_id,
            start_time_ms,
            end_time_ms,
            limit
        )
    }

    /// Current canonical binding(s) for one underlying: the latest `oracle_bound`
    /// row per `(oracle_kind, value_kind)` is the active binding. Returns the
    /// most-recent binding row for the underlying (top-1 by event triple);
    /// `null` when unbound.
    pub async fn get_underlying_binding(
        &self,
        propbook_underlying_id: i64,
    ) -> Result<Value, OracleError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();

        Ok(latest_row!(
            conn,
            oracle_bound,
            OracleBound,
            propbook_underlying_id,
            propbook_underlying_id
        )
        .unwrap_or(Value::Null))
    }
}
