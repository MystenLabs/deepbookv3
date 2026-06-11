// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use crate::error::PredictError;
use axum::http::Method;
use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    routing::get,
    Json, Router,
};
use serde::Deserialize;
use std::collections::HashMap;
use std::net::SocketAddr;
use std::net::{IpAddr, Ipv4Addr};
use std::time::{SystemTime, UNIX_EPOCH};
use sui_pg_db::DbArgs;
use tokio::net::TcpListener;
use tokio::sync::oneshot;
use tokio::sync::OnceCell;
use tower_http::cors::{AllowMethods, Any, CorsLayer};
use url::Url;

use crate::metrics::middleware::track_metrics;
use crate::metrics::RpcMetrics;
use crate::reader::Reader;
use axum::middleware::from_fn_with_state;
use prometheus::Registry;
use std::sync::Arc;
use sui_futures::service::Service;
use sui_indexer_alt_metrics::{MetricsArgs, MetricsService};
use sui_sdk::SuiClientBuilder;

pub const STATUS_PATH: &str = "/status";
pub const MARKET_ORDERS_PATH: &str = "/markets/:expiry_market_id/orders";
pub const MANAGER_ORDERS_PATH: &str = "/managers/:predict_manager_id/orders";
pub const MANAGERS_PATH: &str = "/managers";
pub const MARKETS_PATH: &str = "/markets";
pub const ORACLE_PRICES_PATH: &str = "/oracles/:market_oracle_id/prices";
pub const ORACLE_SVI_PATH: &str = "/oracles/:market_oracle_id/svi";
pub const ORACLE_SETTLEMENTS_PATH: &str = "/oracles/:market_oracle_id/settlements";
pub const PYTH_SOURCE_UPDATES_PATH: &str = "/pyth-sources/:pyth_source_id/updates";
pub const VAULT_SUPPLIES_PATH: &str = "/vaults/:pool_vault_id/supplies";
pub const VAULT_WITHDRAWALS_PATH: &str = "/vaults/:pool_vault_id/withdrawals";
pub const VAULT_PROFIT_PATH: &str = "/vaults/:pool_vault_id/profit";
pub const VAULT_FUNDING_PATH: &str = "/vaults/:pool_vault_id/funding";
pub const VAULT_CASH_REBALANCES_PATH: &str = "/vaults/:pool_vault_id/cash-rebalances";
pub const VAULT_CASH_RECEIPTS_PATH: &str = "/vaults/:pool_vault_id/cash-receipts";
pub const MANAGER_STAKING_PATH: &str = "/managers/:predict_manager_id/staking";
pub const MANAGER_REBATES_PATH: &str = "/managers/:predict_manager_id/rebates";
pub const BUILDER_CODE_FEES_PATH: &str = "/builder-codes/:builder_code_id/fees";

#[derive(Clone)]
pub struct AppState {
    reader: Reader,
    metrics: Arc<RpcMetrics>,
    rpc_url: Url,
    sui_client: Arc<OnceCell<sui_sdk::SuiClient>>,
}

impl AppState {
    pub async fn new(
        database_url: Url,
        args: DbArgs,
        registry: &Registry,
        rpc_url: Url,
    ) -> Result<Self, anyhow::Error> {
        let metrics = RpcMetrics::new(registry);
        let reader = Reader::new(database_url, args, metrics.clone(), registry).await?;

        Ok(Self {
            reader,
            metrics,
            rpc_url,
            sui_client: Arc::new(OnceCell::new()),
        })
    }

    /// Returns a reference to the shared SuiClient instance.
    /// Lazily initializes the client on first access and caches it for subsequent calls
    pub async fn sui_client(&self) -> Result<&sui_sdk::SuiClient, PredictError> {
        self.sui_client
            .get_or_try_init(|| async {
                SuiClientBuilder::default()
                    .build(self.rpc_url.as_str())
                    .await
            })
            .await
            .map_err(PredictError::from)
    }

    pub(crate) fn metrics(&self) -> &RpcMetrics {
        &self.metrics
    }
}

/// Query parameters for the /status endpoint
#[derive(Debug, Deserialize)]
pub struct StatusQueryParams {
    /// Maximum acceptable checkpoint lag for "healthy" status (default: 100)
    #[serde(default = "default_max_checkpoint_lag")]
    pub max_checkpoint_lag: i64,
    /// Maximum acceptable time lag in seconds for "healthy" status (default: 60)
    #[serde(default = "default_max_time_lag_seconds")]
    pub max_time_lag_seconds: i64,
}

fn default_max_checkpoint_lag() -> i64 {
    100
}

fn default_max_time_lag_seconds() -> i64 {
    60
}

pub async fn run_server(
    server_port: u16,
    database_url: Url,
    db_arg: DbArgs,
    rpc_url: Url,
    metrics_address: SocketAddr,
) -> Result<(), anyhow::Error> {
    let registry = Registry::new_custom(Some("predict_api".into()), None)
        .expect("Failed to create Prometheus registry.");

    let metrics = MetricsService::new(MetricsArgs { metrics_address }, registry);

    let state = AppState::new(database_url, db_arg, metrics.registry(), rpc_url).await?;
    let socket_address = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(0, 0, 0, 0)), server_port);

    println!("Server started successfully on port {}", server_port);

    let s_metrics = metrics.run().await?;

    let listener = TcpListener::bind(socket_address).await?;
    let (stx, srx) = oneshot::channel::<()>();

    Service::new()
        .attach(s_metrics)
        .with_shutdown_signal(async move {
            let _ = stx.send(());
        })
        .spawn(async move {
            axum::serve(listener, make_router(Arc::new(state)))
                .with_graceful_shutdown(async move {
                    let _ = srx.await;
                })
                .await?;

            Ok(())
        })
        .main()
        .await?;

    Ok(())
}

pub(crate) fn make_router(state: Arc<AppState>) -> Router {
    let cors = CorsLayer::new()
        .allow_methods(AllowMethods::list(vec![
            Method::GET,
            Method::POST,
            Method::PUT,
            Method::DELETE,
            Method::OPTIONS,
        ]))
        .allow_headers(Any)
        .allow_origin(Any);

    Router::new()
        .route("/", get(health_check))
        .route(STATUS_PATH, get(status))
        .route(MARKET_ORDERS_PATH, get(market_orders))
        .route(MANAGER_ORDERS_PATH, get(manager_orders))
        .route(MANAGERS_PATH, get(managers))
        .route(MARKETS_PATH, get(markets))
        .route(ORACLE_PRICES_PATH, get(oracle_prices))
        .route(ORACLE_SVI_PATH, get(oracle_svi))
        .route(ORACLE_SETTLEMENTS_PATH, get(oracle_settlements))
        .route(PYTH_SOURCE_UPDATES_PATH, get(pyth_source_updates))
        .route(VAULT_SUPPLIES_PATH, get(vault_supplies))
        .route(VAULT_WITHDRAWALS_PATH, get(vault_withdrawals))
        .route(VAULT_PROFIT_PATH, get(vault_profit))
        .route(VAULT_FUNDING_PATH, get(vault_funding))
        .route(VAULT_CASH_REBALANCES_PATH, get(vault_cash_rebalances))
        .route(VAULT_CASH_RECEIPTS_PATH, get(vault_cash_receipts))
        .route(MANAGER_STAKING_PATH, get(manager_staking))
        .route(MANAGER_REBATES_PATH, get(manager_rebates))
        .route(BUILDER_CODE_FEES_PATH, get(builder_code_fees))
        .with_state(state.clone())
        .layer(cors)
        .layer(from_fn_with_state(state, track_metrics))
}

async fn health_check() -> StatusCode {
    StatusCode::OK
}

/// Get indexer status including checkpoint lag
async fn status(
    Query(params): Query<StatusQueryParams>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<serde_json::Value>, PredictError> {
    // Get watermarks from the database
    let watermarks = state.reader.get_watermarks().await?;

    // Get the latest checkpoint from Sui RPC
    let sui_client = state.sui_client().await?;
    let latest_checkpoint = sui_client
        .read_api()
        .get_latest_checkpoint_sequence_number()
        .await
        .map_err(|e| PredictError::rpc(format!("Failed to get latest checkpoint: {}", e)))?;

    // Get current timestamp
    let current_time_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| PredictError::internal("System time error"))?
        .as_millis() as i64;

    // Build status for each pipeline
    let mut pipelines = Vec::new();
    let mut min_checkpoint = i64::MAX;
    let mut max_lag_pipeline_name = String::new();
    let mut max_checkpoint_lag = 0i64;

    for (pipeline, checkpoint_hi, timestamp_ms_hi, epoch_hi) in watermarks {
        let checkpoint_lag = latest_checkpoint as i64 - checkpoint_hi;
        let time_lag_ms = current_time_ms - timestamp_ms_hi;
        let time_lag_seconds = time_lag_ms / 1000;
        let is_backfill = pipeline.contains("@backfill");

        // Exclude backfill pipelines from health calculation
        if !is_backfill {
            if checkpoint_hi < min_checkpoint {
                min_checkpoint = checkpoint_hi;
            }
            if checkpoint_lag > max_checkpoint_lag {
                max_checkpoint_lag = checkpoint_lag;
                max_lag_pipeline_name = pipeline.clone();
            }
        }

        pipelines.push(serde_json::json!({
            "pipeline": pipeline,
            "indexed_checkpoint": checkpoint_hi,
            "indexed_epoch": epoch_hi,
            "indexed_timestamp_ms": timestamp_ms_hi,
            "checkpoint_lag": checkpoint_lag,
            "time_lag_seconds": time_lag_seconds,
            "latest_onchain_checkpoint": latest_checkpoint,
            "is_backfill": is_backfill,
        }));
    }

    let max_time_lag_seconds = pipelines
        .iter()
        .filter_map(|p| {
            if p["is_backfill"].as_bool() == Some(true) {
                None
            } else {
                p["time_lag_seconds"].as_i64()
            }
        })
        .max()
        .unwrap_or(0);

    // Handle case where no pipelines exist
    let earliest_checkpoint = if min_checkpoint == i64::MAX {
        0
    } else {
        min_checkpoint
    };

    let is_healthy = max_checkpoint_lag < params.max_checkpoint_lag
        && max_time_lag_seconds < params.max_time_lag_seconds;
    let status_str = if is_healthy { "OK" } else { "UNHEALTHY" };

    Ok(Json(serde_json::json!({
        "status": status_str,
        "latest_onchain_checkpoint": latest_checkpoint,
        "current_time_ms": current_time_ms,
        "earliest_checkpoint": earliest_checkpoint,
        "max_lag_pipeline": max_lag_pipeline_name,
        "pipelines": pipelines,
        "max_checkpoint_lag": max_checkpoint_lag,
        "max_time_lag_seconds": max_time_lag_seconds,
    })))
}

/// Default page size when `?limit` is absent.
const DEFAULT_LIMIT: i64 = 50;
/// Hard cap on page size.
const MAX_LIMIT: i64 = 500;

/// Timestamp-window feed query params, mirroring core's `ParameterUtil`
/// (`crates/server/src/server.rs`) but with sane limit defaults. `start_time`
/// and `end_time` are parsed as unix SECONDS and converted to milliseconds.
trait FeedParams {
    /// `?start_time` (unix seconds → ms), defaulting to 0 (no lower bound).
    fn start_time_ms(&self) -> i64;
    /// `?end_time` (unix seconds → ms), defaulting to now.
    fn end_time_ms(&self) -> i64;
    /// `?limit`, defaulting to `DEFAULT_LIMIT` and clamped to `[1, MAX_LIMIT]`.
    fn limit(&self) -> i64;
}

impl FeedParams for HashMap<String, String> {
    fn start_time_ms(&self) -> i64 {
        self.get("start_time")
            .and_then(|v| v.parse::<i64>().ok())
            .map(|t| t * 1000)
            .unwrap_or(0)
    }

    fn end_time_ms(&self) -> i64 {
        self.get("end_time")
            .and_then(|v| v.parse::<i64>().ok())
            .map(|t| t * 1000)
            .unwrap_or_else(|| {
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map(|d| d.as_millis() as i64)
                    .unwrap_or(i64::MAX)
            })
    }

    fn limit(&self) -> i64 {
        self.get("limit")
            .and_then(|v| v.parse::<i64>().ok())
            .unwrap_or(DEFAULT_LIMIT)
            .clamp(1, MAX_LIMIT)
    }
}

/// Interleaved order feed for a market, timestamp-windowed newest-first.
async fn market_orders(
    Path(expiry_market_id): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<serde_json::Value>>, PredictError> {
    let data = state
        .reader
        .get_market_orders(
            expiry_market_id,
            params.start_time_ms(),
            params.end_time_ms(),
            params.limit(),
        )
        .await?;
    Ok(Json(data))
}

/// Interleaved order feed for a manager, timestamp-windowed newest-first.
async fn manager_orders(
    Path(predict_manager_id): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<serde_json::Value>>, PredictError> {
    let data = state
        .reader
        .get_manager_orders(
            predict_manager_id,
            params.start_time_ms(),
            params.end_time_ms(),
            params.limit(),
        )
        .await?;
    Ok(Json(data))
}

/// `predict_manager_created` list, optionally filtered by `?owner`.
async fn managers(
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<serde_json::Value>>, PredictError> {
    let data = state
        .reader
        .get_managers(
            params.get("owner").cloned(),
            params.start_time_ms(),
            params.end_time_ms(),
            params.limit(),
        )
        .await?;
    Ok(Json(data))
}

/// `market_created` list, timestamp-windowed newest-first.
async fn markets(
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<serde_json::Value>>, PredictError> {
    let data = state
        .reader
        .get_markets(params.start_time_ms(), params.end_time_ms(), params.limit())
        .await?;
    Ok(Json(data))
}

/// `block_scholes_prices_updated` feed for one oracle.
async fn oracle_prices(
    Path(market_oracle_id): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<serde_json::Value>>, PredictError> {
    let data = state
        .reader
        .get_oracle_prices(
            market_oracle_id,
            params.start_time_ms(),
            params.end_time_ms(),
            params.limit(),
        )
        .await?;
    Ok(Json(data))
}

/// `block_scholes_svi_updated` feed for one oracle.
async fn oracle_svi(
    Path(market_oracle_id): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<serde_json::Value>>, PredictError> {
    let data = state
        .reader
        .get_oracle_svi(
            market_oracle_id,
            params.start_time_ms(),
            params.end_time_ms(),
            params.limit(),
        )
        .await?;
    Ok(Json(data))
}

/// `market_oracle_settled` feed for one oracle.
async fn oracle_settlements(
    Path(market_oracle_id): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<serde_json::Value>>, PredictError> {
    let data = state
        .reader
        .get_oracle_settlements(
            market_oracle_id,
            params.start_time_ms(),
            params.end_time_ms(),
            params.limit(),
        )
        .await?;
    Ok(Json(data))
}

/// `pyth_source_updated` feed for one pyth source.
async fn pyth_source_updates(
    Path(pyth_source_id): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<serde_json::Value>>, PredictError> {
    let data = state
        .reader
        .get_pyth_source_updates(
            pyth_source_id,
            params.start_time_ms(),
            params.end_time_ms(),
            params.limit(),
        )
        .await?;
    Ok(Json(data))
}

/// `supply_executed` feed for one vault.
async fn vault_supplies(
    Path(pool_vault_id): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<serde_json::Value>>, PredictError> {
    let data = state
        .reader
        .get_vault_supplies(
            pool_vault_id,
            params.start_time_ms(),
            params.end_time_ms(),
            params.limit(),
        )
        .await?;
    Ok(Json(data))
}

/// `withdraw_executed` feed for one vault.
async fn vault_withdrawals(
    Path(pool_vault_id): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<serde_json::Value>>, PredictError> {
    let data = state
        .reader
        .get_vault_withdrawals(
            pool_vault_id,
            params.start_time_ms(),
            params.end_time_ms(),
            params.limit(),
        )
        .await?;
    Ok(Json(data))
}

/// `expiry_profit_materialized` feed for one vault.
async fn vault_profit(
    Path(pool_vault_id): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<serde_json::Value>>, PredictError> {
    let data = state
        .reader
        .get_vault_profit(
            pool_vault_id,
            params.start_time_ms(),
            params.end_time_ms(),
            params.limit(),
        )
        .await?;
    Ok(Json(data))
}

/// `expiry_max_funding_updated` feed for one vault.
async fn vault_funding(
    Path(pool_vault_id): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<serde_json::Value>>, PredictError> {
    let data = state
        .reader
        .get_vault_funding(
            pool_vault_id,
            params.start_time_ms(),
            params.end_time_ms(),
            params.limit(),
        )
        .await?;
    Ok(Json(data))
}

/// `expiry_cash_rebalanced` feed for one vault.
async fn vault_cash_rebalances(
    Path(pool_vault_id): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<serde_json::Value>>, PredictError> {
    let data = state
        .reader
        .get_vault_cash_rebalances(
            pool_vault_id,
            params.start_time_ms(),
            params.end_time_ms(),
            params.limit(),
        )
        .await?;
    Ok(Json(data))
}

/// `expiry_cash_received` feed for one vault.
async fn vault_cash_receipts(
    Path(pool_vault_id): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<serde_json::Value>>, PredictError> {
    let data = state
        .reader
        .get_vault_cash_receipts(
            pool_vault_id,
            params.start_time_ms(),
            params.end_time_ms(),
            params.limit(),
        )
        .await?;
    Ok(Json(data))
}

/// Interleaved DEEP staking feed (`deep_staked` + `deep_unstaked`) for one
/// manager.
async fn manager_staking(
    Path(predict_manager_id): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<serde_json::Value>>, PredictError> {
    let data = state
        .reader
        .get_manager_staking(
            predict_manager_id,
            params.start_time_ms(),
            params.end_time_ms(),
            params.limit(),
        )
        .await?;
    Ok(Json(data))
}

/// `trading_loss_rebate_claimed` feed for one manager.
async fn manager_rebates(
    Path(predict_manager_id): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<serde_json::Value>>, PredictError> {
    let data = state
        .reader
        .get_manager_rebates(
            predict_manager_id,
            params.start_time_ms(),
            params.end_time_ms(),
            params.limit(),
        )
        .await?;
    Ok(Json(data))
}

/// `builder_fees_claimed` feed for one builder code.
async fn builder_code_fees(
    Path(builder_code_id): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<serde_json::Value>>, PredictError> {
    let data = state
        .reader
        .get_builder_code_fees(
            builder_code_id,
            params.start_time_ms(),
            params.end_time_ms(),
            params.limit(),
        )
        .await?;
    Ok(Json(data))
}
