// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use crate::error::OracleError;
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
// Oracle feeds keyed by propbook_oracle_id.
pub const ORACLE_PYTH_PATH: &str = "/oracles/:propbook_oracle_id/pyth";
pub const ORACLE_PYTH_LATEST_PATH: &str = "/oracles/:propbook_oracle_id/pyth/latest";
pub const ORACLE_BLOCK_SCHOLES_PATH: &str = "/oracles/:propbook_oracle_id/block-scholes";
pub const ORACLE_BLOCK_SCHOLES_SAMPLED_PATH: &str =
    "/oracles/:propbook_oracle_id/block-scholes/sampled";
// Registry feeds.
pub const ORACLE_SOURCES_PATH: &str = "/oracle-sources";
pub const ORACLE_BINDINGS_PATH: &str = "/oracle-bindings";
pub const UNDERLYING_BINDING_PATH: &str = "/underlyings/:propbook_underlying_id/binding";

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
    pub async fn sui_client(&self) -> Result<&sui_sdk::SuiClient, OracleError> {
        self.sui_client
            .get_or_try_init(|| async {
                SuiClientBuilder::default()
                    .build(self.rpc_url.as_str())
                    .await
            })
            .await
            .map_err(OracleError::from)
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
    let registry = Registry::new_custom(Some("oracle_api".into()), None)
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
        .route(ORACLE_PYTH_PATH, get(oracle_pyth))
        .route(ORACLE_PYTH_LATEST_PATH, get(oracle_pyth_latest))
        .route(ORACLE_BLOCK_SCHOLES_PATH, get(oracle_block_scholes))
        .route(
            ORACLE_BLOCK_SCHOLES_SAMPLED_PATH,
            get(oracle_block_scholes_sampled),
        )
        .route(ORACLE_SOURCES_PATH, get(oracle_sources))
        .route(ORACLE_BINDINGS_PATH, get(oracle_bindings))
        .route(UNDERLYING_BINDING_PATH, get(underlying_binding))
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
) -> Result<Json<serde_json::Value>, OracleError> {
    // Get watermarks from the database
    let watermarks = state.reader.get_watermarks().await?;

    // Get the latest checkpoint from Sui RPC
    let sui_client = state.sui_client().await?;
    let latest_checkpoint = sui_client
        .read_api()
        .get_latest_checkpoint_sequence_number()
        .await
        .map_err(|e| OracleError::rpc(format!("Failed to get latest checkpoint: {}", e)))?;

    // Get current timestamp
    let current_time_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| OracleError::internal("System time error"))?
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

/// Timestamp-window feed query params, mirroring the predict server's
/// `FeedParams` with sane limit defaults. `start_time` and `end_time` are parsed
/// as unix SECONDS and converted to milliseconds.
trait FeedParams {
    /// `?start_time` (unix seconds → ms), defaulting to 0 (no lower bound).
    fn start_time_ms(&self) -> i64;
    /// `?end_time` (unix seconds → ms), defaulting to now.
    fn end_time_ms(&self) -> i64;
    /// `?limit`, defaulting to `DEFAULT_LIMIT` and clamped to `[1, MAX_LIMIT]`.
    fn limit(&self) -> i64;
    /// `?is_exact` filter, when present and parseable as a bool.
    fn is_exact(&self) -> Option<bool>;
    /// `?expiry_ms` filter, when present and parseable.
    fn expiry_ms(&self) -> Option<i64>;
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

    fn is_exact(&self) -> Option<bool> {
        self.get("is_exact").and_then(|v| v.parse::<bool>().ok())
    }

    fn expiry_ms(&self) -> Option<i64> {
        self.get("expiry_ms").and_then(|v| v.parse::<i64>().ok())
    }
}

/// `pyth_observation` window for one oracle, newest-first. `?is_exact` filters
/// to the live (false) or exact-ms (true) lane.
async fn oracle_pyth(
    Path(propbook_oracle_id): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<serde_json::Value>>, OracleError> {
    let data = state
        .reader
        .get_oracle_pyth(
            propbook_oracle_id,
            params.is_exact(),
            params.start_time_ms(),
            params.end_time_ms(),
            params.limit(),
        )
        .await?;
    Ok(Json(data))
}

/// Latest live Pyth spot observation for one oracle.
async fn oracle_pyth_latest(
    Path(propbook_oracle_id): Path<String>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<serde_json::Value>, OracleError> {
    Ok(Json(
        state
            .reader
            .get_oracle_pyth_latest(propbook_oracle_id)
            .await?,
    ))
}

/// `block_scholes_observation` window for one oracle, newest-first. Optionally
/// filtered by `?expiry_ms` and/or `?is_exact`.
async fn oracle_block_scholes(
    Path(propbook_oracle_id): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<serde_json::Value>>, OracleError> {
    let data = state
        .reader
        .get_oracle_block_scholes(
            propbook_oracle_id,
            params.expiry_ms(),
            params.is_exact(),
            params.start_time_ms(),
            params.end_time_ms(),
            params.limit(),
        )
        .await?;
    Ok(Json(data))
}

/// `oracle_spot_1m` per-minute OHLC buckets for one oracle, newest bucket first.
async fn oracle_block_scholes_sampled(
    Path(propbook_oracle_id): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<serde_json::Value>>, OracleError> {
    let data = state
        .reader
        .get_oracle_block_scholes_sampled(
            propbook_oracle_id,
            params.start_time_ms(),
            params.end_time_ms(),
            params.limit(),
        )
        .await?;
    Ok(Json(data))
}

/// `oracle_source_registered` list, newest-first.
async fn oracle_sources(
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<serde_json::Value>>, OracleError> {
    let data = state
        .reader
        .get_oracle_sources(params.start_time_ms(), params.end_time_ms(), params.limit())
        .await?;
    Ok(Json(data))
}

/// `oracle_bound` list, newest-first. Optionally filtered by
/// `?propbook_underlying_id`.
async fn oracle_bindings(
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<serde_json::Value>>, OracleError> {
    let propbook_underlying_id = params
        .get("propbook_underlying_id")
        .and_then(|v| v.parse::<i64>().ok());
    let data = state
        .reader
        .get_oracle_bindings(
            propbook_underlying_id,
            params.start_time_ms(),
            params.end_time_ms(),
            params.limit(),
        )
        .await?;
    Ok(Json(data))
}

/// Current canonical binding for one underlying (`null` when unbound).
async fn underlying_binding(
    Path(propbook_underlying_id): Path<i64>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<serde_json::Value>, OracleError> {
    Ok(Json(
        state
            .reader
            .get_underlying_binding(propbook_underlying_id)
            .await?,
    ))
}
