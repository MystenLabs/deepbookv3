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
// Async-LP request/fill/flush feeds. Oracle feeds (prices/SVI/sources) live in
// the separate oracle service, keyed by propbook_oracle_id.
pub const VAULT_SUPPLY_REQUESTS_PATH: &str = "/vaults/:pool_vault_id/supply-requests";
pub const VAULT_WITHDRAW_REQUESTS_PATH: &str = "/vaults/:pool_vault_id/withdraw-requests";
pub const VAULT_SUPPLY_FILLS_PATH: &str = "/vaults/:pool_vault_id/supply-fills";
pub const VAULT_WITHDRAW_FILLS_PATH: &str = "/vaults/:pool_vault_id/withdraw-fills";
pub const VAULT_FLUSHES_PATH: &str = "/vaults/:pool_vault_id/flushes";
pub const VAULT_PROFIT_PATH: &str = "/vaults/:pool_vault_id/profit";
pub const VAULT_CASH_REBALANCES_PATH: &str = "/vaults/:pool_vault_id/cash-rebalances";
pub const VAULT_CASH_RECEIPTS_PATH: &str = "/vaults/:pool_vault_id/cash-receipts";
pub const MANAGER_STAKING_PATH: &str = "/managers/:predict_manager_id/staking";
pub const MANAGER_LP_REQUESTS_PATH: &str = "/managers/:predict_manager_id/lp-requests";
pub const BUILDER_CODE_FEES_PATH: &str = "/builder-codes/:builder_code_id/fees";
// Composed current-state lookups (top-1 index scans over raw tables).
pub const MARKET_STATE_PATH: &str = "/markets/:expiry_market_id/state";
pub const VAULT_STATE_PATH: &str = "/vaults/:pool_vault_id/state";
pub const MANAGER_STATE_PATH: &str = "/managers/:predict_manager_id/state";
pub const CONFIG_PATH: &str = "/config";
// order_state-backed position queries.
pub const MANAGER_POSITIONS_PATH: &str = "/managers/:predict_manager_id/positions";
pub const MARKET_OPEN_INTEREST_PATH: &str = "/markets/:expiry_market_id/open-interest";
// Materialized-view feeds.
pub const MARKET_ACTIVITY_PATH: &str = "/markets/:expiry_market_id/activity";
pub const MARKET_LIQUIDATION_STATS_PATH: &str = "/markets/:expiry_market_id/liquidation-stats";
pub const VAULT_FLOWS_PATH: &str = "/vaults/:pool_vault_id/flows";
// Market-scoped: packed order/root ids are expiry-local, never globally unique.
pub const POSITION_CASHFLOW_PATH: &str =
    "/markets/:expiry_market_id/positions/:position_root_id/cashflow";

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

pub fn make_router(state: Arc<AppState>) -> Router {
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
        .route(VAULT_SUPPLY_REQUESTS_PATH, get(vault_supply_requests))
        .route(VAULT_WITHDRAW_REQUESTS_PATH, get(vault_withdraw_requests))
        .route(VAULT_SUPPLY_FILLS_PATH, get(vault_supply_fills))
        .route(VAULT_WITHDRAW_FILLS_PATH, get(vault_withdraw_fills))
        .route(VAULT_FLUSHES_PATH, get(vault_flushes))
        .route(VAULT_PROFIT_PATH, get(vault_profit))
        .route(VAULT_CASH_REBALANCES_PATH, get(vault_cash_rebalances))
        .route(VAULT_CASH_RECEIPTS_PATH, get(vault_cash_receipts))
        .route(MANAGER_STAKING_PATH, get(manager_staking))
        .route(MANAGER_LP_REQUESTS_PATH, get(manager_lp_requests))
        .route(BUILDER_CODE_FEES_PATH, get(builder_code_fees))
        .route(MARKET_STATE_PATH, get(market_state))
        .route(VAULT_STATE_PATH, get(vault_state))
        .route(MANAGER_STATE_PATH, get(manager_state))
        .route(CONFIG_PATH, get(protocol_config))
        .route(MANAGER_POSITIONS_PATH, get(manager_positions))
        .route(MARKET_OPEN_INTEREST_PATH, get(market_open_interest))
        .route(MARKET_ACTIVITY_PATH, get(market_activity))
        .route(MARKET_LIQUIDATION_STATS_PATH, get(market_liquidation_stats))
        .route(VAULT_FLOWS_PATH, get(vault_flows))
        .route(POSITION_CASHFLOW_PATH, get(position_cashflow))
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

/// `supply_requested` feed for one vault.
async fn vault_supply_requests(
    Path(pool_vault_id): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<serde_json::Value>>, PredictError> {
    let data = state
        .reader
        .get_vault_supply_requests(
            pool_vault_id,
            params.start_time_ms(),
            params.end_time_ms(),
            params.limit(),
        )
        .await?;
    Ok(Json(data))
}

/// `withdraw_requested` feed for one vault.
async fn vault_withdraw_requests(
    Path(pool_vault_id): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<serde_json::Value>>, PredictError> {
    let data = state
        .reader
        .get_vault_withdraw_requests(
            pool_vault_id,
            params.start_time_ms(),
            params.end_time_ms(),
            params.limit(),
        )
        .await?;
    Ok(Json(data))
}

/// `supply_filled` feed for one vault.
async fn vault_supply_fills(
    Path(pool_vault_id): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<serde_json::Value>>, PredictError> {
    let data = state
        .reader
        .get_vault_supply_fills(
            pool_vault_id,
            params.start_time_ms(),
            params.end_time_ms(),
            params.limit(),
        )
        .await?;
    Ok(Json(data))
}

/// `withdraw_filled` feed for one vault.
async fn vault_withdraw_fills(
    Path(pool_vault_id): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<serde_json::Value>>, PredictError> {
    let data = state
        .reader
        .get_vault_withdraw_fills(
            pool_vault_id,
            params.start_time_ms(),
            params.end_time_ms(),
            params.limit(),
        )
        .await?;
    Ok(Json(data))
}

/// `flush_executed` feed for one vault.
async fn vault_flushes(
    Path(pool_vault_id): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<serde_json::Value>>, PredictError> {
    let data = state
        .reader
        .get_vault_flushes(
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

/// `lp_request_state` rows for one manager, windowed by `opened_at_ms`
/// (`?start_time`/`?end_time`, unix seconds). `?status` defaults to `open`.
async fn manager_lp_requests(
    Path(predict_manager_id): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<serde_json::Value>>, PredictError> {
    let status = params
        .get("status")
        .cloned()
        .unwrap_or_else(|| predict_schema::models::lp_request_status::OPEN.to_string());
    let data = state
        .reader
        .get_manager_lp_requests(
            predict_manager_id,
            status,
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

/// Composed current state for one market (creation, latest config snapshot,
/// mint-pause flag, terminal settlement).
async fn market_state(
    Path(expiry_market_id): Path<String>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<serde_json::Value>, PredictError> {
    Ok(Json(state.reader.get_market_state(expiry_market_id).await?))
}

/// Composed current state for one vault (current balances/supply plus the
/// latest event of each vault table).
async fn vault_state(
    Path(pool_vault_id): Path<String>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<serde_json::Value>, PredictError> {
    Ok(Json(state.reader.get_vault_state(pool_vault_id).await?))
}

/// Composed current state for one manager (creation row, latest builder code).
async fn manager_state(
    Path(predict_manager_id): Path<String>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<serde_json::Value>, PredictError> {
    Ok(Json(
        state.reader.get_manager_state(predict_manager_id).await?,
    ))
}

/// Latest value of every protocol-config event.
async fn protocol_config(
    State(state): State<Arc<AppState>>,
) -> Result<Json<serde_json::Value>, PredictError> {
    Ok(Json(state.reader.get_protocol_config().await?))
}

/// `order_state` rows for one manager, windowed by `opened_at_ms`
/// (`?start_time`/`?end_time`, unix seconds). `?status` defaults to `open`;
/// each row carries a `"root"` object with the root order's entry facts when
/// the row is a replacement.
async fn manager_positions(
    Path(predict_manager_id): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<serde_json::Value>>, PredictError> {
    let status = params
        .get("status")
        .cloned()
        .unwrap_or_else(|| predict_schema::models::order_status::OPEN.to_string());
    let data = state
        .reader
        .get_manager_positions(
            predict_manager_id,
            status,
            params.start_time_ms(),
            params.end_time_ms(),
            params.limit(),
        )
        .await?;
    Ok(Json(data))
}

/// Open-interest aggregate over `order_state` for one market.
async fn market_open_interest(
    Path(expiry_market_id): Path<String>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<serde_json::Value>, PredictError> {
    Ok(Json(
        state
            .reader
            .get_market_open_interest(expiry_market_id)
            .await?,
    ))
}

/// `market_activity_1h` buckets for one market.
async fn market_activity(
    Path(expiry_market_id): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<serde_json::Value>>, PredictError> {
    let data = state
        .reader
        .get_market_activity(
            expiry_market_id,
            params.start_time_ms(),
            params.end_time_ms(),
            params.limit(),
        )
        .await?;
    Ok(Json(data))
}

/// `liquidation_stats_1h` buckets for one market.
async fn market_liquidation_stats(
    Path(expiry_market_id): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<serde_json::Value>>, PredictError> {
    let data = state
        .reader
        .get_market_liquidation_stats(
            expiry_market_id,
            params.start_time_ms(),
            params.end_time_ms(),
            params.limit(),
        )
        .await?;
    Ok(Json(data))
}

/// `vault_flows_1h` buckets for one vault.
async fn vault_flows(
    Path(pool_vault_id): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<serde_json::Value>>, PredictError> {
    let data = state
        .reader
        .get_vault_flows(
            pool_vault_id,
            params.start_time_ms(),
            params.end_time_ms(),
            params.limit(),
        )
        .await?;
    Ok(Json(data))
}

/// `position_cashflow` lookup for one market-scoped position root (`null`
/// when unknown).
async fn position_cashflow(
    Path((expiry_market_id, position_root_id)): Path<(String, String)>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<serde_json::Value>, PredictError> {
    Ok(Json(
        state
            .reader
            .get_position_cashflow(expiry_market_id, position_root_id)
            .await?,
    ))
}
