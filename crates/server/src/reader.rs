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
use diesel::sql_types::{BigInt, Double};
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
    #[diesel(sql_type = BigInt)]
    timestamp_ms: i64,
    #[diesel(sql_type = Double)]
    open: f64,
    #[diesel(sql_type = Double)]
    high: f64,
    #[diesel(sql_type = Double)]
    low: f64,
    #[diesel(sql_type = Double)]
    close: f64,
    #[diesel(sql_type = Double)]
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

    // === Deepbook Margin Events ===
    pub async fn get_margin_manager_created(
        &self,
        start_time: i64,
        end_time: i64,
        limit: i64,
        margin_manager_id_filter: Option<String>,
    ) -> Result<
        Vec<(
            String,
            String,
            String,
            i64,
            i64,
            String,
            String,
            String,
            String,
            i64,
        )>,
        DeepBookError,
    > {
        let mut connection = self.db.connect().await?;
        let mut query = schema::margin_manager_created::table
            .filter(
                schema::margin_manager_created::checkpoint_timestamp_ms
                    .between(start_time, end_time),
            )
            .order_by(schema::margin_manager_created::checkpoint_timestamp_ms.desc())
            .select((
                schema::margin_manager_created::event_digest,
                schema::margin_manager_created::digest,
                schema::margin_manager_created::sender,
                schema::margin_manager_created::checkpoint,
                schema::margin_manager_created::checkpoint_timestamp_ms,
                schema::margin_manager_created::package,
                schema::margin_manager_created::margin_manager_id,
                schema::margin_manager_created::balance_manager_id,
                schema::margin_manager_created::owner,
                schema::margin_manager_created::onchain_timestamp,
            ))
            .limit(limit)
            .into_boxed();

        if let Some(manager_id) = margin_manager_id_filter {
            query = query.filter(schema::margin_manager_created::margin_manager_id.eq(manager_id));
        }

        let _guard = self.metrics.db_latency.start_timer();
        let res = query
            .load::<(
                String,
                String,
                String,
                i64,
                i64,
                String,
                String,
                String,
                String,
                i64,
            )>(&mut connection)
            .await
            .map_err(|_| {
                DeepBookError::InternalError(
                    "Error fetching margin manager created events".to_string(),
                )
            });

        if res.is_ok() {
            self.metrics.db_requests_succeeded.inc();
        } else {
            self.metrics.db_requests_failed.inc();
        }
        res
    }

    pub async fn get_loan_borrowed(
        &self,
        start_time: i64,
        end_time: i64,
        limit: i64,
        margin_manager_id_filter: Option<String>,
        margin_pool_id_filter: Option<String>,
    ) -> Result<
        Vec<(
            String,
            String,
            String,
            i64,
            i64,
            String,
            String,
            String,
            i64,
            i64,
            i64,
        )>,
        DeepBookError,
    > {
        let mut connection = self.db.connect().await?;
        let mut query = schema::loan_borrowed::table
            .filter(schema::loan_borrowed::checkpoint_timestamp_ms.between(start_time, end_time))
            .order_by(schema::loan_borrowed::checkpoint_timestamp_ms.desc())
            .select((
                schema::loan_borrowed::event_digest,
                schema::loan_borrowed::digest,
                schema::loan_borrowed::sender,
                schema::loan_borrowed::checkpoint,
                schema::loan_borrowed::checkpoint_timestamp_ms,
                schema::loan_borrowed::package,
                schema::loan_borrowed::margin_manager_id,
                schema::loan_borrowed::margin_pool_id,
                schema::loan_borrowed::loan_amount,
                schema::loan_borrowed::loan_shares,
                schema::loan_borrowed::onchain_timestamp,
            ))
            .limit(limit)
            .into_boxed();

        if let Some(manager_id) = margin_manager_id_filter {
            query = query.filter(schema::loan_borrowed::margin_manager_id.eq(manager_id));
        }
        if let Some(pool_id) = margin_pool_id_filter {
            query = query.filter(schema::loan_borrowed::margin_pool_id.eq(pool_id));
        }

        let _guard = self.metrics.db_latency.start_timer();
        let res = query
            .load::<(
                String,
                String,
                String,
                i64,
                i64,
                String,
                String,
                String,
                i64,
                i64,
                i64,
            )>(&mut connection)
            .await
            .map_err(|_| {
                DeepBookError::InternalError("Error fetching loan borrowed events".to_string())
            });

        if res.is_ok() {
            self.metrics.db_requests_succeeded.inc();
        } else {
            self.metrics.db_requests_failed.inc();
        }
        res
    }

    pub async fn get_loan_repaid(
        &self,
        start_time: i64,
        end_time: i64,
        limit: i64,
        margin_manager_id_filter: Option<String>,
        margin_pool_id_filter: Option<String>,
    ) -> Result<
        Vec<(
            String,
            String,
            String,
            i64,
            i64,
            String,
            String,
            String,
            i64,
            i64,
            i64,
        )>,
        DeepBookError,
    > {
        let mut connection = self.db.connect().await?;
        let mut query = schema::loan_repaid::table
            .filter(schema::loan_repaid::checkpoint_timestamp_ms.between(start_time, end_time))
            .order_by(schema::loan_repaid::checkpoint_timestamp_ms.desc())
            .select((
                schema::loan_repaid::event_digest,
                schema::loan_repaid::digest,
                schema::loan_repaid::sender,
                schema::loan_repaid::checkpoint,
                schema::loan_repaid::checkpoint_timestamp_ms,
                schema::loan_repaid::package,
                schema::loan_repaid::margin_manager_id,
                schema::loan_repaid::margin_pool_id,
                schema::loan_repaid::repay_amount,
                schema::loan_repaid::repay_shares,
                schema::loan_repaid::onchain_timestamp,
            ))
            .limit(limit)
            .into_boxed();

        if let Some(manager_id) = margin_manager_id_filter {
            query = query.filter(schema::loan_repaid::margin_manager_id.eq(manager_id));
        }
        if let Some(pool_id) = margin_pool_id_filter {
            query = query.filter(schema::loan_repaid::margin_pool_id.eq(pool_id));
        }

        let _guard = self.metrics.db_latency.start_timer();
        let res = query
            .load::<(
                String,
                String,
                String,
                i64,
                i64,
                String,
                String,
                String,
                i64,
                i64,
                i64,
            )>(&mut connection)
            .await
            .map_err(|_| {
                DeepBookError::InternalError("Error fetching loan repaid events".to_string())
            });

        if res.is_ok() {
            self.metrics.db_requests_succeeded.inc();
        } else {
            self.metrics.db_requests_failed.inc();
        }
        res
    }

    pub async fn get_liquidation(
        &self,
        start_time: i64,
        end_time: i64,
        limit: i64,
        margin_manager_id_filter: Option<String>,
        margin_pool_id_filter: Option<String>,
    ) -> Result<
        Vec<(
            String,
            String,
            String,
            i64,
            i64,
            String,
            String,
            String,
            i64,
            i64,
            i64,
            i64,
            i64,
        )>,
        DeepBookError,
    > {
        let mut connection = self.db.connect().await?;
        let mut query = schema::liquidation::table
            .filter(schema::liquidation::checkpoint_timestamp_ms.between(start_time, end_time))
            .order_by(schema::liquidation::checkpoint_timestamp_ms.desc())
            .select((
                schema::liquidation::event_digest,
                schema::liquidation::digest,
                schema::liquidation::sender,
                schema::liquidation::checkpoint,
                schema::liquidation::checkpoint_timestamp_ms,
                schema::liquidation::package,
                schema::liquidation::margin_manager_id,
                schema::liquidation::margin_pool_id,
                schema::liquidation::liquidation_amount,
                schema::liquidation::pool_reward,
                schema::liquidation::pool_default,
                schema::liquidation::risk_ratio,
                schema::liquidation::onchain_timestamp,
            ))
            .limit(limit)
            .into_boxed();

        if let Some(manager_id) = margin_manager_id_filter {
            query = query.filter(schema::liquidation::margin_manager_id.eq(manager_id));
        }
        if let Some(pool_id) = margin_pool_id_filter {
            query = query.filter(schema::liquidation::margin_pool_id.eq(pool_id));
        }

        let _guard = self.metrics.db_latency.start_timer();
        let res = query
            .load::<(
                String,
                String,
                String,
                i64,
                i64,
                String,
                String,
                String,
                i64,
                i64,
                i64,
                i64,
                i64,
            )>(&mut connection)
            .await
            .map_err(|_| {
                DeepBookError::InternalError("Error fetching liquidation events".to_string())
            });

        if res.is_ok() {
            self.metrics.db_requests_succeeded.inc();
        } else {
            self.metrics.db_requests_failed.inc();
        }
        res
    }

    pub async fn get_asset_supplied(
        &self,
        start_time: i64,
        end_time: i64,
        limit: i64,
        margin_pool_id_filter: Option<String>,
        supplier_filter: Option<String>,
    ) -> Result<
        Vec<(
            String,
            String,
            String,
            i64,
            i64,
            String,
            String,
            String,
            String,
            i64,
            i64,
            i64,
        )>,
        DeepBookError,
    > {
        let mut connection = self.db.connect().await?;
        let mut query = schema::asset_supplied::table
            .filter(schema::asset_supplied::checkpoint_timestamp_ms.between(start_time, end_time))
            .order_by(schema::asset_supplied::checkpoint_timestamp_ms.desc())
            .select((
                schema::asset_supplied::event_digest,
                schema::asset_supplied::digest,
                schema::asset_supplied::sender,
                schema::asset_supplied::checkpoint,
                schema::asset_supplied::checkpoint_timestamp_ms,
                schema::asset_supplied::package,
                schema::asset_supplied::margin_pool_id,
                schema::asset_supplied::asset_type,
                schema::asset_supplied::supplier,
                schema::asset_supplied::amount,
                schema::asset_supplied::shares,
                schema::asset_supplied::onchain_timestamp,
            ))
            .limit(limit)
            .into_boxed();

        if let Some(pool_id) = margin_pool_id_filter {
            query = query.filter(schema::asset_supplied::margin_pool_id.eq(pool_id));
        }
        if let Some(supplier) = supplier_filter {
            query = query.filter(schema::asset_supplied::supplier.eq(supplier));
        }

        let _guard = self.metrics.db_latency.start_timer();
        let res = query
            .load::<(
                String,
                String,
                String,
                i64,
                i64,
                String,
                String,
                String,
                String,
                i64,
                i64,
                i64,
            )>(&mut connection)
            .await
            .map_err(|_| {
                DeepBookError::InternalError("Error fetching asset supplied events".to_string())
            });

        if res.is_ok() {
            self.metrics.db_requests_succeeded.inc();
        } else {
            self.metrics.db_requests_failed.inc();
        }
        res
    }

    pub async fn get_asset_withdrawn(
        &self,
        start_time: i64,
        end_time: i64,
        limit: i64,
        margin_pool_id_filter: Option<String>,
        supplier_filter: Option<String>,
    ) -> Result<
        Vec<(
            String,
            String,
            String,
            i64,
            i64,
            String,
            String,
            String,
            String,
            i64,
            i64,
            i64,
        )>,
        DeepBookError,
    > {
        let mut connection = self.db.connect().await?;
        let mut query = schema::asset_withdrawn::table
            .filter(schema::asset_withdrawn::checkpoint_timestamp_ms.between(start_time, end_time))
            .order_by(schema::asset_withdrawn::checkpoint_timestamp_ms.desc())
            .select((
                schema::asset_withdrawn::event_digest,
                schema::asset_withdrawn::digest,
                schema::asset_withdrawn::sender,
                schema::asset_withdrawn::checkpoint,
                schema::asset_withdrawn::checkpoint_timestamp_ms,
                schema::asset_withdrawn::package,
                schema::asset_withdrawn::margin_pool_id,
                schema::asset_withdrawn::asset_type,
                schema::asset_withdrawn::supplier,
                schema::asset_withdrawn::amount,
                schema::asset_withdrawn::shares,
                schema::asset_withdrawn::onchain_timestamp,
            ))
            .limit(limit)
            .into_boxed();

        if let Some(pool_id) = margin_pool_id_filter {
            query = query.filter(schema::asset_withdrawn::margin_pool_id.eq(pool_id));
        }
        if let Some(supplier) = supplier_filter {
            query = query.filter(schema::asset_withdrawn::supplier.eq(supplier));
        }

        let _guard = self.metrics.db_latency.start_timer();
        let res = query
            .load::<(
                String,
                String,
                String,
                i64,
                i64,
                String,
                String,
                String,
                String,
                i64,
                i64,
                i64,
            )>(&mut connection)
            .await
            .map_err(|_| {
                DeepBookError::InternalError("Error fetching asset withdrawn events".to_string())
            });

        if res.is_ok() {
            self.metrics.db_requests_succeeded.inc();
        } else {
            self.metrics.db_requests_failed.inc();
        }
        res
    }

    pub async fn get_margin_pool_created(
        &self,
        start_time: i64,
        end_time: i64,
        limit: i64,
        margin_pool_id_filter: Option<String>,
    ) -> Result<
        Vec<(
            String,
            String,
            String,
            i64,
            i64,
            String,
            String,
            String,
            String,
            serde_json::Value,
            i64,
        )>,
        DeepBookError,
    > {
        let mut connection = self.db.connect().await?;
        let mut query = schema::margin_pool_created::table
            .filter(
                schema::margin_pool_created::checkpoint_timestamp_ms.between(start_time, end_time),
            )
            .order_by(schema::margin_pool_created::checkpoint_timestamp_ms.desc())
            .select((
                schema::margin_pool_created::event_digest,
                schema::margin_pool_created::digest,
                schema::margin_pool_created::sender,
                schema::margin_pool_created::checkpoint,
                schema::margin_pool_created::checkpoint_timestamp_ms,
                schema::margin_pool_created::package,
                schema::margin_pool_created::margin_pool_id,
                schema::margin_pool_created::maintainer_cap_id,
                schema::margin_pool_created::asset_type,
                schema::margin_pool_created::config_json,
                schema::margin_pool_created::onchain_timestamp,
            ))
            .limit(limit)
            .into_boxed();

        if let Some(pool_id) = margin_pool_id_filter {
            query = query.filter(schema::margin_pool_created::margin_pool_id.eq(pool_id));
        }

        let _guard = self.metrics.db_latency.start_timer();
        let res = query
            .load::<(
                String,
                String,
                String,
                i64,
                i64,
                String,
                String,
                String,
                String,
                serde_json::Value,
                i64,
            )>(&mut connection)
            .await
            .map_err(|_| {
                DeepBookError::InternalError(
                    "Error fetching margin pool created events".to_string(),
                )
            });

        if res.is_ok() {
            self.metrics.db_requests_succeeded.inc();
        } else {
            self.metrics.db_requests_failed.inc();
        }
        res
    }

    pub async fn get_deepbook_pool_updated(
        &self,
        start_time: i64,
        end_time: i64,
        limit: i64,
        margin_pool_id_filter: Option<String>,
        deepbook_pool_id_filter: Option<String>,
    ) -> Result<
        Vec<(
            String,
            String,
            String,
            i64,
            i64,
            String,
            String,
            String,
            String,
            bool,
            i64,
        )>,
        DeepBookError,
    > {
        let mut connection = self.db.connect().await?;
        let mut query = schema::deepbook_pool_updated::table
            .filter(
                schema::deepbook_pool_updated::checkpoint_timestamp_ms
                    .between(start_time, end_time),
            )
            .order_by(schema::deepbook_pool_updated::checkpoint_timestamp_ms.desc())
            .select((
                schema::deepbook_pool_updated::event_digest,
                schema::deepbook_pool_updated::digest,
                schema::deepbook_pool_updated::sender,
                schema::deepbook_pool_updated::checkpoint,
                schema::deepbook_pool_updated::checkpoint_timestamp_ms,
                schema::deepbook_pool_updated::package,
                schema::deepbook_pool_updated::margin_pool_id,
                schema::deepbook_pool_updated::deepbook_pool_id,
                schema::deepbook_pool_updated::pool_cap_id,
                schema::deepbook_pool_updated::enabled,
                schema::deepbook_pool_updated::onchain_timestamp,
            ))
            .limit(limit)
            .into_boxed();

        if let Some(pool_id) = margin_pool_id_filter {
            query = query.filter(schema::deepbook_pool_updated::margin_pool_id.eq(pool_id));
        }
        if let Some(deepbook_pool_id) = deepbook_pool_id_filter {
            query =
                query.filter(schema::deepbook_pool_updated::deepbook_pool_id.eq(deepbook_pool_id));
        }

        let _guard = self.metrics.db_latency.start_timer();
        let res = query
            .load::<(
                String,
                String,
                String,
                i64,
                i64,
                String,
                String,
                String,
                String,
                bool,
                i64,
            )>(&mut connection)
            .await
            .map_err(|_| {
                DeepBookError::InternalError(
                    "Error fetching deepbook pool updated events".to_string(),
                )
            });

        if res.is_ok() {
            self.metrics.db_requests_succeeded.inc();
        } else {
            self.metrics.db_requests_failed.inc();
        }
        res
    }

    pub async fn get_interest_params_updated(
        &self,
        start_time: i64,
        end_time: i64,
        limit: i64,
        margin_pool_id_filter: Option<String>,
    ) -> Result<
        Vec<(
            String,
            String,
            String,
            i64,
            i64,
            String,
            String,
            String,
            serde_json::Value,
            i64,
        )>,
        DeepBookError,
    > {
        let mut connection = self.db.connect().await?;
        let mut query = schema::interest_params_updated::table
            .filter(
                schema::interest_params_updated::checkpoint_timestamp_ms
                    .between(start_time, end_time),
            )
            .order_by(schema::interest_params_updated::checkpoint_timestamp_ms.desc())
            .select((
                schema::interest_params_updated::event_digest,
                schema::interest_params_updated::digest,
                schema::interest_params_updated::sender,
                schema::interest_params_updated::checkpoint,
                schema::interest_params_updated::checkpoint_timestamp_ms,
                schema::interest_params_updated::package,
                schema::interest_params_updated::margin_pool_id,
                schema::interest_params_updated::pool_cap_id,
                schema::interest_params_updated::config_json,
                schema::interest_params_updated::onchain_timestamp,
            ))
            .limit(limit)
            .into_boxed();

        if let Some(pool_id) = margin_pool_id_filter {
            query = query.filter(schema::interest_params_updated::margin_pool_id.eq(pool_id));
        }

        let _guard = self.metrics.db_latency.start_timer();
        let res = query
            .load::<(
                String,
                String,
                String,
                i64,
                i64,
                String,
                String,
                String,
                serde_json::Value,
                i64,
            )>(&mut connection)
            .await
            .map_err(|_| {
                DeepBookError::InternalError(
                    "Error fetching interest params updated events".to_string(),
                )
            });

        if res.is_ok() {
            self.metrics.db_requests_succeeded.inc();
        } else {
            self.metrics.db_requests_failed.inc();
        }
        res
    }

    pub async fn get_margin_pool_config_updated(
        &self,
        start_time: i64,
        end_time: i64,
        limit: i64,
        margin_pool_id_filter: Option<String>,
    ) -> Result<
        Vec<(
            String,
            String,
            String,
            i64,
            i64,
            String,
            String,
            String,
            serde_json::Value,
            i64,
        )>,
        DeepBookError,
    > {
        let mut connection = self.db.connect().await?;
        let mut query = schema::margin_pool_config_updated::table
            .filter(
                schema::margin_pool_config_updated::checkpoint_timestamp_ms
                    .between(start_time, end_time),
            )
            .order_by(schema::margin_pool_config_updated::checkpoint_timestamp_ms.desc())
            .select((
                schema::margin_pool_config_updated::event_digest,
                schema::margin_pool_config_updated::digest,
                schema::margin_pool_config_updated::sender,
                schema::margin_pool_config_updated::checkpoint,
                schema::margin_pool_config_updated::checkpoint_timestamp_ms,
                schema::margin_pool_config_updated::package,
                schema::margin_pool_config_updated::margin_pool_id,
                schema::margin_pool_config_updated::pool_cap_id,
                schema::margin_pool_config_updated::config_json,
                schema::margin_pool_config_updated::onchain_timestamp,
            ))
            .limit(limit)
            .into_boxed();

        if let Some(pool_id) = margin_pool_id_filter {
            query = query.filter(schema::margin_pool_config_updated::margin_pool_id.eq(pool_id));
        }

        let _guard = self.metrics.db_latency.start_timer();
        let res = query
            .load::<(
                String,
                String,
                String,
                i64,
                i64,
                String,
                String,
                String,
                serde_json::Value,
                i64,
            )>(&mut connection)
            .await
            .map_err(|_| {
                DeepBookError::InternalError(
                    "Error fetching margin pool config updated events".to_string(),
                )
            });

        if res.is_ok() {
            self.metrics.db_requests_succeeded.inc();
        } else {
            self.metrics.db_requests_failed.inc();
        }
        res
    }

    pub async fn get_maintainer_cap_updated(
        &self,
        start_time: i64,
        end_time: i64,
        limit: i64,
        maintainer_cap_id_filter: Option<String>,
    ) -> Result<Vec<(String, String, String, i64, i64, String, String, bool, i64)>, DeepBookError>
    {
        let mut connection = self.db.connect().await?;
        let mut query = schema::maintainer_cap_updated::table
            .filter(
                schema::maintainer_cap_updated::checkpoint_timestamp_ms
                    .between(start_time, end_time),
            )
            .order_by(schema::maintainer_cap_updated::checkpoint_timestamp_ms.desc())
            .select((
                schema::maintainer_cap_updated::event_digest,
                schema::maintainer_cap_updated::digest,
                schema::maintainer_cap_updated::sender,
                schema::maintainer_cap_updated::checkpoint,
                schema::maintainer_cap_updated::checkpoint_timestamp_ms,
                schema::maintainer_cap_updated::package,
                schema::maintainer_cap_updated::maintainer_cap_id,
                schema::maintainer_cap_updated::allowed,
                schema::maintainer_cap_updated::onchain_timestamp,
            ))
            .limit(limit)
            .into_boxed();

        if let Some(cap_id) = maintainer_cap_id_filter {
            query = query.filter(schema::maintainer_cap_updated::maintainer_cap_id.eq(cap_id));
        }

        let _guard = self.metrics.db_latency.start_timer();
        let res = query
            .load::<(String, String, String, i64, i64, String, String, bool, i64)>(&mut connection)
            .await
            .map_err(|_| {
                DeepBookError::InternalError(
                    "Error fetching maintainer cap updated events".to_string(),
                )
            });

        if res.is_ok() {
            self.metrics.db_requests_succeeded.inc();
        } else {
            self.metrics.db_requests_failed.inc();
        }
        res
    }

    pub async fn get_deepbook_pool_registered(
        &self,
        start_time: i64,
        end_time: i64,
        limit: i64,
        pool_id_filter: Option<String>,
    ) -> Result<Vec<(String, String, String, i64, i64, String, String, i64)>, DeepBookError> {
        let mut connection = self.db.connect().await?;
        let mut query = schema::deepbook_pool_registered::table
            .filter(
                schema::deepbook_pool_registered::checkpoint_timestamp_ms
                    .between(start_time, end_time),
            )
            .order_by(schema::deepbook_pool_registered::checkpoint_timestamp_ms.desc())
            .select((
                schema::deepbook_pool_registered::event_digest,
                schema::deepbook_pool_registered::digest,
                schema::deepbook_pool_registered::sender,
                schema::deepbook_pool_registered::checkpoint,
                schema::deepbook_pool_registered::checkpoint_timestamp_ms,
                schema::deepbook_pool_registered::package,
                schema::deepbook_pool_registered::pool_id,
                schema::deepbook_pool_registered::onchain_timestamp,
            ))
            .limit(limit)
            .into_boxed();

        if let Some(pool_id) = pool_id_filter {
            query = query.filter(schema::deepbook_pool_registered::pool_id.eq(pool_id));
        }

        let _guard = self.metrics.db_latency.start_timer();
        let res = query
            .load::<(String, String, String, i64, i64, String, String, i64)>(&mut connection)
            .await
            .map_err(|_| {
                DeepBookError::InternalError(
                    "Error fetching deepbook pool registered events".to_string(),
                )
            });

        if res.is_ok() {
            self.metrics.db_requests_succeeded.inc();
        } else {
            self.metrics.db_requests_failed.inc();
        }
        res
    }

    pub async fn get_deepbook_pool_updated_registry(
        &self,
        start_time: i64,
        end_time: i64,
        limit: i64,
        pool_id_filter: Option<String>,
    ) -> Result<Vec<(String, String, String, i64, i64, String, String, bool, i64)>, DeepBookError>
    {
        let mut connection = self.db.connect().await?;
        let mut query = schema::deepbook_pool_updated_registry::table
            .filter(
                schema::deepbook_pool_updated_registry::checkpoint_timestamp_ms
                    .between(start_time, end_time),
            )
            .order_by(schema::deepbook_pool_updated_registry::checkpoint_timestamp_ms.desc())
            .select((
                schema::deepbook_pool_updated_registry::event_digest,
                schema::deepbook_pool_updated_registry::digest,
                schema::deepbook_pool_updated_registry::sender,
                schema::deepbook_pool_updated_registry::checkpoint,
                schema::deepbook_pool_updated_registry::checkpoint_timestamp_ms,
                schema::deepbook_pool_updated_registry::package,
                schema::deepbook_pool_updated_registry::pool_id,
                schema::deepbook_pool_updated_registry::enabled,
                schema::deepbook_pool_updated_registry::onchain_timestamp,
            ))
            .limit(limit)
            .into_boxed();

        if let Some(pool_id) = pool_id_filter {
            query = query.filter(schema::deepbook_pool_updated_registry::pool_id.eq(pool_id));
        }

        let _guard = self.metrics.db_latency.start_timer();
        let res = query
            .load::<(String, String, String, i64, i64, String, String, bool, i64)>(&mut connection)
            .await
            .map_err(|_| {
                DeepBookError::InternalError(
                    "Error fetching deepbook pool updated registry events".to_string(),
                )
            });

        if res.is_ok() {
            self.metrics.db_requests_succeeded.inc();
        } else {
            self.metrics.db_requests_failed.inc();
        }
        res
    }

    pub async fn get_deepbook_pool_config_updated(
        &self,
        start_time: i64,
        end_time: i64,
        limit: i64,
        pool_id_filter: Option<String>,
    ) -> Result<
        Vec<(
            String,
            String,
            String,
            i64,
            i64,
            String,
            String,
            serde_json::Value,
            i64,
        )>,
        DeepBookError,
    > {
        let mut connection = self.db.connect().await?;
        let mut query = schema::deepbook_pool_config_updated::table
            .filter(
                schema::deepbook_pool_config_updated::checkpoint_timestamp_ms
                    .between(start_time, end_time),
            )
            .order_by(schema::deepbook_pool_config_updated::checkpoint_timestamp_ms.desc())
            .select((
                schema::deepbook_pool_config_updated::event_digest,
                schema::deepbook_pool_config_updated::digest,
                schema::deepbook_pool_config_updated::sender,
                schema::deepbook_pool_config_updated::checkpoint,
                schema::deepbook_pool_config_updated::checkpoint_timestamp_ms,
                schema::deepbook_pool_config_updated::package,
                schema::deepbook_pool_config_updated::pool_id,
                schema::deepbook_pool_config_updated::config_json,
                schema::deepbook_pool_config_updated::onchain_timestamp,
            ))
            .limit(limit)
            .into_boxed();

        if let Some(pool_id) = pool_id_filter {
            query = query.filter(schema::deepbook_pool_config_updated::pool_id.eq(pool_id));
        }

        let _guard = self.metrics.db_latency.start_timer();
        let res = query
            .load::<(
                String,
                String,
                String,
                i64,
                i64,
                String,
                String,
                serde_json::Value,
                i64,
            )>(&mut connection)
            .await
            .map_err(|_| {
                DeepBookError::InternalError(
                    "Error fetching deepbook pool config updated events".to_string(),
                )
            });

        if res.is_ok() {
            self.metrics.db_requests_succeeded.inc();
        } else {
            self.metrics.db_requests_failed.inc();
        }
        res
    }

    pub async fn get_margin_managers_info(
        &self,
    ) -> Result<
        Vec<(
            String,         // margin_manager_id
            Option<String>, // deepbook_pool_id
            Option<String>, // base_asset_id
            Option<String>, // base_asset_symbol
            Option<String>, // quote_asset_id
            Option<String>, // quote_asset_symbol
            Option<String>, // base_margin_pool_id
            Option<String>, // quote_margin_pool_id
        )>,
        DeepBookError,
    > {
        let mut connection = self.db.connect().await?;

        let query = diesel::sql_query(
            r#"
            WITH managers_with_pools AS (
                SELECT DISTINCT
                    mmc.margin_manager_id,
                    mmc.deepbook_pool_id,
                    p.base_asset_id,
                    p.base_asset_symbol,
                    p.quote_asset_id,
                    p.quote_asset_symbol,
                    base_mp.margin_pool_id as base_margin_pool_id,
                    quote_mp.margin_pool_id as quote_margin_pool_id
                FROM margin_manager_created mmc
                LEFT JOIN pools p ON mmc.deepbook_pool_id = p.pool_id
                LEFT JOIN margin_pool_created base_mp
                    ON ('0x' || base_mp.asset_type = p.base_asset_id OR base_mp.asset_type = p.base_asset_id)
                LEFT JOIN margin_pool_created quote_mp
                    ON ('0x' || quote_mp.asset_type = p.quote_asset_id OR quote_mp.asset_type = p.quote_asset_id)
            )
            SELECT DISTINCT
                margin_manager_id::text,
                deepbook_pool_id::text,
                base_asset_id::text,
                base_asset_symbol::text,
                quote_asset_id::text,
                quote_asset_symbol::text,
                base_margin_pool_id::text,
                quote_margin_pool_id::text
            FROM managers_with_pools
            ORDER BY margin_manager_id
            "#,
        );

        let _guard = self.metrics.db_latency.start_timer();

        #[derive(QueryableByName)]
        struct ManagerInfo {
            #[diesel(sql_type = diesel::sql_types::Text)]
            margin_manager_id: String,
            #[diesel(sql_type = diesel::sql_types::Nullable<diesel::sql_types::Text>)]
            deepbook_pool_id: Option<String>,
            #[diesel(sql_type = diesel::sql_types::Nullable<diesel::sql_types::Text>)]
            base_asset_id: Option<String>,
            #[diesel(sql_type = diesel::sql_types::Nullable<diesel::sql_types::Text>)]
            base_asset_symbol: Option<String>,
            #[diesel(sql_type = diesel::sql_types::Nullable<diesel::sql_types::Text>)]
            quote_asset_id: Option<String>,
            #[diesel(sql_type = diesel::sql_types::Nullable<diesel::sql_types::Text>)]
            quote_asset_symbol: Option<String>,
            #[diesel(sql_type = diesel::sql_types::Nullable<diesel::sql_types::Text>)]
            base_margin_pool_id: Option<String>,
            #[diesel(sql_type = diesel::sql_types::Nullable<diesel::sql_types::Text>)]
            quote_margin_pool_id: Option<String>,
        }

        let res = query
            .load::<ManagerInfo>(&mut connection)
            .await
            .map(|items| {
                items
                    .into_iter()
                    .map(|item| {
                        (
                            item.margin_manager_id,
                            item.deepbook_pool_id,
                            item.base_asset_id,
                            item.base_asset_symbol,
                            item.quote_asset_id,
                            item.quote_asset_symbol,
                            item.base_margin_pool_id,
                            item.quote_margin_pool_id,
                        )
                    })
                    .collect()
            })
            .map_err(|_| {
                DeepBookError::InternalError("Error fetching margin managers info".to_string())
            });

        if res.is_ok() {
            self.metrics.db_requests_succeeded.inc();
        } else {
            self.metrics.db_requests_failed.inc();
        }
        res
    }

    pub async fn get_margin_manager_states(
        &self,
        max_risk_ratio: Option<f64>,
        deepbook_pool_id_filter: Option<String>,
    ) -> Result<Vec<serde_json::Value>, DeepBookError> {
        use bigdecimal::BigDecimal;
        use deepbook_schema::schema::margin_manager_state::dsl::*;
        use diesel::PgSortExpressionMethods;
        use serde_json::json;
        use std::str::FromStr;

        let mut connection = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();

        let mut query = margin_manager_state.into_boxed();

        if let Some(max_ratio) = max_risk_ratio {
            let max_ratio_decimal = BigDecimal::from_str(&max_ratio.to_string()).unwrap();
            query = query.filter(risk_ratio.is_null().or(risk_ratio.le(max_ratio_decimal)));
        }
        if let Some(pool_id) = deepbook_pool_id_filter {
            query = query.filter(deepbook_pool_id.eq(pool_id));
        }
        query = query.order(risk_ratio.desc().nulls_last());

        #[derive(diesel::Queryable)]
        struct MarginManagerStateRow {
            id: i32,
            margin_manager_id: String,
            deepbook_pool_id: String,
            base_margin_pool_id: Option<String>,
            quote_margin_pool_id: Option<String>,
            base_asset_id: Option<String>,
            base_asset_symbol: Option<String>,
            quote_asset_id: Option<String>,
            quote_asset_symbol: Option<String>,
            risk_ratio: Option<BigDecimal>,
            base_asset: Option<BigDecimal>,
            quote_asset: Option<BigDecimal>,
            base_debt: Option<BigDecimal>,
            quote_debt: Option<BigDecimal>,
            base_pyth_price: Option<i64>,
            base_pyth_decimals: Option<i32>,
            quote_pyth_price: Option<i64>,
            quote_pyth_decimals: Option<i32>,
            created_at: chrono::NaiveDateTime,
            updated_at: chrono::NaiveDateTime,
        }

        let res = query
            .load::<MarginManagerStateRow>(&mut connection)
            .await
            .map(|rows| {
                rows.into_iter()
                    .map(|row| {
                        json!({
                            "id": row.id,
                            "margin_manager_id": row.margin_manager_id,
                            "deepbook_pool_id": row.deepbook_pool_id,
                            "base_margin_pool_id": row.base_margin_pool_id,
                            "quote_margin_pool_id": row.quote_margin_pool_id,
                            "base_asset_id": row.base_asset_id,
                            "base_asset_symbol": row.base_asset_symbol,
                            "quote_asset_id": row.quote_asset_id,
                            "quote_asset_symbol": row.quote_asset_symbol,
                            "risk_ratio": row.risk_ratio.map(|v| v.to_string()),
                            "base_asset": row.base_asset.map(|v| v.to_string()),
                            "quote_asset": row.quote_asset.map(|v| v.to_string()),
                            "base_debt": row.base_debt.map(|v| v.to_string()),
                            "quote_debt": row.quote_debt.map(|v| v.to_string()),
                            "base_pyth_price": row.base_pyth_price,
                            "base_pyth_decimals": row.base_pyth_decimals,
                            "quote_pyth_price": row.quote_pyth_price,
                            "quote_pyth_decimals": row.quote_pyth_decimals,
                            "created_at": row.created_at.to_string(),
                            "updated_at": row.updated_at.to_string(),
                        })
                    })
                    .collect()
            })
            .map_err(|_| {
                DeepBookError::InternalError("Error fetching margin manager states".to_string())
            });

        if res.is_ok() {
            self.metrics.db_requests_succeeded.inc();
        } else {
            self.metrics.db_requests_failed.inc();
        }
        res
    }
}
