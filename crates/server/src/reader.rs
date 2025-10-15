use crate::error::DeepBookError;
use crate::metrics::RpcMetrics;
use deepbook_schema::models::{OrderFillSummary, Pools};
use deepbook_schema::schema;
use diesel::deserialize::FromSqlRow;
use diesel::dsl::sql;
use diesel::expression::QueryMetadata;
use diesel::pg::Pg;
use diesel::query_builder::{Query, QueryFragment, QueryId};
use diesel::query_dsl::CompatibleType;
use diesel::{
    BoolExpressionMethods, ExpressionMethods, QueryDsl, QueryableByName, SelectableHelper,
};
use diesel_async::methods::LoadQuery;
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use prometheus::Registry;
use std::sync::Arc;
use sui_indexer_alt_metrics::db::DbConnectionStatsCollector;
use sui_pg_db::{Db, DbArgs};
use url::Url;

#[derive(QueryableByName, Debug)]
struct OhclvRow {
    #[diesel(sql_type = diesel::sql_types::BigInt)]
    timestamp_ms: i64,
    #[diesel(sql_type = diesel::sql_types::Double)]
    open: f64,
    #[diesel(sql_type = diesel::sql_types::Double)]
    high: f64,
    #[diesel(sql_type = diesel::sql_types::Double)]
    low: f64,
    #[diesel(sql_type = diesel::sql_types::Double)]
    close: f64,
    #[diesel(sql_type = diesel::sql_types::Double)]
    base_volume: f64,
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
            Some("deepbook_api_db"),
            db.clone(),
        )))?;

        // Try to open a read connection to verify we can
        // connect to the DB on startup.
        let _ = db.connect().await?;

        Ok(Self { db, metrics })
    }

    pub(crate) async fn results<Q, U>(&self, query: Q) -> Result<Vec<U>, anyhow::Error>
    where
        U: Send,
        Q: RunQueryDsl<AsyncPgConnection> + 'static,
        Q: LoadQuery<'static, AsyncPgConnection, U> + QueryFragment<Pg> + Send,
    {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();
        let res = query.get_results(&mut conn).await;

        if res.is_ok() {
            self.metrics.db_requests_succeeded.inc();
        } else {
            self.metrics.db_requests_failed.inc();
        }

        Ok(res?)
    }

    pub async fn first<'q, Q, ST, U>(&self, query: Q) -> Result<U, anyhow::Error>
    where
        Q: diesel::query_dsl::limit_dsl::LimitDsl,
        Q::Output: Query + QueryFragment<Pg> + QueryId + Send + 'q,
        <Q::Output as Query>::SqlType: CompatibleType<U, Pg, SqlType = ST>,
        U: Send + FromSqlRow<ST, Pg> + 'static,
        Pg: QueryMetadata<<Q::Output as Query>::SqlType>,
        ST: 'static,
    {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();

        let res = query.first(&mut conn).await;
        if res.is_ok() {
            self.metrics.db_requests_succeeded.inc();
        } else {
            self.metrics.db_requests_failed.inc();
        }

        Ok(res?)
    }

    pub async fn get_pools(&self) -> Result<Vec<Pools>, DeepBookError> {
        Ok(self
            .results(schema::pools::table.select(Pools::as_select()))
            .await?)
    }

    pub async fn get_historical_volume(
        &self,
        start_time: i64,
        end_time: i64,
        pool_ids: &Vec<String>,
        volume_in_base: bool,
    ) -> Result<Vec<(String, i64)>, DeepBookError> {
        let column_to_query = if volume_in_base {
            sql::<diesel::sql_types::BigInt>("base_quantity")
        } else {
            sql::<diesel::sql_types::BigInt>("quote_quantity")
        };

        let query = schema::order_fills::table
            .filter(schema::order_fills::checkpoint_timestamp_ms.between(start_time, end_time))
            .filter(schema::order_fills::pool_id.eq_any(pool_ids.clone()))
            .select((schema::order_fills::pool_id, column_to_query));

        Ok(self.results(query).await?)
    }

    pub async fn get_order_fill_summary(
        &self,
        start_time: i64,
        end_time: i64,
        pool_ids: &Vec<String>,
        balance_manager_id: &str,
        volume_in_base: bool,
    ) -> Result<Vec<OrderFillSummary>, DeepBookError> {
        let column_to_query = if volume_in_base {
            sql::<diesel::sql_types::BigInt>("base_quantity")
        } else {
            sql::<diesel::sql_types::BigInt>("quote_quantity")
        };
        let balance_manager_id = balance_manager_id.to_string();
        let query = schema::order_fills::table
            .select((
                schema::order_fills::pool_id,
                schema::order_fills::maker_balance_manager_id,
                schema::order_fills::taker_balance_manager_id,
                column_to_query,
            ))
            .filter(schema::order_fills::pool_id.eq_any(pool_ids.clone()))
            .filter(schema::order_fills::checkpoint_timestamp_ms.between(start_time, end_time))
            .filter(
                schema::order_fills::maker_balance_manager_id
                    .eq(balance_manager_id.clone())
                    .or(schema::order_fills::taker_balance_manager_id.eq(balance_manager_id)),
            );
        Ok(self.results(query).await?)
    }

    pub async fn get_price(
        &self,
        start_time: i64,
        end_time: i64,
        pool_id: &str,
    ) -> Result<i64, DeepBookError> {
        let query = schema::order_fills::table
            .filter(schema::order_fills::checkpoint_timestamp_ms.between(start_time, end_time))
            .filter(schema::order_fills::pool_id.eq(pool_id))
            .order_by(schema::order_fills::checkpoint_timestamp_ms.desc())
            .select(schema::order_fills::price);
        Ok(self.first(query).await?)
    }

    pub async fn get_pool_decimals(
        &self,
        pool_name: &str,
    ) -> Result<(String, i16, i16), DeepBookError> {
        let query = schema::pools::table
            .filter(schema::pools::pool_name.eq(pool_name))
            .select((
                schema::pools::pool_id,
                schema::pools::base_asset_decimals,
                schema::pools::quote_asset_decimals,
            ));
        self.first(query)
            .await
            .map_err(|_| DeepBookError::InternalError(format!("Pool '{}' not found", pool_name)))
    }

    pub async fn get_orders(
        &self,
        pool_name: String,
        pool_id: String,
        start_time: i64,
        end_time: i64,
        limit: i64,
        maker_balance_manager: Option<String>,
        taker_balance_manager: Option<String>,
    ) -> Result<
        Vec<(
            String,
            String,
            String,
            String,
            i64,
            i64,
            i64,
            i64,
            bool,
            String,
            String,
            bool,
            bool,
            i64,
            i64,
        )>,
        DeepBookError,
    > {
        let mut connection = self.db.connect().await?;
        // Build the query dynamically
        let mut query = schema::order_fills::table
            .filter(schema::order_fills::pool_id.eq(pool_id))
            .filter(schema::order_fills::checkpoint_timestamp_ms.between(start_time, end_time))
            .into_boxed();

        // Apply optional filters if parameters are provided
        if let Some(maker_id) = maker_balance_manager {
            query = query.filter(schema::order_fills::maker_balance_manager_id.eq(maker_id));
        }
        if let Some(taker_id) = taker_balance_manager {
            query = query.filter(schema::order_fills::taker_balance_manager_id.eq(taker_id));
        }

        let _guard = self.metrics.db_latency.start_timer();

        // Fetch latest trades (sorted by timestamp in descending order) within the time range, applying the limit
        let res = query
            .order_by(schema::order_fills::checkpoint_timestamp_ms.desc()) // Ensures latest trades come first
            .limit(limit) // Apply limit to get the most recent trades
            .select((
                schema::order_fills::event_digest,
                schema::order_fills::digest,
                schema::order_fills::maker_order_id,
                schema::order_fills::taker_order_id,
                schema::order_fills::price,
                schema::order_fills::base_quantity,
                schema::order_fills::quote_quantity,
                schema::order_fills::checkpoint_timestamp_ms,
                schema::order_fills::taker_is_bid,
                schema::order_fills::maker_balance_manager_id,
                schema::order_fills::taker_balance_manager_id,
                schema::order_fills::taker_fee_is_deep,
                schema::order_fills::maker_fee_is_deep,
                schema::order_fills::taker_fee,
                schema::order_fills::maker_fee,
            ))
            .load::<(
                String,
                String,
                String,
                String,
                i64,
                i64,
                i64,
                i64,
                bool,
                String,
                String,
                bool,
                bool,
                i64,
                i64,
            )>(&mut connection)
            .await
            .map_err(|_| {
                DeepBookError::InternalError(format!(
                    "No trades found for pool '{}' in the specified time range",
                    pool_name
                ))
            });

        if res.is_ok() {
            self.metrics.db_requests_succeeded.inc();
        } else {
            self.metrics.db_requests_failed.inc();
        }
        res
    }

    pub async fn get_order_updates(
        &self,
        pool_id: String,
        start_time: i64,
        end_time: i64,
        limit: i64,
        balance_manager_filter: Option<String>,
        status_filter: Option<String>,
    ) -> Result<Vec<(String, i64, i64, i64, i64, i64, bool, String, String)>, DeepBookError> {
        let mut connection = self.db.connect().await?;
        let mut query = schema::order_updates::table
            .filter(schema::order_updates::checkpoint_timestamp_ms.between(start_time, end_time))
            .filter(schema::order_updates::pool_id.eq(pool_id))
            .order_by(schema::order_updates::checkpoint_timestamp_ms.desc())
            .select((
                schema::order_updates::order_id,
                schema::order_updates::price,
                schema::order_updates::original_quantity,
                schema::order_updates::quantity,
                schema::order_updates::filled_quantity,
                schema::order_updates::checkpoint_timestamp_ms,
                schema::order_updates::is_bid,
                schema::order_updates::balance_manager_id,
                schema::order_updates::status,
            ))
            .limit(limit)
            .into_boxed();

        if let Some(manager_id) = balance_manager_filter {
            query = query.filter(schema::order_updates::balance_manager_id.eq(manager_id));
        }

        if let Some(status) = status_filter {
            query = query.filter(schema::order_updates::status.eq(status));
        }

        let _guard = self.metrics.db_latency.start_timer();

        let res = query
            .load::<(String, i64, i64, i64, i64, i64, bool, String, String)>(&mut connection)
            .await
            .map_err(|_| DeepBookError::InternalError("Error fetching trade details".to_string()));

        if res.is_ok() {
            self.metrics.db_requests_succeeded.inc();
        } else {
            self.metrics.db_requests_failed.inc();
        }
        res
    }

    pub async fn get_ohclv(
        &self,
        pool_id: String,
        interval: String,
        start_time: Option<i64>,
        end_time: Option<i64>,
        limit: Option<i32>,
    ) -> Result<Vec<(i64, f64, f64, f64, f64, f64)>, DeepBookError> {
        let mut connection = self.db.connect().await?;
        let limit_val = limit.unwrap_or(1000);
        let _guard = self.metrics.db_latency.start_timer();
        let query_str = format!(
            "SELECT EXTRACT(EPOCH FROM bucket_time)::bigint * 1000 as timestamp_ms, \
             open::float8, high::float8, low::float8, close::float8, base_volume::float8 \
             FROM get_ohclv('{}', '{}', {}::timestamp, {}::timestamp, {})",
            interval,
            pool_id,
            start_time
                .map(|ts| format!("to_timestamp({})", ts / 1000))
                .unwrap_or_else(|| "NULL".to_string()),
            end_time
                .map(|ts| format!("to_timestamp({})", ts / 1000))
                .unwrap_or_else(|| "NULL".to_string()),
            limit_val
        );

        let res = diesel::sql_query(query_str)
            .load::<OhclvRow>(&mut connection)
            .await
            .map_err(|e| DeepBookError::InternalError(format!("Error fetching OHCLV data: {}", e)))
            .map(|rows| {
                rows.into_iter()
                    .map(|row| {
                        (
                            row.timestamp_ms,
                            row.open,
                            row.high,
                            row.low,
                            row.close,
                            row.base_volume,
                        )
                    })
                    .collect()
            });

        if res.is_ok() {
            self.metrics.db_requests_succeeded.inc();
        } else {
            self.metrics.db_requests_failed.inc();
        }
        res
    }
}
