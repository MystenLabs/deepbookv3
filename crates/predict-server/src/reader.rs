use crate::error::PredictError;
use crate::metrics::RpcMetrics;
use predict_schema::models::{
    OracleActivatedRow, OracleAskBoundsSetRow, OracleCreatedRow, OraclePricesUpdatedRow,
    OracleSettledRow, OracleSviUpdatedRow, PositionMintedRow, PositionRedeemedRow,
    PredictManagerCreatedRow, PricingConfigUpdatedRow, RangeMintedRow, RangeRedeemedRow,
    RiskConfigUpdatedRow, SuppliedRow, TradingPauseUpdatedRow, WithdrawnRow,
};
use predict_schema::schema;

use diesel::deserialize::FromSqlRow;
use diesel::expression::QueryMetadata;
use diesel::pg::Pg;
use diesel::query_builder::{Query, QueryFragment, QueryId};
use diesel::query_dsl::CompatibleType;
use diesel::{ExpressionMethods, QueryDsl, QueryableByName, SelectableHelper};

use diesel_async::methods::LoadQuery;
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use prometheus::Registry;
use std::sync::Arc;
use sui_indexer_alt_metrics::db::DbConnectionStatsCollector;
use sui_pg_db::{Db, DbArgs};
use url::Url;

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

    // === Oracle queries ===

    pub async fn get_oracles_created(&self) -> Result<Vec<OracleCreatedRow>, PredictError> {
        Ok(self
            .results(
                schema::oracle_created::table
                    .select(OracleCreatedRow::as_select())
                    .order_by(schema::oracle_created::checkpoint.desc()),
            )
            .await?)
    }

    pub async fn get_oracles_activated(&self) -> Result<Vec<OracleActivatedRow>, PredictError> {
        Ok(self
            .results(
                schema::oracle_activated::table
                    .select(OracleActivatedRow::as_select())
                    .order_by(schema::oracle_activated::checkpoint.desc()),
            )
            .await?)
    }

    pub async fn get_oracles_settled(&self) -> Result<Vec<OracleSettledRow>, PredictError> {
        Ok(self
            .results(
                schema::oracle_settled::table
                    .select(OracleSettledRow::as_select())
                    .order_by(schema::oracle_settled::checkpoint.desc()),
            )
            .await?)
    }

    pub async fn get_oracle_prices(
        &self,
        oracle_id: &str,
        limit: i64,
        start_time: Option<i64>,
        end_time: Option<i64>,
    ) -> Result<Vec<OraclePricesUpdatedRow>, PredictError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();

        let mut query = schema::oracle_prices_updated::table
            .filter(schema::oracle_prices_updated::oracle_id.eq(oracle_id))
            .order_by(schema::oracle_prices_updated::checkpoint_timestamp_ms.desc())
            .select(OraclePricesUpdatedRow::as_select())
            .into_boxed();

        if let Some(start) = start_time {
            query = query
                .filter(schema::oracle_prices_updated::checkpoint_timestamp_ms.ge(start));
        }
        if let Some(end) = end_time {
            query =
                query.filter(schema::oracle_prices_updated::checkpoint_timestamp_ms.le(end));
        }

        query = query.limit(limit);
        let res = query.get_results(&mut conn).await;

        if res.is_ok() {
            self.metrics.db_requests_succeeded.inc();
        } else {
            self.metrics.db_requests_failed.inc();
        }
        Ok(res?)
    }

    pub async fn get_oracle_latest_price(
        &self,
        oracle_id: &str,
    ) -> Result<OraclePricesUpdatedRow, PredictError> {
        let query = schema::oracle_prices_updated::table
            .filter(schema::oracle_prices_updated::oracle_id.eq(oracle_id.to_string()))
            .order_by(schema::oracle_prices_updated::checkpoint_timestamp_ms.desc())
            .select(OraclePricesUpdatedRow::as_select());

        self.first(query)
            .await
            .map_err(|_| PredictError::not_found(format!("oracle prices for {}", oracle_id)))
    }

    pub async fn get_oracle_svi(
        &self,
        oracle_id: &str,
        limit: i64,
    ) -> Result<Vec<OracleSviUpdatedRow>, PredictError> {
        let query = schema::oracle_svi_updated::table
            .filter(schema::oracle_svi_updated::oracle_id.eq(oracle_id.to_string()))
            .order_by(schema::oracle_svi_updated::checkpoint_timestamp_ms.desc())
            .select(OracleSviUpdatedRow::as_select())
            .limit(limit);
        Ok(self.results(query).await?)
    }

    pub async fn get_oracle_latest_svi(
        &self,
        oracle_id: &str,
    ) -> Result<OracleSviUpdatedRow, PredictError> {
        let query = schema::oracle_svi_updated::table
            .filter(schema::oracle_svi_updated::oracle_id.eq(oracle_id.to_string()))
            .order_by(schema::oracle_svi_updated::checkpoint_timestamp_ms.desc())
            .select(OracleSviUpdatedRow::as_select());

        self.first(query)
            .await
            .map_err(|_| PredictError::not_found(format!("oracle SVI for {}", oracle_id)))
    }

    // === Trading queries ===

    pub async fn get_positions_minted(
        &self,
        oracle_id: Option<&str>,
        trader: Option<&str>,
        manager_id: Option<&str>,
        limit: i64,
    ) -> Result<Vec<PositionMintedRow>, PredictError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();

        let mut query = schema::position_minted::table
            .order_by(schema::position_minted::checkpoint.desc())
            .select(PositionMintedRow::as_select())
            .into_boxed();

        if let Some(oid) = oracle_id {
            query = query.filter(schema::position_minted::oracle_id.eq(oid.to_string()));
        }
        if let Some(t) = trader {
            query = query.filter(schema::position_minted::trader.eq(t.to_string()));
        }
        if let Some(mid) = manager_id {
            query = query.filter(schema::position_minted::manager_id.eq(mid.to_string()));
        }

        query = query.limit(limit);
        let res = query.get_results(&mut conn).await;

        if res.is_ok() {
            self.metrics.db_requests_succeeded.inc();
        } else {
            self.metrics.db_requests_failed.inc();
        }
        Ok(res?)
    }

    pub async fn get_positions_redeemed(
        &self,
        oracle_id: Option<&str>,
        owner: Option<&str>,
        manager_id: Option<&str>,
        limit: i64,
    ) -> Result<Vec<PositionRedeemedRow>, PredictError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();

        let mut query = schema::position_redeemed::table
            .order_by(schema::position_redeemed::checkpoint.desc())
            .select(PositionRedeemedRow::as_select())
            .into_boxed();

        if let Some(oid) = oracle_id {
            query = query.filter(schema::position_redeemed::oracle_id.eq(oid.to_string()));
        }
        if let Some(o) = owner {
            query = query.filter(schema::position_redeemed::owner.eq(o.to_string()));
        }
        if let Some(mid) = manager_id {
            query = query.filter(schema::position_redeemed::manager_id.eq(mid.to_string()));
        }

        query = query.limit(limit);
        let res = query.get_results(&mut conn).await;

        if res.is_ok() {
            self.metrics.db_requests_succeeded.inc();
        } else {
            self.metrics.db_requests_failed.inc();
        }
        Ok(res?)
    }

    pub async fn get_ranges_minted(
        &self,
        oracle_id: Option<&str>,
        trader: Option<&str>,
        manager_id: Option<&str>,
        limit: i64,
    ) -> Result<Vec<RangeMintedRow>, PredictError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();

        let mut query = schema::range_minted::table
            .order_by(schema::range_minted::checkpoint.desc())
            .select(RangeMintedRow::as_select())
            .into_boxed();

        if let Some(oid) = oracle_id {
            query = query.filter(schema::range_minted::oracle_id.eq(oid.to_string()));
        }
        if let Some(t) = trader {
            query = query.filter(schema::range_minted::trader.eq(t.to_string()));
        }
        if let Some(mid) = manager_id {
            query = query.filter(schema::range_minted::manager_id.eq(mid.to_string()));
        }

        query = query.limit(limit);
        let res = query.get_results(&mut conn).await;

        if res.is_ok() {
            self.metrics.db_requests_succeeded.inc();
        } else {
            self.metrics.db_requests_failed.inc();
        }
        Ok(res?)
    }

    pub async fn get_ranges_redeemed(
        &self,
        oracle_id: Option<&str>,
        trader: Option<&str>,
        manager_id: Option<&str>,
        limit: i64,
    ) -> Result<Vec<RangeRedeemedRow>, PredictError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();

        let mut query = schema::range_redeemed::table
            .order_by(schema::range_redeemed::checkpoint.desc())
            .select(RangeRedeemedRow::as_select())
            .into_boxed();

        if let Some(oid) = oracle_id {
            query = query.filter(schema::range_redeemed::oracle_id.eq(oid.to_string()));
        }
        if let Some(t) = trader {
            query = query.filter(schema::range_redeemed::trader.eq(t.to_string()));
        }
        if let Some(mid) = manager_id {
            query = query.filter(schema::range_redeemed::manager_id.eq(mid.to_string()));
        }

        query = query.limit(limit);
        let res = query.get_results(&mut conn).await;

        if res.is_ok() {
            self.metrics.db_requests_succeeded.inc();
        } else {
            self.metrics.db_requests_failed.inc();
        }
        Ok(res?)
    }

    pub async fn get_ranges_for_manager(
        &self,
        manager_id: &str,
    ) -> Result<(Vec<RangeMintedRow>, Vec<RangeRedeemedRow>), PredictError> {
        let minted = self
            .get_ranges_minted(None, None, Some(manager_id), 1000)
            .await?;
        let redeemed = self
            .get_ranges_redeemed(None, None, Some(manager_id), 1000)
            .await?;
        Ok((minted, redeemed))
    }

    // === LP queries ===

    pub async fn get_lp_supplies(
        &self,
        supplier: Option<&str>,
        limit: i64,
    ) -> Result<Vec<SuppliedRow>, PredictError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();

        let mut query = schema::supplied::table
            .order_by(schema::supplied::checkpoint.desc())
            .select(SuppliedRow::as_select())
            .into_boxed();

        if let Some(s) = supplier {
            query = query.filter(schema::supplied::supplier.eq(s.to_string()));
        }

        query = query.limit(limit);
        let res = query.get_results(&mut conn).await;

        if res.is_ok() {
            self.metrics.db_requests_succeeded.inc();
        } else {
            self.metrics.db_requests_failed.inc();
        }
        Ok(res?)
    }

    pub async fn get_lp_withdrawals(
        &self,
        withdrawer: Option<&str>,
        limit: i64,
    ) -> Result<Vec<WithdrawnRow>, PredictError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();

        let mut query = schema::withdrawn::table
            .order_by(schema::withdrawn::checkpoint.desc())
            .select(WithdrawnRow::as_select())
            .into_boxed();

        if let Some(w) = withdrawer {
            query = query.filter(schema::withdrawn::withdrawer.eq(w.to_string()));
        }

        query = query.limit(limit);
        let res = query.get_results(&mut conn).await;

        if res.is_ok() {
            self.metrics.db_requests_succeeded.inc();
        } else {
            self.metrics.db_requests_failed.inc();
        }
        Ok(res?)
    }

    // === User queries ===

    pub async fn get_managers(
        &self,
        owner: Option<&str>,
    ) -> Result<Vec<PredictManagerCreatedRow>, PredictError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();

        let mut query = schema::predict_manager_created::table
            .order_by(schema::predict_manager_created::checkpoint.desc())
            .select(PredictManagerCreatedRow::as_select())
            .into_boxed();

        if let Some(o) = owner {
            query = query.filter(schema::predict_manager_created::owner.eq(o.to_string()));
        }

        let res = query.get_results(&mut conn).await;

        if res.is_ok() {
            self.metrics.db_requests_succeeded.inc();
        } else {
            self.metrics.db_requests_failed.inc();
        }
        Ok(res?)
    }

    pub async fn get_positions_for_manager(
        &self,
        manager_id: &str,
    ) -> Result<(Vec<PositionMintedRow>, Vec<PositionRedeemedRow>), PredictError> {
        let minted = self
            .get_positions_minted(None, None, Some(manager_id), 1000)
            .await?;
        let redeemed = self
            .get_positions_redeemed(None, None, Some(manager_id), 1000)
            .await?;
        Ok((minted, redeemed))
    }

    // === Config queries ===

    pub async fn get_latest_pricing_config(
        &self,
    ) -> Result<PricingConfigUpdatedRow, PredictError> {
        let query = schema::pricing_config_updated::table
            .order_by(schema::pricing_config_updated::checkpoint.desc())
            .select(PricingConfigUpdatedRow::as_select());

        self.first(query)
            .await
            .map_err(|_| PredictError::not_found("pricing config"))
    }

    pub async fn get_latest_risk_config(&self) -> Result<RiskConfigUpdatedRow, PredictError> {
        let query = schema::risk_config_updated::table
            .order_by(schema::risk_config_updated::checkpoint.desc())
            .select(RiskConfigUpdatedRow::as_select());

        self.first(query)
            .await
            .map_err(|_| PredictError::not_found("risk config"))
    }

    pub async fn get_trading_pause_status(
        &self,
    ) -> Result<TradingPauseUpdatedRow, PredictError> {
        let query = schema::trading_pause_updated::table
            .order_by(schema::trading_pause_updated::checkpoint.desc())
            .select(TradingPauseUpdatedRow::as_select());

        self.first(query)
            .await
            .map_err(|_| PredictError::not_found("trading pause status"))
    }

    // === Oracle ask bounds ===

    pub async fn get_latest_oracle_ask_bounds(
        &self,
        oracle_id: &str,
    ) -> Result<Option<OracleAskBoundsSetRow>, PredictError> {
        #[derive(QueryableByName)]
        struct LatestBoundsRow {
            #[diesel(sql_type = diesel::sql_types::Text)]
            event_digest: String,
            #[diesel(sql_type = diesel::sql_types::Text)]
            digest: String,
            #[diesel(sql_type = diesel::sql_types::Text)]
            sender: String,
            #[diesel(sql_type = diesel::sql_types::BigInt)]
            checkpoint: i64,
            #[diesel(sql_type = diesel::sql_types::BigInt)]
            checkpoint_timestamp_ms: i64,
            #[diesel(sql_type = diesel::sql_types::Text)]
            package: String,
            #[diesel(sql_type = diesel::sql_types::Text)]
            predict_id: String,
            #[diesel(sql_type = diesel::sql_types::Text)]
            oracle_id: String,
            #[diesel(sql_type = diesel::sql_types::BigInt)]
            min_ask_price: i64,
            #[diesel(sql_type = diesel::sql_types::BigInt)]
            max_ask_price: i64,
            #[diesel(sql_type = diesel::sql_types::Text)]
            kind: String,
        }

        // Single query returning the most recent set-or-cleared row for this
        // oracle. If the winning row is a `set`, its bounds are active; if it
        // is a `cleared`, the latest set has been cancelled and there are no
        // active bounds. Collapsing this into one query avoids having to
        // distinguish "no rows" from real DB errors across two separate calls.
        let sql = r#"
            SELECT
                event_digest,
                digest,
                sender,
                checkpoint,
                checkpoint_timestamp_ms,
                package,
                predict_id,
                oracle_id,
                min_ask_price,
                max_ask_price,
                'set' AS kind
            FROM oracle_ask_bounds_set
            WHERE oracle_id = $1
            UNION ALL
            SELECT
                event_digest,
                digest,
                sender,
                checkpoint,
                checkpoint_timestamp_ms,
                package,
                predict_id,
                oracle_id,
                0 AS min_ask_price,
                0 AS max_ask_price,
                'cleared' AS kind
            FROM oracle_ask_bounds_cleared
            WHERE oracle_id = $1
            ORDER BY checkpoint DESC
            LIMIT 1
        "#;

        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();

        let res = diesel::sql_query(sql)
            .bind::<diesel::sql_types::Text, _>(oracle_id)
            .get_result::<LatestBoundsRow>(&mut conn)
            .await;

        match res {
            Ok(row) => {
                self.metrics.db_requests_succeeded.inc();
                if row.kind == "set" {
                    Ok(Some(OracleAskBoundsSetRow {
                        event_digest: row.event_digest,
                        digest: row.digest,
                        sender: row.sender,
                        checkpoint: row.checkpoint,
                        checkpoint_timestamp_ms: row.checkpoint_timestamp_ms,
                        package: row.package,
                        predict_id: row.predict_id,
                        oracle_id: row.oracle_id,
                        min_ask_price: row.min_ask_price,
                        max_ask_price: row.max_ask_price,
                    }))
                } else {
                    Ok(None)
                }
            }
            Err(diesel::result::Error::NotFound) => {
                self.metrics.db_requests_succeeded.inc();
                Ok(None)
            }
            Err(e) => {
                self.metrics.db_requests_failed.inc();
                Err(PredictError::database(e.to_string()))
            }
        }
    }

    // === Quote assets ===

    pub async fn get_enabled_quote_assets(
        &self,
        predict_id: &str,
    ) -> Result<Vec<String>, PredictError> {
        #[derive(QueryableByName)]
        struct QuoteAssetRow {
            #[diesel(sql_type = diesel::sql_types::Text)]
            quote_asset: String,
        }

        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();

        let sql = r#"
            SELECT quote_asset
            FROM (
                SELECT DISTINCT ON (quote_asset) quote_asset, enabled
                FROM (
                    SELECT quote_asset, checkpoint, TRUE AS enabled
                      FROM quote_asset_enabled  WHERE predict_id = $1
                    UNION ALL
                    SELECT quote_asset, checkpoint, FALSE AS enabled
                      FROM quote_asset_disabled WHERE predict_id = $1
                ) all_events
                ORDER BY quote_asset, checkpoint DESC
            ) latest
            WHERE enabled = TRUE
        "#;

        let res = diesel::sql_query(sql)
            .bind::<diesel::sql_types::Text, _>(predict_id)
            .get_results::<QuoteAssetRow>(&mut conn)
            .await;

        if res.is_ok() {
            self.metrics.db_requests_succeeded.inc();
        } else {
            self.metrics.db_requests_failed.inc();
        }

        Ok(res?.into_iter().map(|r| r.quote_asset).collect())
    }

    // === System queries ===

    pub async fn get_watermarks(
        &self,
    ) -> Result<Vec<(String, i64, i64, i64)>, PredictError> {
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
}
