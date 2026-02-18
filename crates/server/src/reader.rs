use crate::error::DeepBookError;
use crate::metrics::RpcMetrics;
use deepbook_schema::models::{
    AssetSupplied, AssetWithdrawn, CollateralEvent, DeepbookPoolConfigUpdated,
    DeepbookPoolRegistered, DeepbookPoolUpdated, DeepbookPoolUpdatedRegistry,
    InterestParamsUpdated, Liquidation, LoanBorrowed, LoanRepaid, MaintainerCapUpdated,
    MaintainerFeesWithdrawn, MarginManagerCreated, MarginManagerState, MarginPoolConfigUpdated,
    MarginPoolCreated, OrderFillSummary, OrderStatus, PauseCapUpdated, Pools,
    ProtocolFeesIncreasedEvent, ProtocolFeesWithdrawn, ReferralFeeEvent, ReferralFeesClaimedEvent,
    SupplierCapMinted, SupplyReferralMinted,
};
use deepbook_schema::schema;
use diesel::deserialize::FromSqlRow;
use diesel::dsl::sql;
use diesel::expression::QueryMetadata;
use diesel::pg::Pg;
use diesel::query_builder::{Query, QueryFragment, QueryId};
use diesel::query_dsl::CompatibleType;
use diesel::sql_types::{Array, BigInt, Double, Integer, Nullable, Text};
use diesel::{
    BoolExpressionMethods, ExpressionMethods, QueryDsl, QueryableByName, SelectableHelper,
    TextExpressionMethods,
};

/// Converts an empty string to "%" for SQL LIKE pattern matching.
/// This allows using required parameters instead of Option<String>,
/// avoiding the need for boxed queries with dynamic filters.
fn to_pattern(s: &str) -> String {
    if s.is_empty() {
        "%".to_string()
    } else {
        s.to_string()
    }
}

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
            .map_err(|_| DeepBookError::not_found(format!("Pool '{}'", pool_name)))
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
        balance_manager: Option<String>,
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
        if let Some(bm_id) = balance_manager {
            query = query.filter(
                schema::order_fills::maker_balance_manager_id
                    .eq(bm_id.clone())
                    .or(schema::order_fills::taker_balance_manager_id.eq(bm_id)),
            );
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
                schema::order_fills::maker_client_order_id,
                schema::order_fills::taker_client_order_id,
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
                DeepBookError::not_found(format!(
                    "Trades for pool '{}' in the specified time range",
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
            .map_err(|_| DeepBookError::database("Error fetching trade details"));

        if res.is_ok() {
            self.metrics.db_requests_succeeded.inc();
        } else {
            self.metrics.db_requests_failed.inc();
        }
        res
    }

    pub async fn get_orders_status(
        &self,
        pool_id: String,
        limit: i64,
        balance_manager_filter: Option<String>,
        status_filter: Option<Vec<String>>,
    ) -> Result<Vec<OrderStatus>, DeepBookError> {
        let mut connection = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();

        let res = diesel::sql_query(
            r#"
            WITH latest_events AS (
                SELECT DISTINCT ON (order_id)
                    order_id,
                    balance_manager_id,
                    is_bid,
                    status as event_status,
                    price,
                    original_quantity,
                    filled_quantity,
                    quantity as remaining_quantity,
                    checkpoint_timestamp_ms as last_updated_at
                FROM order_updates
                WHERE pool_id = $1
                AND ($2 IS NULL OR balance_manager_id = $2)
                ORDER BY order_id, checkpoint_timestamp_ms DESC
            ),
            placed_events AS (
                SELECT DISTINCT ON (order_id)
                    order_id,
                    checkpoint_timestamp_ms as placed_at
                FROM order_updates
                WHERE pool_id = $1
                    AND status = 'Placed'
                ORDER BY order_id, checkpoint_timestamp_ms ASC
            ),
            order_status AS (
                SELECT
                    le.order_id,
                    le.balance_manager_id,
                    le.is_bid,
                    CASE
                        WHEN le.event_status = 'Canceled' THEN 'canceled'
                        WHEN le.event_status = 'Expired' THEN 'expired'
                        WHEN le.filled_quantity >= le.original_quantity THEN 'filled'
                        WHEN le.filled_quantity > 0 THEN 'partially_filled'
                        ELSE 'placed'
                    END as current_status,
                    le.price,
                    COALESCE(pe.placed_at, le.last_updated_at) as placed_at,
                    le.last_updated_at,
                    le.original_quantity,
                    le.filled_quantity,
                    le.remaining_quantity
                FROM latest_events le
                LEFT JOIN placed_events pe ON le.order_id = pe.order_id
            )
            SELECT
                order_id::text,
                balance_manager_id::text,
                is_bid,
                current_status::text,
                price,
                placed_at,
                last_updated_at,
                original_quantity,
                filled_quantity,
                remaining_quantity
            FROM order_status
            WHERE ($3 IS NULL OR current_status = ANY($3))
            ORDER BY last_updated_at DESC
            LIMIT $4
            "#,
        )
        .bind::<Text, _>(&pool_id)
        .bind::<Nullable<Text>, _>(&balance_manager_filter)
        .bind::<Nullable<Array<Text>>, _>(&status_filter)
        .bind::<BigInt, _>(limit)
        .load::<OrderStatus>(&mut connection)
        .await
        .map_err(|e| DeepBookError::database(format!("Error fetching order status: {}", e)));

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

        // Convert milliseconds to seconds for to_timestamp()
        let start_secs = start_time.map(|ts| ts / 1000);
        let end_secs = end_time.map(|ts| ts / 1000);

        let res = diesel::sql_query(
            "SELECT EXTRACT(EPOCH FROM bucket_time)::bigint * 1000 as timestamp_ms, \
             open::float8, high::float8, low::float8, close::float8, base_volume::float8 \
             FROM get_ohclv($1, $2, \
                CASE WHEN $3 IS NULL THEN NULL ELSE to_timestamp($3)::timestamp END, \
                CASE WHEN $4 IS NULL THEN NULL ELSE to_timestamp($4)::timestamp END, \
                $5)",
        )
        .bind::<Text, _>(&interval)
        .bind::<Text, _>(&pool_id)
        .bind::<Nullable<BigInt>, _>(&start_secs)
        .bind::<Nullable<BigInt>, _>(&end_secs)
        .bind::<Integer, _>(limit_val)
        .load::<OhclvRow>(&mut connection)
        .await
        .map_err(|e| DeepBookError::database(format!("Error fetching OHCLV data: {}", e)))
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
        margin_manager_id_filter: String,
    ) -> Result<Vec<MarginManagerCreated>, DeepBookError> {
        let query = schema::margin_manager_created::table
            .select(MarginManagerCreated::as_select())
            .filter(
                schema::margin_manager_created::checkpoint_timestamp_ms
                    .between(start_time, end_time),
            )
            .filter(
                schema::margin_manager_created::margin_manager_id
                    .like(to_pattern(&margin_manager_id_filter)),
            )
            .order_by(schema::margin_manager_created::checkpoint_timestamp_ms.desc())
            .limit(limit);

        Ok(self.results(query).await?)
    }

    pub async fn get_loan_borrowed(
        &self,
        start_time: i64,
        end_time: i64,
        limit: i64,
        margin_manager_id_filter: String,
        margin_pool_id_filter: String,
    ) -> Result<Vec<LoanBorrowed>, DeepBookError> {
        let query = schema::loan_borrowed::table
            .select(LoanBorrowed::as_select())
            .filter(schema::loan_borrowed::checkpoint_timestamp_ms.between(start_time, end_time))
            .filter(
                schema::loan_borrowed::margin_manager_id
                    .like(to_pattern(&margin_manager_id_filter)),
            )
            .filter(schema::loan_borrowed::margin_pool_id.like(to_pattern(&margin_pool_id_filter)))
            .order_by(schema::loan_borrowed::checkpoint_timestamp_ms.desc())
            .limit(limit);

        Ok(self.results(query).await?)
    }

    pub async fn get_loan_repaid(
        &self,
        start_time: i64,
        end_time: i64,
        limit: i64,
        margin_manager_id_filter: String,
        margin_pool_id_filter: String,
    ) -> Result<Vec<LoanRepaid>, DeepBookError> {
        let query = schema::loan_repaid::table
            .select(LoanRepaid::as_select())
            .filter(schema::loan_repaid::checkpoint_timestamp_ms.between(start_time, end_time))
            .filter(
                schema::loan_repaid::margin_manager_id.like(to_pattern(&margin_manager_id_filter)),
            )
            .filter(schema::loan_repaid::margin_pool_id.like(to_pattern(&margin_pool_id_filter)))
            .order_by(schema::loan_repaid::checkpoint_timestamp_ms.desc())
            .limit(limit);

        Ok(self.results(query).await?)
    }

    pub async fn get_liquidation(
        &self,
        start_time: i64,
        end_time: i64,
        limit: i64,
        margin_manager_id_filter: String,
        margin_pool_id_filter: String,
    ) -> Result<Vec<Liquidation>, DeepBookError> {
        let query = schema::liquidation::table
            .select(Liquidation::as_select())
            .filter(schema::liquidation::checkpoint_timestamp_ms.between(start_time, end_time))
            .filter(
                schema::liquidation::margin_manager_id.like(to_pattern(&margin_manager_id_filter)),
            )
            .filter(schema::liquidation::margin_pool_id.like(to_pattern(&margin_pool_id_filter)))
            .order_by(schema::liquidation::checkpoint_timestamp_ms.desc())
            .limit(limit);

        Ok(self.results(query).await?)
    }

    pub async fn get_asset_supplied(
        &self,
        start_time: i64,
        end_time: i64,
        limit: i64,
        margin_pool_id_filter: String,
        supplier_filter: String,
    ) -> Result<Vec<AssetSupplied>, DeepBookError> {
        let query = schema::asset_supplied::table
            .select(AssetSupplied::as_select())
            .filter(schema::asset_supplied::checkpoint_timestamp_ms.between(start_time, end_time))
            .filter(schema::asset_supplied::margin_pool_id.like(to_pattern(&margin_pool_id_filter)))
            .filter(schema::asset_supplied::supplier.like(to_pattern(&supplier_filter)))
            .order_by(schema::asset_supplied::checkpoint_timestamp_ms.desc())
            .limit(limit);

        Ok(self.results(query).await?)
    }

    pub async fn get_asset_withdrawn(
        &self,
        start_time: i64,
        end_time: i64,
        limit: i64,
        margin_pool_id_filter: String,
        supplier_filter: String,
    ) -> Result<Vec<AssetWithdrawn>, DeepBookError> {
        let query = schema::asset_withdrawn::table
            .select(AssetWithdrawn::as_select())
            .filter(schema::asset_withdrawn::checkpoint_timestamp_ms.between(start_time, end_time))
            .filter(
                schema::asset_withdrawn::margin_pool_id.like(to_pattern(&margin_pool_id_filter)),
            )
            .filter(schema::asset_withdrawn::supplier.like(to_pattern(&supplier_filter)))
            .order_by(schema::asset_withdrawn::checkpoint_timestamp_ms.desc())
            .limit(limit);

        Ok(self.results(query).await?)
    }

    pub async fn get_margin_pool_created(
        &self,
        margin_pool_id_filter: String,
    ) -> Result<Vec<MarginPoolCreated>, DeepBookError> {
        let query = schema::margin_pool_created::table
            .select(MarginPoolCreated::as_select())
            .filter(
                schema::margin_pool_created::margin_pool_id
                    .like(to_pattern(&margin_pool_id_filter)),
            )
            .order_by(schema::margin_pool_created::checkpoint_timestamp_ms.desc());

        Ok(self.results(query).await?)
    }

    pub async fn get_deepbook_pool_updated(
        &self,
        start_time: i64,
        end_time: i64,
        limit: i64,
        margin_pool_id_filter: String,
        deepbook_pool_id_filter: String,
    ) -> Result<Vec<DeepbookPoolUpdated>, DeepBookError> {
        let query = schema::deepbook_pool_updated::table
            .select(DeepbookPoolUpdated::as_select())
            .filter(
                schema::deepbook_pool_updated::checkpoint_timestamp_ms
                    .between(start_time, end_time),
            )
            .filter(
                schema::deepbook_pool_updated::margin_pool_id
                    .like(to_pattern(&margin_pool_id_filter)),
            )
            .filter(
                schema::deepbook_pool_updated::deepbook_pool_id
                    .like(to_pattern(&deepbook_pool_id_filter)),
            )
            .order_by(schema::deepbook_pool_updated::checkpoint_timestamp_ms.desc())
            .limit(limit);

        Ok(self.results(query).await?)
    }

    pub async fn get_interest_params_updated(
        &self,
        start_time: i64,
        end_time: i64,
        limit: i64,
        margin_pool_id_filter: String,
    ) -> Result<Vec<InterestParamsUpdated>, DeepBookError> {
        let query = schema::interest_params_updated::table
            .select(InterestParamsUpdated::as_select())
            .filter(
                schema::interest_params_updated::checkpoint_timestamp_ms
                    .between(start_time, end_time),
            )
            .filter(
                schema::interest_params_updated::margin_pool_id
                    .like(to_pattern(&margin_pool_id_filter)),
            )
            .order_by(schema::interest_params_updated::checkpoint_timestamp_ms.desc())
            .limit(limit);

        Ok(self.results(query).await?)
    }

    pub async fn get_margin_pool_config_updated(
        &self,
        start_time: i64,
        end_time: i64,
        limit: i64,
        margin_pool_id_filter: String,
    ) -> Result<Vec<MarginPoolConfigUpdated>, DeepBookError> {
        let query = schema::margin_pool_config_updated::table
            .select(MarginPoolConfigUpdated::as_select())
            .filter(
                schema::margin_pool_config_updated::checkpoint_timestamp_ms
                    .between(start_time, end_time),
            )
            .filter(
                schema::margin_pool_config_updated::margin_pool_id
                    .like(to_pattern(&margin_pool_id_filter)),
            )
            .order_by(schema::margin_pool_config_updated::checkpoint_timestamp_ms.desc())
            .limit(limit);

        Ok(self.results(query).await?)
    }

    pub async fn get_maintainer_cap_updated(
        &self,
        start_time: i64,
        end_time: i64,
        limit: i64,
        maintainer_cap_id_filter: String,
    ) -> Result<Vec<MaintainerCapUpdated>, DeepBookError> {
        let query = schema::maintainer_cap_updated::table
            .select(MaintainerCapUpdated::as_select())
            .filter(
                schema::maintainer_cap_updated::checkpoint_timestamp_ms
                    .between(start_time, end_time),
            )
            .filter(
                schema::maintainer_cap_updated::maintainer_cap_id
                    .like(to_pattern(&maintainer_cap_id_filter)),
            )
            .order_by(schema::maintainer_cap_updated::checkpoint_timestamp_ms.desc())
            .limit(limit);

        Ok(self.results(query).await?)
    }

    pub async fn get_maintainer_fees_withdrawn(
        &self,
        start_time: i64,
        end_time: i64,
        limit: i64,
        margin_pool_id_filter: String,
    ) -> Result<Vec<MaintainerFeesWithdrawn>, DeepBookError> {
        let query = schema::maintainer_fees_withdrawn::table
            .select(MaintainerFeesWithdrawn::as_select())
            .filter(
                schema::maintainer_fees_withdrawn::checkpoint_timestamp_ms
                    .between(start_time, end_time),
            )
            .filter(
                schema::maintainer_fees_withdrawn::margin_pool_id
                    .like(to_pattern(&margin_pool_id_filter)),
            )
            .order_by(schema::maintainer_fees_withdrawn::checkpoint_timestamp_ms.desc())
            .limit(limit);

        Ok(self.results(query).await?)
    }

    pub async fn get_protocol_fees_withdrawn(
        &self,
        start_time: i64,
        end_time: i64,
        limit: i64,
        margin_pool_id_filter: String,
    ) -> Result<Vec<ProtocolFeesWithdrawn>, DeepBookError> {
        let query = schema::protocol_fees_withdrawn::table
            .select(ProtocolFeesWithdrawn::as_select())
            .filter(
                schema::protocol_fees_withdrawn::checkpoint_timestamp_ms
                    .between(start_time, end_time),
            )
            .filter(
                schema::protocol_fees_withdrawn::margin_pool_id
                    .like(to_pattern(&margin_pool_id_filter)),
            )
            .order_by(schema::protocol_fees_withdrawn::checkpoint_timestamp_ms.desc())
            .limit(limit);

        Ok(self.results(query).await?)
    }

    pub async fn get_supplier_cap_minted(
        &self,
        start_time: i64,
        end_time: i64,
        limit: i64,
        supplier_cap_id_filter: String,
    ) -> Result<Vec<SupplierCapMinted>, DeepBookError> {
        let query = schema::supplier_cap_minted::table
            .select(SupplierCapMinted::as_select())
            .filter(
                schema::supplier_cap_minted::checkpoint_timestamp_ms.between(start_time, end_time),
            )
            .filter(
                schema::supplier_cap_minted::supplier_cap_id
                    .like(to_pattern(&supplier_cap_id_filter)),
            )
            .order_by(schema::supplier_cap_minted::checkpoint_timestamp_ms.desc())
            .limit(limit);

        Ok(self.results(query).await?)
    }

    pub async fn get_supply_referral_minted(
        &self,
        start_time: i64,
        end_time: i64,
        limit: i64,
        margin_pool_id_filter: String,
        owner_filter: String,
    ) -> Result<Vec<SupplyReferralMinted>, DeepBookError> {
        let query = schema::supply_referral_minted::table
            .select(SupplyReferralMinted::as_select())
            .filter(
                schema::supply_referral_minted::checkpoint_timestamp_ms
                    .between(start_time, end_time),
            )
            .filter(
                schema::supply_referral_minted::margin_pool_id
                    .like(to_pattern(&margin_pool_id_filter)),
            )
            .filter(schema::supply_referral_minted::owner.like(to_pattern(&owner_filter)))
            .order_by(schema::supply_referral_minted::checkpoint_timestamp_ms.desc())
            .limit(limit);

        Ok(self.results(query).await?)
    }

    pub async fn get_pause_cap_updated(
        &self,
        start_time: i64,
        end_time: i64,
        limit: i64,
        pause_cap_id_filter: String,
    ) -> Result<Vec<PauseCapUpdated>, DeepBookError> {
        let query = schema::pause_cap_updated::table
            .select(PauseCapUpdated::as_select())
            .filter(
                schema::pause_cap_updated::checkpoint_timestamp_ms.between(start_time, end_time),
            )
            .filter(schema::pause_cap_updated::pause_cap_id.like(to_pattern(&pause_cap_id_filter)))
            .order_by(schema::pause_cap_updated::checkpoint_timestamp_ms.desc())
            .limit(limit);

        Ok(self.results(query).await?)
    }

    pub async fn get_protocol_fees_increased(
        &self,
        start_time: i64,
        end_time: i64,
        limit: i64,
        margin_pool_id_filter: String,
    ) -> Result<Vec<ProtocolFeesIncreasedEvent>, DeepBookError> {
        let query = schema::protocol_fees_increased::table
            .select(ProtocolFeesIncreasedEvent::as_select())
            .filter(
                schema::protocol_fees_increased::checkpoint_timestamp_ms
                    .between(start_time, end_time),
            )
            .filter(
                schema::protocol_fees_increased::margin_pool_id
                    .like(to_pattern(&margin_pool_id_filter)),
            )
            .order_by(schema::protocol_fees_increased::checkpoint_timestamp_ms.desc())
            .limit(limit);

        Ok(self.results(query).await?)
    }

    pub async fn get_referral_fees_claimed(
        &self,
        start_time: i64,
        end_time: i64,
        limit: i64,
        referral_id_filter: String,
        owner_filter: String,
    ) -> Result<Vec<ReferralFeesClaimedEvent>, DeepBookError> {
        let query = schema::referral_fees_claimed::table
            .select(ReferralFeesClaimedEvent::as_select())
            .filter(
                schema::referral_fees_claimed::checkpoint_timestamp_ms
                    .between(start_time, end_time),
            )
            .filter(
                schema::referral_fees_claimed::referral_id.like(to_pattern(&referral_id_filter)),
            )
            .filter(schema::referral_fees_claimed::owner.like(to_pattern(&owner_filter)))
            .order_by(schema::referral_fees_claimed::checkpoint_timestamp_ms.desc())
            .limit(limit);

        Ok(self.results(query).await?)
    }

    pub async fn get_referral_fee_events(
        &self,
        start_time: i64,
        end_time: i64,
        limit: i64,
        pool_id_filter: String,
        referral_id_filter: String,
    ) -> Result<Vec<ReferralFeeEvent>, DeepBookError> {
        let query = schema::referral_fee_events::table
            .select(ReferralFeeEvent::as_select())
            .filter(
                schema::referral_fee_events::checkpoint_timestamp_ms.between(start_time, end_time),
            )
            .filter(schema::referral_fee_events::pool_id.like(to_pattern(&pool_id_filter)))
            .filter(schema::referral_fee_events::referral_id.like(to_pattern(&referral_id_filter)))
            .order_by(schema::referral_fee_events::checkpoint_timestamp_ms.desc())
            .limit(limit);

        Ok(self.results(query).await?)
    }

    pub async fn get_deepbook_pool_registered(
        &self,
        start_time: i64,
        end_time: i64,
        limit: i64,
        pool_id_filter: String,
    ) -> Result<Vec<DeepbookPoolRegistered>, DeepBookError> {
        let query = schema::deepbook_pool_registered::table
            .select(DeepbookPoolRegistered::as_select())
            .filter(
                schema::deepbook_pool_registered::checkpoint_timestamp_ms
                    .between(start_time, end_time),
            )
            .filter(schema::deepbook_pool_registered::pool_id.like(to_pattern(&pool_id_filter)))
            .order_by(schema::deepbook_pool_registered::checkpoint_timestamp_ms.desc())
            .limit(limit);

        Ok(self.results(query).await?)
    }

    pub async fn get_deepbook_pool_updated_registry(
        &self,
        start_time: i64,
        end_time: i64,
        limit: i64,
        pool_id_filter: String,
    ) -> Result<Vec<DeepbookPoolUpdatedRegistry>, DeepBookError> {
        let query = schema::deepbook_pool_updated_registry::table
            .select(DeepbookPoolUpdatedRegistry::as_select())
            .filter(
                schema::deepbook_pool_updated_registry::checkpoint_timestamp_ms
                    .between(start_time, end_time),
            )
            .filter(
                schema::deepbook_pool_updated_registry::pool_id.like(to_pattern(&pool_id_filter)),
            )
            .order_by(schema::deepbook_pool_updated_registry::checkpoint_timestamp_ms.desc())
            .limit(limit);

        Ok(self.results(query).await?)
    }

    pub async fn get_deepbook_pool_config_updated(
        &self,
        start_time: i64,
        end_time: i64,
        limit: i64,
        pool_id_filter: String,
    ) -> Result<Vec<DeepbookPoolConfigUpdated>, DeepBookError> {
        let query = schema::deepbook_pool_config_updated::table
            .select(DeepbookPoolConfigUpdated::as_select())
            .filter(
                schema::deepbook_pool_config_updated::checkpoint_timestamp_ms
                    .between(start_time, end_time),
            )
            .filter(schema::deepbook_pool_config_updated::pool_id.like(to_pattern(&pool_id_filter)))
            .order_by(schema::deepbook_pool_config_updated::checkpoint_timestamp_ms.desc())
            .limit(limit);

        Ok(self.results(query).await?)
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
            .map_err(|_| DeepBookError::database("Error fetching margin managers info"));

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
        base_asset_symbol_filter: Option<String>,
        quote_asset_symbol_filter: Option<String>,
    ) -> Result<Vec<MarginManagerState>, DeepBookError> {
        use bigdecimal::BigDecimal;
        use deepbook_schema::schema::margin_manager_state::dsl::*;
        use diesel::PgSortExpressionMethods;
        use std::str::FromStr;

        let mut connection = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();

        let mut query = margin_manager_state
            .select(MarginManagerState::as_select())
            .into_boxed();

        if let Some(max_ratio) = max_risk_ratio {
            let max_ratio_decimal = BigDecimal::from_str(&max_ratio.to_string()).unwrap();
            query = query.filter(risk_ratio.is_null().or(risk_ratio.le(max_ratio_decimal)));
        }
        if let Some(pool_id) = deepbook_pool_id_filter {
            query = query.filter(deepbook_pool_id.eq(pool_id));
        }
        if let Some(base_symbol) = base_asset_symbol_filter {
            query = query.filter(base_asset_symbol.eq(base_symbol));
        }
        if let Some(quote_symbol) = quote_asset_symbol_filter {
            query = query.filter(quote_asset_symbol.eq(quote_symbol));
        }
        query = query.order(risk_ratio.asc().nulls_last());

        let res = query.load::<MarginManagerState>(&mut connection).await;

        if res.is_ok() {
            self.metrics.db_requests_succeeded.inc();
        } else {
            self.metrics.db_requests_failed.inc();
        }

        res.map_err(|_| DeepBookError::database("Error fetching margin manager states"))
    }

    pub async fn get_watermarks(&self) -> Result<Vec<(String, i64, i64, i64)>, DeepBookError> {
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
            .map_err(|_| DeepBookError::database("Error fetching watermarks"));

        if res.is_ok() {
            self.metrics.db_requests_succeeded.inc();
        } else {
            self.metrics.db_requests_failed.inc();
        }
        res
    }

    pub async fn get_deposited_assets_by_balance_managers(
        &self,
        balance_manager_ids: &[String],
    ) -> Result<Vec<(String, String)>, DeepBookError> {
        let mut connection = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();

        let res = schema::balances::table
            .select((
                schema::balances::balance_manager_id,
                schema::balances::asset,
            ))
            .filter(schema::balances::balance_manager_id.eq_any(balance_manager_ids))
            .filter(schema::balances::deposit.eq(true))
            .distinct()
            .load::<(String, String)>(&mut connection)
            .await
            .map_err(|_| DeepBookError::database("Error fetching deposited assets"));

        if res.is_ok() {
            self.metrics.db_requests_succeeded.inc();
        } else {
            self.metrics.db_requests_failed.inc();
        }
        res
    }

    /// Query net deposits using the materialized view for efficiency.
    /// Triggers a concurrent refresh of the view and queries for net deposits up to timestamp.
    pub async fn get_net_deposits_from_view(
        &self,
        asset_ids: &[String],
        timestamp_ms: i64,
    ) -> Result<std::collections::HashMap<String, i64>, DeepBookError> {
        let mut connection = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();

        // Trigger concurrent refresh (non-blocking, won't fail if already refreshing)
        let _ = diesel::sql_query("REFRESH MATERIALIZED VIEW CONCURRENTLY net_deposits_hourly")
            .execute(&mut connection)
            .await;

        // Calculate the hour boundary for the timestamp
        let hour_bucket_ms = (timestamp_ms / 3600000) * 3600000;

        // Strip 0x prefix from asset_ids for database comparison
        let cleaned_assets: Vec<String> = asset_ids
            .iter()
            .map(|a| a.strip_prefix("0x").unwrap_or(a).to_string())
            .collect();

        #[derive(QueryableByName)]
        struct NetDepositRow {
            #[diesel(sql_type = diesel::sql_types::Text)]
            asset: String,
            #[diesel(sql_type = diesel::sql_types::BigInt)]
            net_amount: i64,
        }

        // Query: sum all hourly deltas up to the hour boundary, then add partial hour from balances
        let res = diesel::sql_query(
            r#"
            WITH hourly_totals AS (
                SELECT asset, SUM(net_amount_delta) AS net_amount
                FROM net_deposits_hourly
                WHERE hour_bucket_ms < $1
                  AND asset = ANY($2)
                GROUP BY asset
            ),
            partial_hour AS (
                SELECT asset, SUM(CASE WHEN deposit THEN amount ELSE -amount END) AS net_amount
                FROM balances
                WHERE checkpoint_timestamp_ms >= $1
                  AND checkpoint_timestamp_ms < $3
                  AND asset = ANY($2)
                GROUP BY asset
            )
            SELECT
                COALESCE(h.asset, p.asset) AS asset,
                (COALESCE(h.net_amount, 0) + COALESCE(p.net_amount, 0))::bigint AS net_amount
            FROM hourly_totals h
            FULL OUTER JOIN partial_hour p ON h.asset = p.asset
            "#,
        )
        .bind::<BigInt, _>(hour_bucket_ms)
        .bind::<Array<Text>, _>(&cleaned_assets)
        .bind::<BigInt, _>(timestamp_ms)
        .load::<NetDepositRow>(&mut connection)
        .await;

        if res.is_ok() {
            self.metrics.db_requests_succeeded.inc();
        } else {
            self.metrics.db_requests_failed.inc();
        }

        res.map(|rows| {
            rows.into_iter()
                .map(|row| {
                    let mut asset = row.asset;
                    if !asset.starts_with("0x") {
                        asset.insert_str(0, "0x");
                    }
                    (asset, row.net_amount)
                })
                .collect()
        })
        .map_err(|e| DeepBookError::database(format!("Error fetching net deposits: {}", e)))
    }

    pub async fn get_collateral_events(
        &self,
        start_time: i64,
        end_time: i64,
        limit: i64,
        margin_manager_id_filter: String,
        event_type_filter: String,
        is_base_filter: Option<bool>,
    ) -> Result<Vec<CollateralEvent>, DeepBookError> {
        let mut connection = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();

        let mut query = schema::collateral_events::table
            .select(CollateralEvent::as_select())
            .filter(
                schema::collateral_events::checkpoint_timestamp_ms.between(start_time, end_time),
            )
            .filter(
                schema::collateral_events::margin_manager_id
                    .like(to_pattern(&margin_manager_id_filter)),
            )
            .filter(schema::collateral_events::event_type.like(to_pattern(&event_type_filter)))
            .order_by(schema::collateral_events::checkpoint_timestamp_ms.desc())
            .limit(limit)
            .into_boxed();

        if let Some(is_base) = is_base_filter {
            query = query.filter(schema::collateral_events::withdraw_base_asset.eq(Some(is_base)));
        }

        let res = query.load::<CollateralEvent>(&mut connection).await;

        if res.is_ok() {
            self.metrics.db_requests_succeeded.inc();
        } else {
            self.metrics.db_requests_failed.inc();
        }

        res.map_err(|_| DeepBookError::database("Error fetching collateral events"))
    }

    pub async fn get_points(
        &self,
        addresses: Option<&[String]>,
    ) -> Result<Vec<(String, i64)>, DeepBookError> {
        let mut connection = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();

        // Convert to owned Vec for binding, None if empty or not provided
        let addr_filter: Option<Vec<String>> =
            addresses.filter(|a| !a.is_empty()).map(|a| a.to_vec());

        #[derive(QueryableByName)]
        struct PointsRow {
            #[diesel(sql_type = diesel::sql_types::Text)]
            address: String,
            #[diesel(sql_type = diesel::sql_types::BigInt)]
            total_points: i64,
        }

        let res = diesel::sql_query(
            "SELECT address, COALESCE(SUM(amount), 0)::bigint as total_points \
             FROM points \
             WHERE ($1 IS NULL OR address = ANY($1)) \
             GROUP BY address",
        )
        .bind::<Nullable<Array<Text>>, _>(&addr_filter)
        .load::<PointsRow>(&mut connection)
        .await;

        if res.is_ok() {
            self.metrics.db_requests_succeeded.inc();
        } else {
            self.metrics.db_requests_failed.inc();
        }

        res.map(|rows| {
            rows.into_iter()
                .map(|r| (r.address, r.total_points))
                .collect()
        })
        .map_err(|e| DeepBookError::database(format!("Error fetching points: {}", e)))
    }

    /// Get a comprehensive margin portfolio for a wallet address.
    /// Returns margin positions, collateral balances, and LP positions with USD valuations.
    /// Prices are sourced from hourly ohclv_1m candles (falling back to daily ohclv_1d).
    ///
    /// NOTE: LP positions use flow-based approximation (cumulative supply - withdraw).
    /// This does not account for interest accrual on lending positions (~3-4% undercount).
    /// Shares are exact; only the share-to-amount conversion is approximate.
    /// This will be resolved once margin_pool_snapshots is populated in production.
    pub async fn get_portfolio(
        &self,
        wallet_address: &str,
    ) -> Result<PortfolioQueryResult, DeepBookError> {
        // Validate: must be 0x-prefixed 64-character hex string
        if !wallet_address.starts_with("0x") || wallet_address.len() != 66 {
            return Err(DeepBookError::bad_request(
                "Invalid wallet address: expected 0x-prefixed 64-character hex string",
            ));
        }

        let mut connection = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();

        // --- Row types ---
        #[derive(QueryableByName, Debug)]
        struct MarginPositionRow {
            #[diesel(sql_type = diesel::sql_types::Text)]
            margin_manager_id: String,
            #[diesel(sql_type = diesel::sql_types::Text)]
            pool_name: String,
            #[diesel(sql_type = diesel::sql_types::Text)]
            base_asset_symbol: String,
            #[diesel(sql_type = diesel::sql_types::Text)]
            quote_asset_symbol: String,
            #[diesel(sql_type = diesel::sql_types::Double)]
            base_asset: f64,
            #[diesel(sql_type = diesel::sql_types::Double)]
            quote_asset: f64,
            #[diesel(sql_type = diesel::sql_types::Double)]
            base_debt: f64,
            #[diesel(sql_type = diesel::sql_types::Double)]
            quote_debt: f64,
            #[diesel(sql_type = diesel::sql_types::Double)]
            base_asset_usd: f64,
            #[diesel(sql_type = diesel::sql_types::Double)]
            quote_asset_usd: f64,
            #[diesel(sql_type = diesel::sql_types::Double)]
            base_debt_usd: f64,
            #[diesel(sql_type = diesel::sql_types::Double)]
            quote_debt_usd: f64,
            #[diesel(sql_type = diesel::sql_types::Double)]
            risk_ratio: f64,
        }

        #[derive(QueryableByName, Debug)]
        struct CollateralRow {
            #[diesel(sql_type = diesel::sql_types::Text)]
            asset: String,
            #[diesel(sql_type = diesel::sql_types::Double)]
            balance: f64,
            #[diesel(sql_type = diesel::sql_types::Double)]
            balance_usd: f64,
        }

        #[derive(QueryableByName, Debug)]
        struct LpPositionRow {
            #[diesel(sql_type = diesel::sql_types::Text)]
            margin_pool_id: String,
            #[diesel(sql_type = diesel::sql_types::Text)]
            asset: String,
            #[diesel(sql_type = diesel::sql_types::Double)]
            net_supplied: f64,
            #[diesel(sql_type = diesel::sql_types::BigInt)]
            net_shares: i64,
            #[diesel(sql_type = diesel::sql_types::Double)]
            supplied_usd: f64,
        }

        // --- Margin positions ---
        let margin_res = diesel::sql_query(
            r#"
            WITH hourly_prices AS (
                SELECT DISTINCT ON (p.base_asset_symbol)
                    p.base_asset_symbol as symbol,
                    o.close as price_usd
                FROM pools p
                JOIN ohclv_1m o ON p.pool_id = o.pool_id
                WHERE p.quote_asset_symbol = 'USDC'
                  AND o.bucket_time >= NOW() - INTERVAL '2 hours'
                ORDER BY p.base_asset_symbol, o.bucket_time DESC
            ),
            daily_prices AS (
                SELECT DISTINCT ON (p.base_asset_symbol)
                    p.base_asset_symbol as symbol,
                    o.close as price_usd
                FROM pools p
                JOIN ohclv_1d o ON p.pool_id = o.pool_id
                WHERE p.quote_asset_symbol = 'USDC'
                ORDER BY p.base_asset_symbol, o.bucket_time DESC
            ),
            latest_prices AS (
                SELECT
                    COALESCE(h.symbol, d.symbol) as symbol,
                    COALESCE(h.price_usd, d.price_usd) as price_usd
                FROM daily_prices d
                LEFT JOIN hourly_prices h ON d.symbol = h.symbol
            )
            SELECT
                c.margin_manager_id::text,
                p.pool_name::text,
                s.base_asset_symbol::text,
                s.quote_asset_symbol::text,
                ROUND(s.base_asset::numeric, 6)::float8 as base_asset,
                ROUND(s.quote_asset::numeric, 6)::float8 as quote_asset,
                ROUND(s.base_debt::numeric, 6)::float8 as base_debt,
                ROUND(s.quote_debt::numeric, 6)::float8 as quote_debt,
                ROUND((s.base_asset * COALESCE(bp.price_usd, 0))::numeric, 2)::float8 as base_asset_usd,
                ROUND((s.quote_asset::numeric * CASE WHEN UPPER(s.quote_asset_symbol) IN ('USDC','USDT','AUSD') THEN 1 ELSE COALESCE(qp.price_usd, 0) END)::numeric, 2)::float8 as quote_asset_usd,
                ROUND((s.base_debt * COALESCE(bp.price_usd, 0))::numeric, 2)::float8 as base_debt_usd,
                ROUND((s.quote_debt::numeric * CASE WHEN UPPER(s.quote_asset_symbol) IN ('USDC','USDT','AUSD') THEN 1 ELSE COALESCE(qp.price_usd, 0) END)::numeric, 2)::float8 as quote_debt_usd,
                ROUND(s.risk_ratio::numeric, 4)::float8 as risk_ratio
            FROM margin_manager_created c
            JOIN margin_manager_state s ON c.margin_manager_id = s.margin_manager_id
            JOIN pools p ON s.deepbook_pool_id = p.pool_id
            LEFT JOIN latest_prices bp ON s.base_asset_symbol = bp.symbol
            LEFT JOIN latest_prices qp ON s.quote_asset_symbol = qp.symbol
            WHERE c.owner = $1
              AND (s.base_asset <> 0 OR s.quote_asset <> 0 OR s.base_debt <> 0 OR s.quote_debt <> 0)
            "#,
        )
        .bind::<Text, _>(wallet_address)
        .load::<MarginPositionRow>(&mut connection)
        .await;

        // --- Collateral balances ---
        let collateral_res = diesel::sql_query(
            r#"
            WITH hourly_prices AS (
                SELECT DISTINCT ON (p.base_asset_symbol)
                    p.base_asset_symbol as symbol,
                    o.close as price_usd
                FROM pools p
                JOIN ohclv_1m o ON p.pool_id = o.pool_id
                WHERE p.quote_asset_symbol = 'USDC'
                  AND o.bucket_time >= NOW() - INTERVAL '2 hours'
                ORDER BY p.base_asset_symbol, o.bucket_time DESC
            ),
            daily_prices AS (
                SELECT DISTINCT ON (p.base_asset_symbol)
                    p.base_asset_symbol as symbol,
                    o.close as price_usd
                FROM pools p
                JOIN ohclv_1d o ON p.pool_id = o.pool_id
                WHERE p.quote_asset_symbol = 'USDC'
                ORDER BY p.base_asset_symbol, o.bucket_time DESC
            ),
            latest_prices AS (
                SELECT
                    COALESCE(h.symbol, d.symbol) as symbol,
                    COALESCE(h.price_usd, d.price_usd) as price_usd
                FROM daily_prices d
                LEFT JOIN hourly_prices h ON d.symbol = h.symbol
            ),
            asset_meta AS (
                SELECT DISTINCT base_asset_id as asset_id, base_asset_decimals as decimals, base_asset_symbol as symbol FROM pools
                UNION
                SELECT DISTINCT quote_asset_id, quote_asset_decimals, quote_asset_symbol FROM pools
            ),
            wallet_bms AS (
                SELECT DISTINCT balance_manager_id
                FROM margin_manager_created
                WHERE owner = $1
            )
            SELECT
                am.symbol::text as asset,
                ROUND(SUM(CASE WHEN b.deposit THEN b.amount ELSE -b.amount END) / POWER(10, am.decimals)::numeric, 6)::float8 as balance,
                ROUND(
                    (SUM(CASE WHEN b.deposit THEN b.amount ELSE -b.amount END) / POWER(10, am.decimals)::numeric) *
                    CASE WHEN UPPER(am.symbol) IN ('USDC','USDT','AUSD') THEN 1 ELSE COALESCE(lp.price_usd, 0) END
                , 2)::float8 as balance_usd
            FROM balances b
            JOIN wallet_bms wbm ON b.balance_manager_id = wbm.balance_manager_id
            -- asset_id matching strips the 0x prefix for a suffix LIKE match; this is intentional
            -- and consistent with other queries in the codebase. Assumes asset IDs are unique enough
            -- that no two assets share the same suffix, which holds for all current DeepBook pools.
            LEFT JOIN asset_meta am ON b.asset LIKE '%' || SUBSTRING(am.asset_id FROM 3) || '%'
            LEFT JOIN latest_prices lp ON am.symbol = lp.symbol
            WHERE am.symbol IS NOT NULL
            GROUP BY am.symbol, am.decimals, lp.price_usd
            HAVING SUM(CASE WHEN b.deposit THEN b.amount ELSE -b.amount END) > 0
            "#,
        )
        .bind::<Text, _>(wallet_address)
        .load::<CollateralRow>(&mut connection)
        .await;

        // --- LP positions ---
        // Uses supplier (balance_manager_id) rather than sender (wallet address) to leverage
        // idx_asset_supplied_supplier / idx_asset_withdrawn_supplier indices.
        let lp_res = diesel::sql_query(
            r#"
            WITH hourly_prices AS (
                SELECT DISTINCT ON (p.base_asset_symbol)
                    p.base_asset_symbol as symbol,
                    o.close as price_usd
                FROM pools p
                JOIN ohclv_1m o ON p.pool_id = o.pool_id
                WHERE p.quote_asset_symbol = 'USDC'
                  AND o.bucket_time >= NOW() - INTERVAL '2 hours'
                ORDER BY p.base_asset_symbol, o.bucket_time DESC
            ),
            daily_prices AS (
                SELECT DISTINCT ON (p.base_asset_symbol)
                    p.base_asset_symbol as symbol,
                    o.close as price_usd
                FROM pools p
                JOIN ohclv_1d o ON p.pool_id = o.pool_id
                WHERE p.quote_asset_symbol = 'USDC'
                ORDER BY p.base_asset_symbol, o.bucket_time DESC
            ),
            latest_prices AS (
                SELECT
                    COALESCE(h.symbol, d.symbol) as symbol,
                    COALESCE(h.price_usd, d.price_usd) as price_usd
                FROM daily_prices d
                LEFT JOIN hourly_prices h ON d.symbol = h.symbol
            ),
            asset_meta AS (
                SELECT DISTINCT base_asset_id as asset_id, base_asset_decimals as decimals, base_asset_symbol as symbol FROM pools
                UNION
                SELECT DISTINCT quote_asset_id, quote_asset_decimals, quote_asset_symbol FROM pools
            ),
            wallet_suppliers AS (
                SELECT DISTINCT balance_manager_id
                FROM margin_manager_created
                WHERE owner = $1
            ),
            lp_supplied AS (
                SELECT s.margin_pool_id, s.asset_type, SUM(s.amount) as supplied, SUM(s.shares) as supplied_shares
                FROM asset_supplied s
                JOIN wallet_suppliers ws ON s.supplier = ws.balance_manager_id
                GROUP BY s.margin_pool_id, s.asset_type
            ),
            lp_withdrawn AS (
                SELECT w.margin_pool_id, w.asset_type, SUM(w.amount) as withdrawn, SUM(w.shares) as withdrawn_shares
                FROM asset_withdrawn w
                JOIN wallet_suppliers ws ON w.supplier = ws.balance_manager_id
                GROUP BY w.margin_pool_id, w.asset_type
            )
            SELECT
                s.margin_pool_id::text,
                am.symbol::text as asset,
                ROUND((s.supplied - COALESCE(w.withdrawn, 0)) / POWER(10, COALESCE(am.decimals, 9))::numeric, 6)::float8 as net_supplied,
                (s.supplied_shares - COALESCE(w.withdrawn_shares, 0))::bigint as net_shares,
                ROUND(
                    ((s.supplied - COALESCE(w.withdrawn, 0)) / POWER(10, COALESCE(am.decimals, 9))::numeric) *
                    CASE WHEN UPPER(am.symbol) IN ('USDC','USDT','AUSD') THEN 1 ELSE COALESCE(lp2.price_usd, 0) END
                , 2)::float8 as supplied_usd
            FROM lp_supplied s
            LEFT JOIN lp_withdrawn w ON s.margin_pool_id = w.margin_pool_id AND s.asset_type = w.asset_type
            -- see comment in collateral query re: LIKE asset matching
            LEFT JOIN asset_meta am ON s.asset_type LIKE '%' || SUBSTRING(am.asset_id FROM 3) || '%'
            LEFT JOIN latest_prices lp2 ON am.symbol = lp2.symbol
            WHERE am.symbol IS NOT NULL
              AND (s.supplied - COALESCE(w.withdrawn, 0)) > 0
            "#,
        )
        .bind::<Text, _>(wallet_address)
        .load::<LpPositionRow>(&mut connection)
        .await;

        // Propagate errors and increment failure metric on any query failure
        let margin_positions = margin_res.map_err(|e| {
            self.metrics.db_requests_failed.inc();
            DeepBookError::database(format!("Error fetching margin positions: {}", e))
        })?;
        let collateral = collateral_res.map_err(|e| {
            self.metrics.db_requests_failed.inc();
            DeepBookError::database(format!("Error fetching collateral: {}", e))
        })?;
        let lp_positions = lp_res.map_err(|e| {
            self.metrics.db_requests_failed.inc();
            DeepBookError::database(format!("Error fetching LP positions: {}", e))
        })?;

        self.metrics.db_requests_succeeded.inc();

        // Compute summary totals
        let collateral_total_usd: f64 = collateral.iter().map(|c| c.balance_usd).sum();
        let margin_equity_usd: f64 = margin_positions
            .iter()
            .map(|m| m.base_asset_usd + m.quote_asset_usd)
            .sum();
        let margin_debt_usd: f64 = margin_positions
            .iter()
            .map(|m| m.base_debt_usd + m.quote_debt_usd)
            .sum();
        let lp_total_usd: f64 = lp_positions.iter().map(|l| l.supplied_usd).sum();

        Ok(PortfolioQueryResult {
            margin_positions: margin_positions
                .into_iter()
                .map(|m| PortfolioMarginPosition {
                    margin_manager_id: m.margin_manager_id,
                    pool: m.pool_name,
                    base_asset_symbol: m.base_asset_symbol,
                    quote_asset_symbol: m.quote_asset_symbol,
                    base_asset: m.base_asset,
                    quote_asset: m.quote_asset,
                    base_debt: m.base_debt,
                    quote_debt: m.quote_debt,
                    base_asset_usd: m.base_asset_usd,
                    quote_asset_usd: m.quote_asset_usd,
                    base_debt_usd: m.base_debt_usd,
                    quote_debt_usd: m.quote_debt_usd,
                    total_debt_usd: m.base_debt_usd + m.quote_debt_usd,
                    net_value_usd: m.base_asset_usd + m.quote_asset_usd
                        - m.base_debt_usd
                        - m.quote_debt_usd,
                    risk_ratio: m.risk_ratio,
                })
                .collect(),
            collateral_balances: collateral
                .into_iter()
                .map(|c| PortfolioCollateralBalance {
                    asset: c.asset,
                    balance: c.balance,
                    balance_usd: c.balance_usd,
                })
                .collect(),
            lp_positions: lp_positions
                .into_iter()
                .map(|l| PortfolioLpPosition {
                    margin_pool_id: l.margin_pool_id,
                    asset: l.asset,
                    supplied: l.net_supplied,
                    shares: l.net_shares,
                    supplied_usd: l.supplied_usd,
                })
                .collect(),
            summary: PortfolioSummary {
                total_equity_usd: collateral_total_usd + margin_equity_usd + lp_total_usd,
                total_debt_usd: margin_debt_usd,
                net_value_usd: collateral_total_usd + margin_equity_usd + lp_total_usd
                    - margin_debt_usd,
            },
        })
    }
}

// --- Portfolio response types ---

#[derive(Debug, serde::Serialize)]
pub struct PortfolioQueryResult {
    pub margin_positions: Vec<PortfolioMarginPosition>,
    pub collateral_balances: Vec<PortfolioCollateralBalance>,
    pub lp_positions: Vec<PortfolioLpPosition>,
    pub summary: PortfolioSummary,
}

#[derive(Debug, serde::Serialize)]
pub struct PortfolioMarginPosition {
    pub margin_manager_id: String,
    pub pool: String,
    pub base_asset_symbol: String,
    pub quote_asset_symbol: String,
    pub base_asset: f64,
    pub quote_asset: f64,
    pub base_debt: f64,
    pub quote_debt: f64,
    pub base_asset_usd: f64,
    pub quote_asset_usd: f64,
    pub base_debt_usd: f64,
    pub quote_debt_usd: f64,
    pub total_debt_usd: f64,
    pub net_value_usd: f64,
    pub risk_ratio: f64,
}

#[derive(Debug, serde::Serialize)]
pub struct PortfolioCollateralBalance {
    pub asset: String,
    pub balance: f64,
    pub balance_usd: f64,
}

#[derive(Debug, serde::Serialize)]
pub struct PortfolioLpPosition {
    pub margin_pool_id: String,
    pub asset: String,
    pub supplied: f64,
    pub shares: i64,
    pub supplied_usd: f64,
}

#[derive(Debug, serde::Serialize)]
pub struct PortfolioSummary {
    pub total_equity_usd: f64,
    pub total_debt_usd: f64,
    pub net_value_usd: f64,
}
