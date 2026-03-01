use crate::error::PredictError;
use crate::metrics::RpcMetrics;
use predict_schema::models::{
    AdminVaultBalanceChangedRow, CollateralizedPositionMintedRow,
    CollateralizedPositionRedeemedRow, OracleActivatedRow, OracleCreatedRow,
    OraclePricesUpdatedRow, OracleSettledRow, OracleSviUpdatedRow, PositionMintedRow,
    PositionRedeemedRow, PredictManagerCreatedRow, PricingConfigUpdatedRow, RiskConfigUpdatedRow,
    TradingPauseUpdatedRow,
};
use predict_schema::schema;

use diesel::deserialize::FromSqlRow;
use diesel::expression::QueryMetadata;
use diesel::pg::Pg;
use diesel::query_builder::{Query, QueryFragment, QueryId};
use diesel::query_dsl::CompatibleType;
use diesel::{ExpressionMethods, QueryDsl, SelectableHelper};

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
        trader: Option<&str>,
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
        if let Some(t) = trader {
            query = query.filter(schema::position_redeemed::trader.eq(t.to_string()));
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

    pub async fn get_collateralized_minted(
        &self,
        oracle_id: Option<&str>,
        trader: Option<&str>,
        manager_id: Option<&str>,
        limit: i64,
    ) -> Result<Vec<CollateralizedPositionMintedRow>, PredictError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();

        let mut query = schema::collateralized_position_minted::table
            .order_by(schema::collateralized_position_minted::checkpoint.desc())
            .select(CollateralizedPositionMintedRow::as_select())
            .into_boxed();

        if let Some(oid) = oracle_id {
            query = query
                .filter(schema::collateralized_position_minted::oracle_id.eq(oid.to_string()));
        }
        if let Some(t) = trader {
            query =
                query.filter(schema::collateralized_position_minted::trader.eq(t.to_string()));
        }
        if let Some(mid) = manager_id {
            query = query
                .filter(schema::collateralized_position_minted::manager_id.eq(mid.to_string()));
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

    pub async fn get_collateralized_redeemed(
        &self,
        oracle_id: Option<&str>,
        trader: Option<&str>,
        manager_id: Option<&str>,
        limit: i64,
    ) -> Result<Vec<CollateralizedPositionRedeemedRow>, PredictError> {
        let mut conn = self.db.connect().await?;
        let _guard = self.metrics.db_latency.start_timer();

        let mut query = schema::collateralized_position_redeemed::table
            .order_by(schema::collateralized_position_redeemed::checkpoint.desc())
            .select(CollateralizedPositionRedeemedRow::as_select())
            .into_boxed();

        if let Some(oid) = oracle_id {
            query = query
                .filter(schema::collateralized_position_redeemed::oracle_id.eq(oid.to_string()));
        }
        if let Some(t) = trader {
            query = query
                .filter(schema::collateralized_position_redeemed::trader.eq(t.to_string()));
        }
        if let Some(mid) = manager_id {
            query = query
                .filter(schema::collateralized_position_redeemed::manager_id.eq(mid.to_string()));
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

    // === System queries ===

    pub async fn get_vault_history(
        &self,
        limit: i64,
    ) -> Result<Vec<AdminVaultBalanceChangedRow>, PredictError> {
        let query = schema::admin_vault_balance_changed::table
            .order_by(schema::admin_vault_balance_changed::checkpoint.desc())
            .select(AdminVaultBalanceChangedRow::as_select())
            .limit(limit);
        Ok(self.results(query).await?)
    }

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
