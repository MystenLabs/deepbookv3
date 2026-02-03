// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use crate::error::DeepBookError;
use axum::http::Method;
use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    routing::get,
    Json, Router,
};
use deepbook_schema::models::{
    AssetSupplied, AssetWithdrawn, CollateralEvent, DeepbookPoolConfigUpdated,
    DeepbookPoolRegistered, DeepbookPoolUpdated, DeepbookPoolUpdatedRegistry,
    InterestParamsUpdated, Liquidation, LoanBorrowed, LoanRepaid, MaintainerCapUpdated,
    MaintainerFeesWithdrawn, MarginManagerCreated, MarginManagerState, MarginPoolConfigUpdated,
    MarginPoolCreated, PauseCapUpdated, Pools, ProtocolFeesIncreasedEvent, ProtocolFeesWithdrawn,
    ReferralFeeEvent, ReferralFeesClaimedEvent, SupplierCapMinted, SupplyReferralMinted,
};
use deepbook_schema::*;
use diesel::dsl::count_star;
use diesel::dsl::{max, min};
use diesel::{ExpressionMethods, QueryDsl};
use governor::{Quota, RateLimiter};
use secrecy::{ExposeSecret, Secret};
use serde::Deserialize;
use serde_json::Value;
use std::net::{IpAddr, Ipv4Addr};
use std::num::NonZeroU32;
use std::time::{SystemTime, UNIX_EPOCH};
use std::{collections::HashMap, net::SocketAddr};
use sui_pg_db::DbArgs;
use tokio::net::TcpListener;
use tokio::sync::oneshot;
use tokio::sync::OnceCell;
use tower_http::cors::{AllowMethods, Any, CorsLayer};
use url::Url;

use crate::admin::routes::admin_routes;
use crate::metrics::middleware::track_metrics;
use crate::metrics::RpcMetrics;
use crate::reader::Reader;
use crate::writer::Writer;
use axum::middleware::from_fn_with_state;
use futures::future::join_all;
use prometheus::Registry;
use std::str::FromStr;
use std::sync::Arc;
use sui_futures::service::Service;
use sui_indexer_alt_metrics::{MetricsArgs, MetricsService};
use sui_json_rpc_types::{SuiObjectData, SuiObjectDataOptions, SuiObjectResponse};
use sui_sdk::SuiClientBuilder;
use sui_types::{
    base_types::{ObjectID, SuiAddress},
    programmable_transaction_builder::ProgrammableTransactionBuilder,
    transaction::{Argument, CallArg, Command, ObjectArg, ProgrammableMoveCall, TransactionKind},
    type_input::TypeInput,
    TypeTag,
};
use tokio::join;

pub const GET_POOLS_PATH: &str = "/get_pools";
pub const GET_HISTORICAL_VOLUME_BY_BALANCE_MANAGER_ID_WITH_INTERVAL: &str =
    "/historical_volume_by_balance_manager_id_with_interval/:pool_names/:balance_manager_id";
pub const GET_HISTORICAL_VOLUME_BY_BALANCE_MANAGER_ID: &str =
    "/historical_volume_by_balance_manager_id/:pool_names/:balance_manager_id";
pub const HISTORICAL_VOLUME_PATH: &str = "/historical_volume/:pool_names";
pub const ALL_HISTORICAL_VOLUME_PATH: &str = "/all_historical_volume";
pub const GET_NET_DEPOSITS: &str = "/get_net_deposits/:asset_ids/:timestamp";
pub const TICKER_PATH: &str = "/ticker";
pub const TRADES_PATH: &str = "/trades/:pool_name";
pub const ORDER_UPDATES_PATH: &str = "/order_updates/:pool_name";
pub const ORDERS_PATH: &str = "/orders/:pool_name/:balance_manager_id";
pub const TRADE_COUNT_PATH: &str = "/trade_count";
pub const ASSETS_PATH: &str = "/assets";
pub const SUMMARY_PATH: &str = "/summary";
pub const LEVEL2_PATH: &str = "/orderbook/:pool_name";
pub const LEVEL2_MODULE: &str = "pool";
pub const LEVEL2_FUNCTION: &str = "get_level2_ticks_from_mid";
pub const DEEP_SUPPLY_MODULE: &str = "deep";
pub const DEEP_SUPPLY_FUNCTION: &str = "total_supply";
pub const DEEP_SUPPLY_PATH: &str = "/deep_supply";
pub const MARGIN_SUPPLY_PATH: &str = "/margin_supply";
pub const MARGIN_POOL_MODULE: &str = "margin_pool";
pub const OHCLV_PATH: &str = "/ohclv/:pool_name";

// Deepbook Margin Events
pub const MARGIN_MANAGER_CREATED_PATH: &str = "/margin_manager_created";
pub const LOAN_BORROWED_PATH: &str = "/loan_borrowed";
pub const LOAN_REPAID_PATH: &str = "/loan_repaid";
pub const LIQUIDATION_PATH: &str = "/liquidation";
pub const ASSET_SUPPLIED_PATH: &str = "/asset_supplied";
pub const ASSET_WITHDRAWN_PATH: &str = "/asset_withdrawn";
pub const MARGIN_POOL_CREATED_PATH: &str = "/margin_pool_created";
pub const DEEPBOOK_POOL_UPDATED_PATH: &str = "/deepbook_pool_updated";
pub const INTEREST_PARAMS_UPDATED_PATH: &str = "/interest_params_updated";
pub const MARGIN_POOL_CONFIG_UPDATED_PATH: &str = "/margin_pool_config_updated";
pub const MAINTAINER_CAP_UPDATED_PATH: &str = "/maintainer_cap_updated";
pub const MAINTAINER_FEES_WITHDRAWN_PATH: &str = "/maintainer_fees_withdrawn";
pub const PROTOCOL_FEES_WITHDRAWN_PATH: &str = "/protocol_fees_withdrawn";
pub const SUPPLIER_CAP_MINTED_PATH: &str = "/supplier_cap_minted";
pub const SUPPLY_REFERRAL_MINTED_PATH: &str = "/supply_referral_minted";
pub const PAUSE_CAP_UPDATED_PATH: &str = "/pause_cap_updated";
pub const PROTOCOL_FEES_INCREASED_PATH: &str = "/protocol_fees_increased";
pub const REFERRAL_FEES_CLAIMED_PATH: &str = "/referral_fees_claimed";
pub const REFERRAL_FEE_EVENTS_PATH: &str = "/referral_fee_events";
pub const DEEPBOOK_POOL_REGISTERED_PATH: &str = "/deepbook_pool_registered";
pub const DEEPBOOK_POOL_UPDATED_REGISTRY_PATH: &str = "/deepbook_pool_updated_registry";
pub const DEEPBOOK_POOL_CONFIG_UPDATED_PATH: &str = "/deepbook_pool_config_updated";
pub const MARGIN_MANAGERS_INFO_PATH: &str = "/margin_managers_info";
pub const MARGIN_MANAGER_STATES_PATH: &str = "/margin_manager_states";
pub const STATUS_PATH: &str = "/status";
pub const DEPOSITED_ASSETS_PATH: &str = "/deposited_assets/:balance_manager_ids";
pub const COLLATERAL_EVENTS_PATH: &str = "/collateral_events";
pub const GET_POINTS_PATH: &str = "/get_points";

type AdminRateLimiter = RateLimiter<
    governor::state::NotKeyed,
    governor::state::InMemoryState,
    governor::clock::DefaultClock,
>;

#[derive(Clone)]
pub struct AppState {
    reader: Reader,
    writer: Writer,
    metrics: Arc<RpcMetrics>,
    rpc_url: Url,
    sui_client: Arc<OnceCell<sui_sdk::SuiClient>>,
    deepbook_package_id: String,
    deep_token_package_id: String,
    deep_treasury_id: String,
    admin_tokens: Vec<Secret<String>>,
    admin_auth_limiter: Arc<AdminRateLimiter>,
    margin_package_id: Option<String>,
}

impl AppState {
    pub async fn new(
        database_url: Url,
        args: DbArgs,
        registry: &Registry,
        rpc_url: Url,
        deepbook_package_id: String,
        deep_token_package_id: String,
        deep_treasury_id: String,
        admin_tokens: Option<String>,
        margin_package_id: Option<String>,
    ) -> Result<Self, anyhow::Error> {
        let metrics = RpcMetrics::new(registry);
        let reader = Reader::new(
            database_url.clone(),
            args.clone(),
            metrics.clone(),
            registry,
        )
        .await?;
        let writer = Writer::new(database_url, args).await?;

        let admin_tokens: Vec<Secret<String>> = admin_tokens
            .map(|s| {
                s.split(',')
                    .map(|t| t.trim().to_string())
                    .filter(|t| !t.is_empty())
                    .map(Secret::new)
                    .collect()
            })
            .unwrap_or_default();

        if admin_tokens.is_empty() {
            tracing::warn!(
                "No admin tokens configured (ADMIN_TOKENS env var). Admin endpoints will reject all requests."
            );
        }

        // Rate limiter: 10 attempts per minute for admin auth failures
        let admin_auth_limiter = Arc::new(RateLimiter::direct(Quota::per_minute(
            NonZeroU32::new(10).unwrap(),
        )));

        Ok(Self {
            reader,
            writer,
            metrics,
            rpc_url,
            sui_client: Arc::new(OnceCell::new()),
            deepbook_package_id,
            deep_token_package_id,
            deep_treasury_id,
            admin_tokens,
            admin_auth_limiter,
            margin_package_id,
        })
    }

    /// Returns a reference to the shared SuiClient instance.
    /// Lazily initializes the client on first access and caches it for subsequent calls
    pub async fn sui_client(&self) -> Result<&sui_sdk::SuiClient, DeepBookError> {
        self.sui_client
            .get_or_try_init(|| async {
                SuiClientBuilder::default()
                    .build(self.rpc_url.as_str())
                    .await
            })
            .await
            .map_err(DeepBookError::from)
    }
    pub(crate) fn metrics(&self) -> &RpcMetrics {
        &self.metrics
    }

    pub fn writer(&self) -> &Writer {
        &self.writer
    }

    pub fn is_valid_admin_token(&self, token: &str) -> bool {
        use subtle::ConstantTimeEq;
        self.admin_tokens
            .iter()
            .any(|t| t.expose_secret().as_bytes().ct_eq(token.as_bytes()).into())
    }

    pub fn check_admin_rate_limit(&self) -> bool {
        self.admin_auth_limiter.check().is_ok()
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
    deepbook_package_id: String,
    deep_token_package_id: String,
    deep_treasury_id: String,
    margin_poll_interval_secs: u64,
    margin_package_id: Option<String>,
    admin_tokens: Option<String>,
) -> Result<(), anyhow::Error> {
    let registry = Registry::new_custom(Some("deepbook_api".into()), None)
        .expect("Failed to create Prometheus registry.");

    let metrics = MetricsService::new(MetricsArgs { metrics_address }, registry);

    let state = AppState::new(
        database_url.clone(),
        db_arg.clone(),
        metrics.registry(),
        rpc_url.clone(),
        deepbook_package_id,
        deep_token_package_id,
        deep_treasury_id,
        admin_tokens,
        margin_package_id.clone(),
    )
    .await?;
    let socket_address = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(0, 0, 0, 0)), server_port);

    println!("Server started successfully on port {}", server_port);

    // Start margin metrics poller if margin_package_id is provided
    // Must be done before spawning the metrics service since we need access to the registry
    if let Some(margin_pkg_id) = margin_package_id {
        let cancellation_token = tokio_util::sync::CancellationToken::new();
        let margin_metrics = crate::margin_metrics::MarginMetrics::new(metrics.registry());
        let margin_db = sui_pg_db::Db::for_read(database_url, db_arg).await?;
        let margin_poller = crate::margin_metrics::MarginPoller::new(
            margin_db,
            rpc_url.clone(),
            margin_pkg_id,
            margin_metrics,
            margin_poll_interval_secs,
            cancellation_token,
        );
        tokio::spawn(async move {
            if let Err(e) = margin_poller.run().await {
                eprintln!("[margin_poller] Margin poller failed: {}", e);
            }
        });
        println!(
            "Margin metrics poller started (interval: {}s)",
            margin_poll_interval_secs
        );
    }

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

    let db_routes = Router::new()
        .route("/", get(health_check))
        .route(GET_POOLS_PATH, get(get_pools))
        .route(HISTORICAL_VOLUME_PATH, get(historical_volume))
        .route(ALL_HISTORICAL_VOLUME_PATH, get(all_historical_volume))
        .route(
            GET_HISTORICAL_VOLUME_BY_BALANCE_MANAGER_ID_WITH_INTERVAL,
            get(get_historical_volume_by_balance_manager_id_with_interval),
        )
        .route(
            GET_HISTORICAL_VOLUME_BY_BALANCE_MANAGER_ID,
            get(get_historical_volume_by_balance_manager_id),
        )
        .route(GET_NET_DEPOSITS, get(get_net_deposits))
        .route(TICKER_PATH, get(ticker))
        .route(TRADES_PATH, get(trades))
        .route(TRADE_COUNT_PATH, get(trade_count))
        .route(ORDER_UPDATES_PATH, get(order_updates))
        .route(ORDERS_PATH, get(orders))
        .route(ASSETS_PATH, get(assets))
        .route(OHCLV_PATH, get(ohclv))
        // Deepbook Margin Events
        .route(MARGIN_MANAGER_CREATED_PATH, get(margin_manager_created))
        .route(LOAN_BORROWED_PATH, get(loan_borrowed))
        .route(LOAN_REPAID_PATH, get(loan_repaid))
        .route(LIQUIDATION_PATH, get(liquidation))
        .route(ASSET_SUPPLIED_PATH, get(asset_supplied))
        .route(ASSET_WITHDRAWN_PATH, get(asset_withdrawn))
        .route(MARGIN_POOL_CREATED_PATH, get(margin_pool_created))
        .route(DEEPBOOK_POOL_UPDATED_PATH, get(deepbook_pool_updated))
        .route(INTEREST_PARAMS_UPDATED_PATH, get(interest_params_updated))
        .route(
            MARGIN_POOL_CONFIG_UPDATED_PATH,
            get(margin_pool_config_updated),
        )
        .route(MAINTAINER_CAP_UPDATED_PATH, get(maintainer_cap_updated))
        .route(
            MAINTAINER_FEES_WITHDRAWN_PATH,
            get(maintainer_fees_withdrawn),
        )
        .route(PROTOCOL_FEES_WITHDRAWN_PATH, get(protocol_fees_withdrawn))
        .route(SUPPLIER_CAP_MINTED_PATH, get(supplier_cap_minted))
        .route(SUPPLY_REFERRAL_MINTED_PATH, get(supply_referral_minted))
        .route(PAUSE_CAP_UPDATED_PATH, get(pause_cap_updated))
        .route(PROTOCOL_FEES_INCREASED_PATH, get(protocol_fees_increased))
        .route(REFERRAL_FEES_CLAIMED_PATH, get(referral_fees_claimed))
        .route(REFERRAL_FEE_EVENTS_PATH, get(referral_fee_events))
        .route(DEEPBOOK_POOL_REGISTERED_PATH, get(deepbook_pool_registered))
        .route(
            DEEPBOOK_POOL_UPDATED_REGISTRY_PATH,
            get(deepbook_pool_updated_registry),
        )
        .route(
            DEEPBOOK_POOL_CONFIG_UPDATED_PATH,
            get(deepbook_pool_config_updated),
        )
        .route(MARGIN_MANAGERS_INFO_PATH, get(margin_managers_info))
        .route(MARGIN_MANAGER_STATES_PATH, get(margin_manager_states))
        .route(DEPOSITED_ASSETS_PATH, get(deposited_assets))
        .route(COLLATERAL_EVENTS_PATH, get(collateral_events))
        .route(GET_POINTS_PATH, get(get_points))
        .with_state(state.clone());

    let rpc_routes = Router::new()
        .route(LEVEL2_PATH, get(orderbook))
        .route(DEEP_SUPPLY_PATH, get(deep_supply))
        .route(MARGIN_SUPPLY_PATH, get(margin_supply))
        .route(SUMMARY_PATH, get(summary))
        .route(STATUS_PATH, get(status))
        .with_state(state.clone());

    let admin = admin_routes(state.clone()).with_state(state.clone());

    db_routes
        .merge(rpc_routes)
        .nest("/admin", admin)
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
) -> Result<Json<serde_json::Value>, DeepBookError> {
    // Get watermarks from the database
    let watermarks = state.reader.get_watermarks().await?;

    // Get the latest checkpoint from Sui RPC
    let sui_client = state.sui_client().await?;
    let latest_checkpoint = sui_client
        .read_api()
        .get_latest_checkpoint_sequence_number()
        .await
        .map_err(|e| DeepBookError::rpc(format!("Failed to get latest checkpoint: {}", e)))?;

    // Get current timestamp
    let current_time_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| DeepBookError::internal("System time error"))?
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

        // Track the earliest checkpoint and pipeline with max lag
        if checkpoint_hi < min_checkpoint {
            min_checkpoint = checkpoint_hi;
        }
        if checkpoint_lag > max_checkpoint_lag {
            max_checkpoint_lag = checkpoint_lag;
            max_lag_pipeline_name = pipeline.clone();
        }

        pipelines.push(serde_json::json!({
            "pipeline": pipeline,
            "indexed_checkpoint": checkpoint_hi,
            "indexed_epoch": epoch_hi,
            "indexed_timestamp_ms": timestamp_ms_hi,
            "checkpoint_lag": checkpoint_lag,
            "time_lag_seconds": time_lag_seconds,
            "latest_onchain_checkpoint": latest_checkpoint,
        }));
    }

    let max_time_lag_seconds = pipelines
        .iter()
        .filter_map(|p| p["time_lag_seconds"].as_i64())
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

/// Get all pools stored in database
async fn get_pools(State(state): State<Arc<AppState>>) -> Result<Json<Vec<Pools>>, DeepBookError> {
    Ok(Json(state.reader.get_pools().await?))
}

async fn historical_volume(
    Path(pool_names): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<HashMap<String, u64>>, DeepBookError> {
    // Fetch all pools to map names to IDs
    let pools = state.reader.get_pools().await?;
    let pool_name_to_id = pools
        .into_iter()
        .map(|pool| (pool.pool_name, pool.pool_id))
        .collect::<HashMap<_, _>>();

    // Map provided pool names to pool IDs
    let pool_ids: Vec<String> = pool_names
        .split(',')
        .filter_map(|name| pool_name_to_id.get(name).cloned())
        .collect();

    if pool_ids.is_empty() {
        return Err(DeepBookError::bad_request("No valid pool names provided"));
    }

    // Parse start_time and end_time from query parameters (in seconds) and convert to milliseconds
    let end_time = params.end_time();
    let start_time = params
        .start_time() // Convert to milliseconds
        .unwrap_or_else(|| end_time - 24 * 60 * 60 * 1000);

    // Determine whether to query volume in base or quote
    let volume_in_base = params.volume_in_base();

    // Query the database for the historical volume
    let results = state
        .reader
        .get_historical_volume(start_time, end_time, &pool_ids, volume_in_base)
        .await?;

    // Aggregate volume by pool ID and map back to pool names
    let mut volume_by_pool = HashMap::new();
    for (pool_id, volume) in results {
        if let Some(pool_name) = pool_name_to_id
            .iter()
            .find(|(_, id)| **id == pool_id)
            .map(|(name, _)| name)
        {
            *volume_by_pool.entry(pool_name.clone()).or_insert(0) += volume as u64;
        }
    }

    Ok(Json(volume_by_pool))
}

/// Get all historical volume for all pools
async fn all_historical_volume(
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<HashMap<String, u64>>, DeepBookError> {
    let pools = state.reader.get_pools().await?;

    let pool_names: String = pools
        .into_iter()
        .map(|pool| pool.pool_name)
        .collect::<Vec<String>>()
        .join(",");

    historical_volume(Path(pool_names), Query(params), State(state)).await
}

async fn get_historical_volume_by_balance_manager_id(
    Path((pool_names, balance_manager_id)): Path<(String, String)>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<HashMap<String, Vec<i64>>>, DeepBookError> {
    let pools = state.reader.get_pools().await?;
    let pool_name_to_id = pools
        .into_iter()
        .map(|pool| (pool.pool_name, pool.pool_id))
        .collect::<HashMap<_, _>>();

    let pool_ids: Vec<String> = pool_names
        .split(',')
        .filter_map(|name| pool_name_to_id.get(name).cloned())
        .collect();

    if pool_ids.is_empty() {
        return Err(DeepBookError::bad_request("No valid pool names provided"));
    }

    // Parse start_time and end_time
    let end_time = params.end_time();
    let start_time = params
        .start_time() // Convert to milliseconds
        .unwrap_or_else(|| end_time - 24 * 60 * 60 * 1000);

    let volume_in_base = params.volume_in_base();

    let results = state
        .reader
        .get_order_fill_summary(
            start_time,
            end_time,
            &pool_ids,
            &balance_manager_id,
            volume_in_base,
        )
        .await?;

    let mut volume_by_pool: HashMap<String, Vec<i64>> = HashMap::new();
    for order_fill in results {
        if let Some(pool_name) = pool_name_to_id
            .iter()
            .find(|(_, id)| **id == order_fill.pool_id)
            .map(|(name, _)| name)
        {
            let entry = volume_by_pool
                .entry(pool_name.clone())
                .or_insert(vec![0, 0]);
            if order_fill.maker_balance_manager_id == balance_manager_id {
                entry[0] += order_fill.quantity;
            }
            if order_fill.taker_balance_manager_id == balance_manager_id {
                entry[1] += order_fill.quantity;
            }
        }
    }

    Ok(Json(volume_by_pool))
}

async fn get_historical_volume_by_balance_manager_id_with_interval(
    Path((pool_names, balance_manager_id)): Path<(String, String)>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<HashMap<String, HashMap<String, Vec<i64>>>>, DeepBookError> {
    let pools = state.reader.get_pools().await?;
    let pool_name_to_id: HashMap<String, String> = pools
        .into_iter()
        .map(|pool| (pool.pool_name, pool.pool_id))
        .collect();

    let pool_ids = pool_names
        .split(',')
        .filter_map(|name| pool_name_to_id.get(name).cloned())
        .collect::<Vec<_>>();

    if pool_ids.is_empty() {
        return Err(DeepBookError::bad_request("No valid pool names provided"));
    }

    // Parse interval
    let interval = params
        .get("interval")
        .and_then(|v| v.parse::<i64>().ok())
        .unwrap_or(3600); // Default interval: 1 hour

    if interval <= 0 {
        return Err(DeepBookError::bad_request(
            "Interval must be greater than 0",
        ));
    }

    let interval_ms = interval * 1000;
    // Parse start_time and end_time
    let end_time = params.end_time();

    let start_time = params
        .start_time() // Convert to milliseconds
        .unwrap_or_else(|| end_time - 24 * 60 * 60 * 1000);

    let mut metrics_by_interval: HashMap<String, HashMap<String, Vec<i64>>> = HashMap::new();

    let mut current_start = start_time;
    while current_start + interval_ms <= end_time {
        let current_end = current_start + interval_ms;

        let volume_in_base = params.volume_in_base();

        let results = state
            .reader
            .get_order_fill_summary(
                start_time,
                end_time,
                &pool_ids,
                &balance_manager_id,
                volume_in_base,
            )
            .await?;

        let mut volume_by_pool: HashMap<String, Vec<i64>> = HashMap::new();
        for order_fill in results {
            if let Some(pool_name) = pool_name_to_id
                .iter()
                .find(|(_, id)| **id == order_fill.pool_id)
                .map(|(name, _)| name)
            {
                let entry = volume_by_pool
                    .entry(pool_name.clone())
                    .or_insert(vec![0, 0]);
                if order_fill.maker_balance_manager_id == balance_manager_id {
                    entry[0] += order_fill.quantity;
                }
                if order_fill.taker_balance_manager_id == balance_manager_id {
                    entry[1] += order_fill.quantity;
                }
            }
        }

        metrics_by_interval.insert(
            format!("[{}, {}]", current_start / 1000, current_end / 1000),
            volume_by_pool,
        );

        current_start = current_end;
    }

    Ok(Json(metrics_by_interval))
}

async fn ticker(
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<HashMap<String, HashMap<String, Value>>>, DeepBookError> {
    // Fetch base and quote historical volumes
    let base_volumes = fetch_historical_volume(&params, true, &state).await?;
    let quote_volumes = fetch_historical_volume(&params, false, &state).await?;

    // Fetch pools data for metadata
    let pools = state.reader.get_pools().await?;
    let pool_map: HashMap<String, &Pools> = pools
        .iter()
        .map(|pool| (pool.pool_id.clone(), pool))
        .collect();

    let end_time = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| DeepBookError::internal("System time error"))?
        .as_millis() as i64;

    // Calculate the start time for 24 hours ago
    let start_time = end_time - (24 * 60 * 60 * 1000);

    // Fetch last prices for all pools in a single query. Only trades in the last 24 hours will count.
    let query = schema::order_fills::table
        .filter(schema::order_fills::checkpoint_timestamp_ms.between(start_time, end_time))
        .select((schema::order_fills::pool_id, schema::order_fills::price))
        .order_by((
            schema::order_fills::pool_id.asc(),
            schema::order_fills::checkpoint_timestamp_ms.desc(),
        ))
        .distinct_on(schema::order_fills::pool_id);

    let last_prices: Vec<(String, i64)> = state.reader.results(query).await?;
    let last_price_map: HashMap<String, i64> = last_prices.into_iter().collect();

    let mut response = HashMap::new();

    for (pool_id, pool) in &pool_map {
        let pool_name = &pool.pool_name;
        let base_volume = base_volumes.get(pool_name).copied().unwrap_or(0);
        let quote_volume = quote_volumes.get(pool_name).copied().unwrap_or(0);
        let last_price = last_price_map.get(pool_id).copied();

        // Conversion factors based on decimals
        let base_factor = 10u64.pow(pool.base_asset_decimals as u32);
        let quote_factor = 10u64.pow(pool.quote_asset_decimals as u32);
        let price_factor =
            10u64.pow((9 - pool.base_asset_decimals + pool.quote_asset_decimals) as u32);

        response.insert(
            pool_name.clone(),
            HashMap::from([
                (
                    "last_price".to_string(),
                    Value::from(
                        last_price
                            .map(|price| price as f64 / price_factor as f64)
                            .unwrap_or(0.0),
                    ),
                ),
                (
                    "base_volume".to_string(),
                    Value::from(base_volume as f64 / base_factor as f64),
                ),
                (
                    "quote_volume".to_string(),
                    Value::from(quote_volume as f64 / quote_factor as f64),
                ),
                ("isFrozen".to_string(), Value::from(0)), // Fixed to 0 because all pools in pools table are active
            ]),
        );
    }

    Ok(Json(response))
}

async fn fetch_historical_volume(
    params: &HashMap<String, String>,
    volume_in_base: bool,
    state: &Arc<AppState>,
) -> Result<HashMap<String, u64>, DeepBookError> {
    let mut params_with_volume = params.clone();
    params_with_volume.insert("volume_in_base".to_string(), volume_in_base.to_string());

    all_historical_volume(Query(params_with_volume), State(state.clone()))
        .await
        .map(|Json(volumes)| volumes)
}

#[allow(clippy::get_first)]
async fn summary(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<HashMap<String, Value>>>, DeepBookError> {
    // Fetch pools metadata first since it's required for other functions
    let pools = state.reader.get_pools().await?;
    let pool_metadata: HashMap<String, (String, (i16, i16))> = pools
        .iter()
        .map(|pool| {
            (
                pool.pool_name.clone(),
                (
                    pool.pool_id.clone(),
                    (pool.base_asset_decimals, pool.quote_asset_decimals),
                ),
            )
        })
        .collect();

    // Prepare pool decimals for scaling
    let pool_decimals: HashMap<String, (i16, i16)> = pool_metadata
        .iter()
        .map(|(_, (pool_id, decimals))| (pool_id.clone(), *decimals))
        .collect();

    // Parallelize fetching ticker, price changes, and high/low prices
    let (ticker_result, price_change_result, high_low_result) = join!(
        ticker(Query(HashMap::new()), State(state.clone())),
        price_change_24h(&pool_metadata, State(state.clone())),
        high_low_prices_24h(&pool_decimals, State(state.clone()))
    );

    let Json(ticker_map) = ticker_result?;
    let price_change_map = price_change_result?;
    let high_low_map = high_low_result?;

    // Prepare futures for orderbook queries
    let orderbook_futures: Vec<_> = ticker_map
        .keys()
        .map(|pool_name| {
            let pool_name_clone = pool_name.clone();
            orderbook(
                Path(pool_name_clone),
                Query(HashMap::from([("level".to_string(), "1".to_string())])),
                State(state.clone()),
            )
        })
        .collect();

    // Run all orderbook queries concurrently
    let orderbook_results = join_all(orderbook_futures).await;

    let mut response = Vec::new();

    for ((pool_name, ticker_info), orderbook_result) in ticker_map.iter().zip(orderbook_results) {
        if let Some((pool_id, _)) = pool_metadata.get(pool_name) {
            // Extract data from the ticker function response
            let last_price = ticker_info
                .get("last_price")
                .and_then(|price| price.as_f64())
                .unwrap_or(0.0);

            let base_volume = ticker_info
                .get("base_volume")
                .and_then(|volume| volume.as_f64())
                .unwrap_or(0.0);

            let quote_volume = ticker_info
                .get("quote_volume")
                .and_then(|volume| volume.as_f64())
                .unwrap_or(0.0);

            // Fetch the 24-hour price change percent
            let price_change_percent = price_change_map.get(pool_name).copied().unwrap_or(0.0);

            // Fetch the highest and lowest prices in the last 24 hours
            let (highest_price, lowest_price) =
                high_low_map.get(pool_id).copied().unwrap_or((0.0, 0.0));

            // Process the parallel orderbook result
            let orderbook_data = orderbook_result.ok().map(|Json(data)| data);

            let highest_bid = orderbook_data
                .as_ref()
                .and_then(|data| data.get("bids"))
                .and_then(|bids| bids.as_array())
                .and_then(|bids| bids.get(0))
                .and_then(|bid| bid.as_array())
                .and_then(|bid| bid.get(0))
                .and_then(|price| price.as_str()?.parse::<f64>().ok())
                .unwrap_or(0.0);

            let lowest_ask = orderbook_data
                .as_ref()
                .and_then(|data| data.get("asks"))
                .and_then(|asks| asks.as_array())
                .and_then(|asks| asks.get(0))
                .and_then(|ask| ask.as_array())
                .and_then(|ask| ask.get(0))
                .and_then(|price| price.as_str()?.parse::<f64>().ok())
                .unwrap_or(0.0);

            let mut summary_data = HashMap::new();
            summary_data.insert(
                "trading_pairs".to_string(),
                Value::String(pool_name.clone()),
            );
            let parts: Vec<&str> = pool_name.split('_').collect();
            let base_currency = parts.get(0).unwrap_or(&"Unknown").to_string();
            let quote_currency = parts.get(1).unwrap_or(&"Unknown").to_string();

            summary_data.insert("base_currency".to_string(), Value::String(base_currency));
            summary_data.insert("quote_currency".to_string(), Value::String(quote_currency));
            summary_data.insert("last_price".to_string(), Value::from(last_price));
            summary_data.insert("base_volume".to_string(), Value::from(base_volume));
            summary_data.insert("quote_volume".to_string(), Value::from(quote_volume));
            summary_data.insert(
                "price_change_percent_24h".to_string(),
                Value::from(price_change_percent),
            );
            summary_data.insert("highest_price_24h".to_string(), Value::from(highest_price));
            summary_data.insert("lowest_price_24h".to_string(), Value::from(lowest_price));
            summary_data.insert("highest_bid".to_string(), Value::from(highest_bid));
            summary_data.insert("lowest_ask".to_string(), Value::from(lowest_ask));

            response.push(summary_data);
        }
    }

    Ok(Json(response))
}

async fn high_low_prices_24h(
    pool_decimals: &HashMap<String, (i16, i16)>,
    State(state): State<Arc<AppState>>,
) -> Result<HashMap<String, (f64, f64)>, DeepBookError> {
    // Get the current timestamp in milliseconds
    let end_time = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| DeepBookError::internal("System time error"))?
        .as_millis() as i64;

    // Calculate the start time for 24 hours ago
    let start_time = end_time - (24 * 60 * 60 * 1000);

    // Query for trades within the last 24 hours for all pools
    let query = schema::order_fills::table
        .filter(schema::order_fills::checkpoint_timestamp_ms.between(start_time, end_time))
        .group_by(schema::order_fills::pool_id)
        .select((
            schema::order_fills::pool_id,
            max(schema::order_fills::price),
            min(schema::order_fills::price),
        ));
    let results: Vec<(String, Option<i64>, Option<i64>)> = state.reader.results(query).await?;

    // Aggregate the highest and lowest prices for each pool
    let mut price_map: HashMap<String, (f64, f64)> = HashMap::new();

    for (pool_id, max_price_opt, min_price_opt) in results {
        if let Some((base_decimals, quote_decimals)) = pool_decimals.get(&pool_id) {
            let scaling_factor = 10f64.powi((9 - base_decimals + quote_decimals) as i32);

            let max_price_f64 = max_price_opt.unwrap_or(0) as f64 / scaling_factor;
            let min_price_f64 = min_price_opt.unwrap_or(0) as f64 / scaling_factor;

            price_map.insert(pool_id, (max_price_f64, min_price_f64));
        }
    }

    Ok(price_map)
}

async fn price_change_24h(
    pool_metadata: &HashMap<String, (String, (i16, i16))>,
    State(state): State<Arc<AppState>>,
) -> Result<HashMap<String, f64>, DeepBookError> {
    // Calculate the timestamp for 24 hours ago
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| DeepBookError::internal("System time error"))?
        .as_millis() as i64;

    let timestamp_24h_ago = now - (24 * 60 * 60 * 1000); // 24 hours in milliseconds
    let timestamp_48h_ago = now - (48 * 60 * 60 * 1000); // 48 hours in milliseconds

    let mut response = HashMap::new();

    for (pool_name, (pool_id, (base_decimals, quote_decimals))) in pool_metadata.iter() {
        // Get the latest price <= 24 hours ago. Only trades until 48 hours ago will count.
        let earliest_trade_24h = state
            .reader
            .get_price(timestamp_48h_ago, timestamp_24h_ago, pool_id)
            .await;
        // Get the most recent price. Only trades until 24 hours ago will count.
        let most_recent_trade = state
            .reader
            .get_price(timestamp_24h_ago, now, pool_id)
            .await;

        if let (Ok(earliest_price), Ok(most_recent_price)) = (earliest_trade_24h, most_recent_trade)
        {
            let price_factor = 10u64.pow((9 - base_decimals + quote_decimals) as u32);

            // Scale the prices
            let earliest_price_scaled = earliest_price as f64 / price_factor as f64;
            let most_recent_price_scaled = most_recent_price as f64 / price_factor as f64;

            // Calculate price change percentage
            let price_change_percent =
                ((most_recent_price_scaled / earliest_price_scaled) - 1.0) * 100.0;

            response.insert(pool_name.clone(), price_change_percent);
        } else {
            // If there's no price data for 24 hours or recent trades, insert 0.0 as price change
            response.insert(pool_name.clone(), 0.0);
        }
    }

    Ok(response)
}

async fn order_updates(
    Path(pool_name): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<HashMap<String, Value>>>, DeepBookError> {
    // Fetch pool data with proper error handling
    let (pool_id, base_decimals, quote_decimals) =
        state.reader.get_pool_decimals(&pool_name).await?;
    let base_decimals = base_decimals as u8;
    let quote_decimals = quote_decimals as u8;

    let end_time = params.end_time();

    let start_time = params
        .start_time() // Convert to milliseconds
        .unwrap_or_else(|| end_time - 24 * 60 * 60 * 1000);

    let limit = params.limit();

    let balance_manager_filter = params.get("balance_manager_id").cloned();
    let status_filter = params.get("status").cloned();

    let trades = state
        .reader
        .get_order_updates(
            pool_id,
            start_time,
            end_time,
            limit,
            balance_manager_filter,
            status_filter,
        )
        .await?;

    let base_factor = 10u64.pow(base_decimals as u32);
    let price_factor = 10u64.pow((9 - base_decimals + quote_decimals) as u32);

    let trade_data: Vec<HashMap<String, Value>> = trades
        .into_iter()
        .map(
            |(
                order_id,
                price,
                original_quantity,
                quantity,
                filled_quantity,
                timestamp,
                is_bid,
                balance_manager_id,
                status,
            )| {
                let trade_type = if is_bid { "buy" } else { "sell" };
                HashMap::from([
                    ("order_id".to_string(), Value::from(order_id)),
                    (
                        "price".to_string(),
                        Value::from(price as f64 / price_factor as f64),
                    ),
                    (
                        "original_quantity".to_string(),
                        Value::from(original_quantity as f64 / base_factor as f64),
                    ),
                    (
                        "remaining_quantity".to_string(),
                        Value::from(quantity as f64 / base_factor as f64),
                    ),
                    (
                        "filled_quantity".to_string(),
                        Value::from(filled_quantity as f64 / base_factor as f64),
                    ),
                    ("timestamp".to_string(), Value::from(timestamp as u64)),
                    ("type".to_string(), Value::from(trade_type)),
                    (
                        "balance_manager_id".to_string(),
                        Value::from(balance_manager_id),
                    ),
                    ("status".to_string(), Value::from(status)),
                ])
            },
        )
        .collect();

    Ok(Json(trade_data))
}

async fn orders(
    Path((pool_name, balance_manager_id)): Path<(String, String)>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<HashMap<String, Value>>>, DeepBookError> {
    let (pool_id, base_decimals, quote_decimals) =
        state.reader.get_pool_decimals(&pool_name).await?;
    let base_decimals = base_decimals as u8;
    let quote_decimals = quote_decimals as u8;

    let limit = params
        .get("limit")
        .and_then(|v| v.parse::<i64>().ok())
        .unwrap_or(1000);

    let status_filter = params.get("status").map(|s| {
        s.split(',')
            .map(|status| status.trim().to_string())
            .collect::<Vec<_>>()
    });

    let orders = state
        .reader
        .get_orders_status(pool_id, limit, Some(balance_manager_id), status_filter)
        .await?;

    let base_factor = 10u64.pow(base_decimals as u32);
    let price_factor = 10u64.pow((9 - base_decimals + quote_decimals) as u32);

    let order_data: Vec<HashMap<String, Value>> = orders
        .into_iter()
        .map(|order| {
            let order_type = if order.is_bid { "buy" } else { "sell" };
            HashMap::from([
                ("order_id".to_string(), Value::from(order.order_id)),
                (
                    "balance_manager_id".to_string(),
                    Value::from(order.balance_manager_id),
                ),
                ("type".to_string(), Value::from(order_type)),
                (
                    "current_status".to_string(),
                    Value::from(order.current_status),
                ),
                (
                    "price".to_string(),
                    Value::from(order.price as f64 / price_factor as f64),
                ),
                ("placed_at".to_string(), Value::from(order.placed_at as u64)),
                (
                    "last_updated_at".to_string(),
                    Value::from(order.last_updated_at as u64),
                ),
                (
                    "original_quantity".to_string(),
                    Value::from(order.original_quantity as f64 / base_factor as f64),
                ),
                (
                    "filled_quantity".to_string(),
                    Value::from(order.filled_quantity as f64 / base_factor as f64),
                ),
                (
                    "remaining_quantity".to_string(),
                    Value::from(order.remaining_quantity as f64 / base_factor as f64),
                ),
            ])
        })
        .collect();

    Ok(Json(order_data))
}

async fn trades(
    Path(pool_name): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<HashMap<String, Value>>>, DeepBookError> {
    // Fetch all pools to map names to IDs and decimals
    let (pool_id, base_decimals, quote_decimals) =
        state.reader.get_pool_decimals(&pool_name).await?;
    // Parse start_time and end_time
    let end_time = params.end_time();
    let start_time = params
        .start_time()
        .unwrap_or_else(|| end_time - 24 * 60 * 60 * 1000);

    // Parse limit (default to 1 if not provided)
    let limit = params.limit();

    // Parse optional filters for balance managers
    let maker_balance_manager_filter = params.get("maker_balance_manager_id").cloned();
    let taker_balance_manager_filter = params.get("taker_balance_manager_id").cloned();
    let balance_manager_filter = params.get("balance_manager_id").cloned();

    let base_decimals = base_decimals as u8;
    let quote_decimals = quote_decimals as u8;

    let trades = state
        .reader
        .get_orders(
            pool_name,
            pool_id,
            start_time,
            end_time,
            limit,
            maker_balance_manager_filter,
            taker_balance_manager_filter,
            balance_manager_filter,
        )
        .await?;

    // Conversion factors for decimals
    let base_factor = 10u64.pow(base_decimals as u32);
    let quote_factor = 10u64.pow(quote_decimals as u32);
    let deep_factor = 10u64.pow(6 as u32);
    let price_factor = 10u64.pow((9 - base_decimals + quote_decimals) as u32);

    // Map trades to JSON format
    let trade_data = trades
        .into_iter()
        .map(
            |(
                event_digest,
                digest,
                maker_order_id,
                taker_order_id,
                maker_client_order_id,
                taker_client_order_id,
                price,
                base_quantity,
                quote_quantity,
                timestamp,
                taker_is_bid,
                maker_balance_manager_id,
                taker_balance_manager_id,
                taker_fee_is_deep,
                maker_fee_is_deep,
                taker_fee,
                maker_fee,
            )| {
                let trade_id = calculate_trade_id(&maker_order_id, &taker_order_id).unwrap_or(0);
                let trade_type = if taker_is_bid { "buy" } else { "sell" };

                // Scale taker_fee based on taker_is_bid and taker_fee_is_deep
                let scaled_taker_fee = if taker_fee_is_deep {
                    taker_fee as f64 / deep_factor as f64
                } else if taker_is_bid {
                    // taker is buying, fee paid in quote asset
                    taker_fee as f64 / quote_factor as f64
                } else {
                    // taker is selling, fee paid in base asset
                    taker_fee as f64 / base_factor as f64
                };

                // Scale maker_fee based on taker_is_bid and maker_fee_is_deep
                let scaled_maker_fee = if maker_fee_is_deep {
                    maker_fee as f64 / deep_factor as f64
                } else if taker_is_bid {
                    // taker is buying, maker is selling, fee paid in base asset
                    maker_fee as f64 / base_factor as f64
                } else {
                    // taker is selling, maker is buying, fee paid in quote asset
                    maker_fee as f64 / quote_factor as f64
                };

                HashMap::from([
                    ("event_digest".to_string(), Value::from(event_digest)),
                    ("digest".to_string(), Value::from(digest)),
                    ("trade_id".to_string(), Value::from(trade_id.to_string())),
                    ("maker_order_id".to_string(), Value::from(maker_order_id)),
                    ("taker_order_id".to_string(), Value::from(taker_order_id)),
                    (
                        "maker_client_order_id".to_string(),
                        Value::from(maker_client_order_id.to_string()),
                    ),
                    (
                        "taker_client_order_id".to_string(),
                        Value::from(taker_client_order_id.to_string()),
                    ),
                    (
                        "maker_balance_manager_id".to_string(),
                        Value::from(maker_balance_manager_id),
                    ),
                    (
                        "taker_balance_manager_id".to_string(),
                        Value::from(taker_balance_manager_id),
                    ),
                    (
                        "price".to_string(),
                        Value::from(price as f64 / price_factor as f64),
                    ),
                    (
                        "base_volume".to_string(),
                        Value::from(base_quantity as f64 / base_factor as f64),
                    ),
                    (
                        "quote_volume".to_string(),
                        Value::from(quote_quantity as f64 / quote_factor as f64),
                    ),
                    ("timestamp".to_string(), Value::from(timestamp as u64)),
                    ("type".to_string(), Value::from(trade_type)),
                    ("taker_is_bid".to_string(), Value::from(taker_is_bid)),
                    ("taker_fee".to_string(), Value::from(scaled_taker_fee)),
                    ("maker_fee".to_string(), Value::from(scaled_maker_fee)),
                    (
                        "taker_fee_is_deep".to_string(),
                        Value::from(taker_fee_is_deep),
                    ),
                    (
                        "maker_fee_is_deep".to_string(),
                        Value::from(maker_fee_is_deep),
                    ),
                ])
            },
        )
        .collect();

    Ok(Json(trade_data))
}

async fn trade_count(
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<i64>, DeepBookError> {
    // Parse start_time and end_time
    let end_time = params.end_time();
    let start_time = params
        .start_time() // Convert to milliseconds
        .unwrap_or_else(|| end_time - 24 * 60 * 60 * 1000);

    let query = schema::order_fills::table
        .select(count_star())
        .filter(schema::order_fills::checkpoint_timestamp_ms.between(start_time, end_time));

    let result = state.reader.first(query).await?;
    Ok(Json(result))
}

fn calculate_trade_id(maker_id: &str, taker_id: &str) -> Result<u128, DeepBookError> {
    // Parse maker_id and taker_id as u128
    let maker_id = maker_id
        .parse::<u128>()
        .map_err(|_| DeepBookError::bad_request("Invalid maker_id"))?;
    let taker_id = taker_id
        .parse::<u128>()
        .map_err(|_| DeepBookError::bad_request("Invalid taker_id"))?;

    // Ignore the most significant bit for both IDs
    let maker_id = maker_id & !(1 << 127);
    let taker_id = taker_id & !(1 << 127);

    // Return the sum of the modified IDs as the trade_id
    Ok(maker_id + taker_id)
}

pub async fn assets(
    State(state): State<Arc<AppState>>,
) -> Result<Json<HashMap<String, HashMap<String, Value>>>, DeepBookError> {
    let query = schema::assets::table.select((
        schema::assets::symbol,
        schema::assets::name,
        schema::assets::ucid,
        schema::assets::package_address_url,
        schema::assets::package_id,
        schema::assets::asset_type,
    ));
    let assets: Vec<(
        String,
        String,
        Option<i32>,
        Option<String>,
        Option<String>,
        String,
    )> = state
        .reader
        .results(query)
        .await
        .map_err(|err| DeepBookError::rpc(format!("Failed to query assets: {}", err)))?;
    let mut response = HashMap::new();

    for (symbol, name, ucid, package_address_url, package_id, asset_type) in assets {
        let mut asset_info = HashMap::new();
        asset_info.insert("name".to_string(), Value::String(name));
        asset_info.insert("asset_type".to_string(), Value::String(asset_type));
        asset_info.insert(
            "can_withdraw".to_string(),
            Value::String("true".to_string()),
        );
        asset_info.insert("can_deposit".to_string(), Value::String("true".to_string()));

        if let Some(ucid) = ucid {
            asset_info.insert(
                "unified_cryptoasset_id".to_string(),
                Value::String(ucid.to_string()),
            );
        }
        if let Some(addresses) = package_address_url {
            asset_info.insert("contractAddressUrl".to_string(), Value::String(addresses));
        }

        if let Some(addresses) = package_id {
            asset_info.insert("contractAddress".to_string(), Value::String(addresses));
        }

        response.insert(symbol, asset_info);
    }

    Ok(Json(response))
}

/// Level2 data for all pools
async fn orderbook(
    Path(pool_name): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<HashMap<String, Value>>, DeepBookError> {
    let depth = params
        .get("depth")
        .map(|v| v.parse::<u64>())
        .transpose()
        .map_err(|_| DeepBookError::bad_request("Depth must be a non-negative integer"))?
        .map(|depth| if depth == 0 { 200 } else { depth });

    if let Some(depth) = depth {
        if depth == 1 {
            return Err(DeepBookError::bad_request(
                "Depth cannot be 1. Use a value greater than 1 or 0 for the entire orderbook",
            ));
        }
    }

    let level = params
        .get("level")
        .map(|v| v.parse::<u64>())
        .transpose()
        .map_err(|_| DeepBookError::bad_request("Level must be an integer between 1 and 2"))?;

    if let Some(level) = level {
        if !(1..=2).contains(&level) {
            return Err(DeepBookError::bad_request("Level must be 1 or 2"));
        }
    }

    let ticks_from_mid = match (depth, level) {
        (Some(_), Some(1)) => 1u64, // Depth + Level 1 → Best bid and ask
        (Some(depth), Some(2)) | (Some(depth), None) => depth / 2, // Depth + Level 2 → Use depth
        (None, Some(1)) => 1u64,    // Only Level 1 → Best bid and ask
        (None, Some(2)) | (None, None) => 100u64, // Level 2 or default → 100 ticks
        _ => 100u64,                // Fallback to default
    };

    // Fetch the pool data from the `pools` table
    let query = schema::pools::table
        .filter(schema::pools::pool_name.eq(pool_name.clone()))
        .select((
            schema::pools::pool_id,
            schema::pools::base_asset_id,
            schema::pools::base_asset_decimals,
            schema::pools::quote_asset_id,
            schema::pools::quote_asset_decimals,
        ));
    let pool_data: (String, String, i16, String, i16) = state.reader.first(query).await?;
    let (pool_id, base_asset_id, base_decimals, quote_asset_id, quote_decimals) = pool_data;
    let base_decimals = base_decimals as u8;
    let quote_decimals = quote_decimals as u8;

    let pool_address = ObjectID::from_hex_literal(&pool_id)?;

    let sui_client = state.sui_client().await?;
    let mut ptb = ProgrammableTransactionBuilder::new();

    let pool_object: SuiObjectResponse = sui_client
        .read_api()
        .get_object_with_options(
            pool_address,
            SuiObjectDataOptions::full_content().with_owner(),
        )
        .await?;
    let pool_data: &SuiObjectData = pool_object.data.as_ref().ok_or(DeepBookError::rpc(
        format!("Missing data in pool object response for '{}'", pool_name),
    ))?;

    let initial_shared_version = match &pool_data.owner {
        Some(sui_types::object::Owner::Shared {
            initial_shared_version,
        }) => *initial_shared_version,
        _ => {
            return Err(DeepBookError::rpc(format!(
                "Pool '{}' is not a shared object or owner info missing",
                pool_name
            )));
        }
    };

    let pool_input = CallArg::Object(ObjectArg::SharedObject {
        id: pool_data.object_id,
        initial_shared_version,
        mutability: sui_types::transaction::SharedObjectMutability::Immutable,
    });
    ptb.input(pool_input)?;

    let input_argument = CallArg::Pure(
        bcs::to_bytes(&ticks_from_mid)
            .map_err(|_| DeepBookError::internal("Failed to serialize ticks_from_mid"))?,
    );
    ptb.input(input_argument)?;

    let sui_clock_object_id = ObjectID::from_hex_literal(
        "0x0000000000000000000000000000000000000000000000000000000000000006",
    )?;
    let clock_input = CallArg::Object(ObjectArg::SharedObject {
        id: sui_clock_object_id,
        initial_shared_version: sui_types::base_types::SequenceNumber::from_u64(1),
        mutability: sui_types::transaction::SharedObjectMutability::Immutable,
    });
    ptb.input(clock_input)?;

    let base_coin_type = parse_type_input(&base_asset_id)?;
    let quote_coin_type = parse_type_input(&quote_asset_id)?;

    let package = ObjectID::from_hex_literal(&state.deepbook_package_id)
        .map_err(|e| DeepBookError::bad_request(format!("Invalid pool ID: {}", e)))?;
    let module = LEVEL2_MODULE.to_string();
    let function = LEVEL2_FUNCTION.to_string();

    ptb.command(Command::MoveCall(Box::new(ProgrammableMoveCall {
        package,
        module,
        function,
        type_arguments: vec![base_coin_type, quote_coin_type],
        arguments: vec![Argument::Input(0), Argument::Input(1), Argument::Input(2)],
    })));

    let builder = ptb.finish();
    let tx = TransactionKind::ProgrammableTransaction(builder);

    let result = sui_client
        .read_api()
        .dev_inspect_transaction_block(SuiAddress::default(), tx, None, None, None)
        .await?;

    let mut binding = result.results.ok_or(DeepBookError::rpc(
        "No results from dev_inspect_transaction_block",
    ))?;
    let bid_prices = &binding
        .first_mut()
        .ok_or(DeepBookError::rpc("No return values for bid prices"))?
        .return_values
        .first_mut()
        .ok_or(DeepBookError::rpc("No bid price data found"))?
        .0;
    let bid_parsed_prices: Vec<u64> = bcs::from_bytes(bid_prices)
        .map_err(|_| DeepBookError::deserialization("Failed to deserialize bid prices"))?;
    let bid_quantities = &binding
        .first_mut()
        .ok_or(DeepBookError::rpc("No return values for bid quantities"))?
        .return_values
        .get(1)
        .ok_or(DeepBookError::rpc("No bid quantity data found"))?
        .0;
    let bid_parsed_quantities: Vec<u64> = bcs::from_bytes(bid_quantities)
        .map_err(|_| DeepBookError::deserialization("Failed to deserialize bid quantities"))?;

    let ask_prices = &binding
        .first_mut()
        .ok_or(DeepBookError::rpc("No return values for ask prices"))?
        .return_values
        .get(2)
        .ok_or(DeepBookError::rpc("No ask price data found"))?
        .0;
    let ask_parsed_prices: Vec<u64> = bcs::from_bytes(ask_prices)
        .map_err(|_| DeepBookError::deserialization("Failed to deserialize ask prices"))?;
    let ask_quantities = &binding
        .first_mut()
        .ok_or(DeepBookError::rpc("No return values for ask quantities"))?
        .return_values
        .get(3)
        .ok_or(DeepBookError::rpc("No ask quantity data found"))?
        .0;
    let ask_parsed_quantities: Vec<u64> = bcs::from_bytes(ask_quantities)
        .map_err(|_| DeepBookError::deserialization("Failed to deserialize ask quantities"))?;

    let mut result = HashMap::new();

    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| DeepBookError::internal("System time error"))?
        .as_millis() as i64;
    result.insert("timestamp".to_string(), Value::from(timestamp.to_string()));

    let bids: Vec<Value> = bid_parsed_prices
        .into_iter()
        .zip(bid_parsed_quantities.into_iter())
        .take(ticks_from_mid as usize)
        .map(|(price, quantity)| {
            let price_factor = 10u64.pow((9 - base_decimals + quote_decimals).into());
            let quantity_factor = 10u64.pow((base_decimals).into());
            Value::Array(vec![
                Value::from((price as f64 / price_factor as f64).to_string()),
                Value::from((quantity as f64 / quantity_factor as f64).to_string()),
            ])
        })
        .collect();
    result.insert("bids".to_string(), Value::Array(bids));

    let asks: Vec<Value> = ask_parsed_prices
        .into_iter()
        .zip(ask_parsed_quantities.into_iter())
        .take(ticks_from_mid as usize)
        .map(|(price, quantity)| {
            let price_factor = 10u64.pow((9 - base_decimals + quote_decimals).into());
            let quantity_factor = 10u64.pow((base_decimals).into());
            Value::Array(vec![
                Value::from((price as f64 / price_factor as f64).to_string()),
                Value::from((quantity as f64 / quantity_factor as f64).to_string()),
            ])
        })
        .collect();
    result.insert("asks".to_string(), Value::Array(asks));

    Ok(Json(result))
}

/// DEEP total supply
async fn deep_supply(State(state): State<Arc<AppState>>) -> Result<Json<u64>, DeepBookError> {
    let sui_client = state.sui_client().await?;
    let mut ptb = ProgrammableTransactionBuilder::new();

    let deep_treasury_object_id = ObjectID::from_hex_literal(&state.deep_treasury_id)?;
    let deep_treasury_object: SuiObjectResponse = sui_client
        .read_api()
        .get_object_with_options(
            deep_treasury_object_id,
            SuiObjectDataOptions::full_content().with_owner(),
        )
        .await?;
    let deep_treasury_data: &SuiObjectData = deep_treasury_object
        .data
        .as_ref()
        .ok_or(DeepBookError::rpc("Incorrect Treasury ID"))?;

    let initial_shared_version = match &deep_treasury_data.owner {
        Some(sui_types::object::Owner::Shared {
            initial_shared_version,
        }) => *initial_shared_version,
        _ => {
            return Err(DeepBookError::rpc("Treasury is not a shared object"));
        }
    };
    let deep_treasury_input = CallArg::Object(ObjectArg::SharedObject {
        id: deep_treasury_data.object_id,
        initial_shared_version,
        mutability: sui_types::transaction::SharedObjectMutability::Immutable,
    });
    ptb.input(deep_treasury_input)?;

    let package = ObjectID::from_hex_literal(&state.deep_token_package_id)
        .map_err(|e| DeepBookError::bad_request(format!("Invalid deep token package ID: {}", e)))?;
    let module = DEEP_SUPPLY_MODULE.to_string();
    let function = DEEP_SUPPLY_FUNCTION.to_string();

    ptb.command(Command::MoveCall(Box::new(ProgrammableMoveCall {
        package,
        module,
        function,
        type_arguments: vec![],
        arguments: vec![Argument::Input(0)],
    })));

    let builder = ptb.finish();
    let tx = TransactionKind::ProgrammableTransaction(builder);

    let result = sui_client
        .read_api()
        .dev_inspect_transaction_block(SuiAddress::default(), tx, None, None, None)
        .await?;

    let mut binding = result.results.ok_or(DeepBookError::rpc(
        "No results from dev_inspect_transaction_block",
    ))?;

    let total_supply = &binding
        .first_mut()
        .ok_or(DeepBookError::rpc("No return values for total supply"))?
        .return_values
        .first_mut()
        .ok_or(DeepBookError::rpc("No total supply data found"))?
        .0;

    let total_supply_value: u64 = bcs::from_bytes(total_supply)
        .map_err(|_| DeepBookError::deserialization("Failed to deserialize total supply"))?;

    Ok(Json(total_supply_value))
}

/// Get total supply for all margin pools
async fn margin_supply(
    State(state): State<Arc<AppState>>,
) -> Result<Json<HashMap<String, u64>>, DeepBookError> {
    let margin_package_id = state
        .margin_package_id
        .as_ref()
        .ok_or_else(|| DeepBookError::bad_request("Margin package ID not configured"))?;

    // Query all margin pools from the database
    let query = schema::margin_pool_created::table.select((
        schema::margin_pool_created::margin_pool_id,
        schema::margin_pool_created::asset_type,
    ));
    let pools: Vec<(String, String)> = state.reader.results(query).await?;

    if pools.is_empty() {
        return Ok(Json(HashMap::new()));
    }

    let sui_client = state.sui_client().await?;
    let package = ObjectID::from_hex_literal(margin_package_id)
        .map_err(|e| DeepBookError::bad_request(format!("Invalid margin package ID: {}", e)))?;

    let mut result: HashMap<String, u64> = HashMap::new();

    for (pool_id, asset_type) in pools {
        let pool_object_id = ObjectID::from_hex_literal(&pool_id).map_err(|e| {
            DeepBookError::bad_request(format!("Invalid pool ID '{}': {}", pool_id, e))
        })?;

        // Get the pool object to find its initial_shared_version
        let pool_object: SuiObjectResponse = sui_client
            .read_api()
            .get_object_with_options(
                pool_object_id,
                SuiObjectDataOptions::full_content().with_owner(),
            )
            .await?;

        let pool_data: &SuiObjectData = pool_object.data.as_ref().ok_or(DeepBookError::rpc(
            format!("Missing data in pool object response for '{}'", pool_id),
        ))?;

        let initial_shared_version = match &pool_data.owner {
            Some(sui_types::object::Owner::Shared {
                initial_shared_version,
            }) => *initial_shared_version,
            _ => {
                continue;
            }
        };

        // Normalize asset type (ensure 0x prefix)
        let normalized_asset_type = if asset_type.starts_with("0x") || asset_type.starts_with("0X")
        {
            asset_type.clone()
        } else {
            format!("0x{}", asset_type)
        };

        let type_tag = match TypeTag::from_str(&normalized_asset_type) {
            Ok(t) => t,
            Err(_) => continue,
        };
        let type_input = TypeInput::from(type_tag);

        // Build PTB for total_supply call
        let mut ptb = ProgrammableTransactionBuilder::new();

        let pool_input = CallArg::Object(ObjectArg::SharedObject {
            id: pool_data.object_id,
            initial_shared_version,
            mutability: sui_types::transaction::SharedObjectMutability::Immutable,
        });
        ptb.input(pool_input)?;

        ptb.command(Command::MoveCall(Box::new(ProgrammableMoveCall {
            package,
            module: MARGIN_POOL_MODULE.to_string(),
            function: "total_supply".to_string(),
            type_arguments: vec![type_input],
            arguments: vec![Argument::Input(0)],
        })));

        let builder = ptb.finish();
        let tx = TransactionKind::ProgrammableTransaction(builder);

        let inspect_result = sui_client
            .read_api()
            .dev_inspect_transaction_block(SuiAddress::default(), tx, None, None, None)
            .await?;

        if let Some(mut results) = inspect_result.results {
            if let Some(first_result) = results.first_mut() {
                if let Some(return_value) = first_result.return_values.first() {
                    if let Ok(total_supply) = bcs::from_bytes::<u64>(&return_value.0) {
                        // Extract asset name from asset_type (e.g., "0x2::sui::SUI" -> "SUI")
                        let asset_name = asset_type
                            .rsplit("::")
                            .next()
                            .unwrap_or(&asset_type)
                            .to_string();
                        result.insert(asset_name, total_supply);
                    }
                }
            }
        }
    }

    Ok(Json(result))
}

async fn get_net_deposits(
    Path((asset_ids, timestamp)): Path<(String, String)>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<HashMap<String, i64>>, DeepBookError> {
    let timestamp_ms = timestamp
        .parse::<i64>()
        .map_err(|_| DeepBookError::bad_request("Invalid timestamp"))?
        * 1000; // Convert seconds to milliseconds

    let assets: Vec<String> = asset_ids.split(',').map(|s| s.to_string()).collect();

    let net_deposits = state
        .reader
        .get_net_deposits_from_view(&assets, timestamp_ms)
        .await?;

    Ok(Json(net_deposits))
}

fn parse_type_input(type_str: &str) -> Result<TypeInput, DeepBookError> {
    let type_tag = TypeTag::from_str(type_str)?;
    Ok(TypeInput::from(type_tag))
}

trait ParameterUtil {
    fn start_time(&self) -> Option<i64>;
    fn end_time(&self) -> i64;
    fn volume_in_base(&self) -> bool;

    fn limit(&self) -> i64;
}

impl ParameterUtil for HashMap<String, String> {
    fn start_time(&self) -> Option<i64> {
        self.get("start_time")
            .and_then(|v| v.parse::<i64>().ok())
            .map(|t| t * 1000) // Convert
    }

    fn end_time(&self) -> i64 {
        self.get("end_time")
            .and_then(|v| v.parse::<i64>().ok())
            .map(|t| t * 1000) // Convert to milliseconds
            .unwrap_or_else(|| {
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap()
                    .as_millis() as i64
            })
    }

    fn volume_in_base(&self) -> bool {
        self.get("volume_in_base")
            .map(|v| v == "true")
            .unwrap_or_default()
    }

    fn limit(&self) -> i64 {
        self.get("limit")
            .and_then(|v| v.parse::<i64>().ok())
            .unwrap_or(1)
    }
}

async fn ohclv(
    Path(pool_name): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<HashMap<String, Value>>, DeepBookError> {
    let pools = state.reader.get_pools().await?;
    let pool = pools
        .iter()
        .find(|p| p.pool_name == pool_name)
        .ok_or_else(|| DeepBookError::not_found(format!("Pool '{}'", pool_name)))?;

    let interval = params.get("interval").unwrap_or(&"1m".to_string()).clone();
    let start_time = params.get("start_time").and_then(|v| v.parse::<i64>().ok());
    let end_time = params.get("end_time").and_then(|v| v.parse::<i64>().ok());
    let limit = params.get("limit").and_then(|v| v.parse::<i32>().ok());

    let valid_intervals = vec!["1m", "5m", "15m", "30m", "1h", "4h", "1d", "1w"];
    if !valid_intervals.contains(&interval.as_str()) {
        return Err(DeepBookError::bad_request(format!(
            "Invalid interval: {}. Valid intervals are: {:?}",
            interval, valid_intervals
        )));
    }

    let candles = state
        .reader
        .get_ohclv(pool.pool_id.clone(), interval, start_time, end_time, limit)
        .await?;
    let candles_array: Vec<Value> = candles
        .into_iter()
        .map(|(timestamp, open, high, low, close, volume)| {
            Value::Array(vec![
                Value::from(timestamp),
                Value::from(open),
                Value::from(high),
                Value::from(low),
                Value::from(close),
                Value::from(volume),
            ])
        })
        .collect();

    let mut response = HashMap::new();
    response.insert("candles".to_string(), Value::Array(candles_array));

    Ok(Json(response))
}

// === Margin Manager Events Handlers ===
async fn margin_manager_created(
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<MarginManagerCreated>>, DeepBookError> {
    let end_time = params.end_time();
    let start_time = params
        .start_time()
        .unwrap_or_else(|| end_time - 24 * 60 * 60 * 1000);
    let limit = params.limit();
    let margin_manager_id_filter = params.get("margin_manager_id").cloned().unwrap_or_default();

    let results = state
        .reader
        .get_margin_manager_created(start_time, end_time, limit, margin_manager_id_filter)
        .await?;

    Ok(Json(results))
}

async fn loan_borrowed(
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<LoanBorrowed>>, DeepBookError> {
    let end_time = params.end_time();
    let start_time = params
        .start_time()
        .unwrap_or_else(|| end_time - 24 * 60 * 60 * 1000);
    let limit = params.limit();
    let margin_manager_id_filter = params.get("margin_manager_id").cloned().unwrap_or_default();
    let margin_pool_id_filter = params.get("margin_pool_id").cloned().unwrap_or_default();

    let results = state
        .reader
        .get_loan_borrowed(
            start_time,
            end_time,
            limit,
            margin_manager_id_filter,
            margin_pool_id_filter,
        )
        .await?;

    Ok(Json(results))
}

async fn loan_repaid(
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<LoanRepaid>>, DeepBookError> {
    let end_time = params.end_time();
    let start_time = params
        .start_time()
        .unwrap_or_else(|| end_time - 24 * 60 * 60 * 1000);
    let limit = params.limit();
    let margin_manager_id_filter = params.get("margin_manager_id").cloned().unwrap_or_default();
    let margin_pool_id_filter = params.get("margin_pool_id").cloned().unwrap_or_default();

    let results = state
        .reader
        .get_loan_repaid(
            start_time,
            end_time,
            limit,
            margin_manager_id_filter,
            margin_pool_id_filter,
        )
        .await?;

    Ok(Json(results))
}

async fn liquidation(
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<Liquidation>>, DeepBookError> {
    let end_time = params.end_time();
    let start_time = params
        .start_time()
        .unwrap_or_else(|| end_time - 24 * 60 * 60 * 1000);
    let limit = params.limit();
    let margin_manager_id_filter = params.get("margin_manager_id").cloned().unwrap_or_default();
    let margin_pool_id_filter = params.get("margin_pool_id").cloned().unwrap_or_default();

    let results = state
        .reader
        .get_liquidation(
            start_time,
            end_time,
            limit,
            margin_manager_id_filter,
            margin_pool_id_filter,
        )
        .await?;

    Ok(Json(results))
}

// === Margin Pool Operations Events Handlers ===
async fn asset_supplied(
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<AssetSupplied>>, DeepBookError> {
    let end_time = params.end_time();
    let start_time = params
        .start_time()
        .unwrap_or_else(|| end_time - 24 * 60 * 60 * 1000);
    let limit = params.limit();
    let margin_pool_id_filter = params.get("margin_pool_id").cloned().unwrap_or_default();
    let supplier_filter = params.get("supplier").cloned().unwrap_or_default();

    let results = state
        .reader
        .get_asset_supplied(
            start_time,
            end_time,
            limit,
            margin_pool_id_filter,
            supplier_filter,
        )
        .await?;

    Ok(Json(results))
}

async fn asset_withdrawn(
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<AssetWithdrawn>>, DeepBookError> {
    let end_time = params.end_time();
    let start_time = params
        .start_time()
        .unwrap_or_else(|| end_time - 24 * 60 * 60 * 1000);
    let limit = params.limit();
    let margin_pool_id_filter = params.get("margin_pool_id").cloned().unwrap_or_default();
    let supplier_filter = params.get("supplier").cloned().unwrap_or_default();

    let results = state
        .reader
        .get_asset_withdrawn(
            start_time,
            end_time,
            limit,
            margin_pool_id_filter,
            supplier_filter,
        )
        .await?;

    Ok(Json(results))
}

// === Margin Pool Admin Events Handlers ===
async fn margin_pool_created(
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<MarginPoolCreated>>, DeepBookError> {
    let margin_pool_id_filter = params.get("margin_pool_id").cloned().unwrap_or_default();

    let results = state
        .reader
        .get_margin_pool_created(margin_pool_id_filter)
        .await?;

    Ok(Json(results))
}

async fn deepbook_pool_updated(
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<DeepbookPoolUpdated>>, DeepBookError> {
    let end_time = params.end_time();
    let start_time = params
        .start_time()
        .unwrap_or_else(|| end_time - 24 * 60 * 60 * 1000);
    let limit = params.limit();
    let margin_pool_id_filter = params.get("margin_pool_id").cloned().unwrap_or_default();
    let deepbook_pool_id_filter = params.get("deepbook_pool_id").cloned().unwrap_or_default();

    let results = state
        .reader
        .get_deepbook_pool_updated(
            start_time,
            end_time,
            limit,
            margin_pool_id_filter,
            deepbook_pool_id_filter,
        )
        .await?;

    Ok(Json(results))
}

async fn interest_params_updated(
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<InterestParamsUpdated>>, DeepBookError> {
    let end_time = params.end_time();
    let start_time = params
        .start_time()
        .unwrap_or_else(|| end_time - 24 * 60 * 60 * 1000);
    let limit = params.limit();
    let margin_pool_id_filter = params.get("margin_pool_id").cloned().unwrap_or_default();

    let results = state
        .reader
        .get_interest_params_updated(start_time, end_time, limit, margin_pool_id_filter)
        .await?;

    Ok(Json(results))
}

async fn margin_pool_config_updated(
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<MarginPoolConfigUpdated>>, DeepBookError> {
    let end_time = params.end_time();
    let start_time = params
        .start_time()
        .unwrap_or_else(|| end_time - 24 * 60 * 60 * 1000);
    let limit = params.limit();
    let margin_pool_id_filter = params.get("margin_pool_id").cloned().unwrap_or_default();

    let results = state
        .reader
        .get_margin_pool_config_updated(start_time, end_time, limit, margin_pool_id_filter)
        .await?;

    Ok(Json(results))
}

// === Margin Registry Events Handlers ===
async fn maintainer_cap_updated(
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<MaintainerCapUpdated>>, DeepBookError> {
    let end_time = params.end_time();
    let start_time = params
        .start_time()
        .unwrap_or_else(|| end_time - 24 * 60 * 60 * 1000);
    let limit = params.limit();
    let maintainer_cap_id_filter = params.get("maintainer_cap_id").cloned().unwrap_or_default();

    let results = state
        .reader
        .get_maintainer_cap_updated(start_time, end_time, limit, maintainer_cap_id_filter)
        .await?;

    Ok(Json(results))
}

async fn maintainer_fees_withdrawn(
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<MaintainerFeesWithdrawn>>, DeepBookError> {
    let end_time = params.end_time();
    let start_time = params
        .start_time()
        .unwrap_or_else(|| end_time - 24 * 60 * 60 * 1000);
    let limit = params.limit();
    let margin_pool_id_filter = params.get("margin_pool_id").cloned().unwrap_or_default();

    let results = state
        .reader
        .get_maintainer_fees_withdrawn(start_time, end_time, limit, margin_pool_id_filter)
        .await?;

    Ok(Json(results))
}

async fn protocol_fees_withdrawn(
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<ProtocolFeesWithdrawn>>, DeepBookError> {
    let end_time = params.end_time();
    let start_time = params
        .start_time()
        .unwrap_or_else(|| end_time - 24 * 60 * 60 * 1000);
    let limit = params.limit();
    let margin_pool_id_filter = params.get("margin_pool_id").cloned().unwrap_or_default();

    let results = state
        .reader
        .get_protocol_fees_withdrawn(start_time, end_time, limit, margin_pool_id_filter)
        .await?;

    Ok(Json(results))
}

async fn supplier_cap_minted(
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<SupplierCapMinted>>, DeepBookError> {
    let end_time = params.end_time();
    let start_time = params
        .start_time()
        .unwrap_or_else(|| end_time - 24 * 60 * 60 * 1000);
    let limit = params.limit();
    let supplier_cap_id_filter = params.get("supplier_cap_id").cloned().unwrap_or_default();

    let results = state
        .reader
        .get_supplier_cap_minted(start_time, end_time, limit, supplier_cap_id_filter)
        .await?;

    Ok(Json(results))
}

async fn supply_referral_minted(
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<SupplyReferralMinted>>, DeepBookError> {
    let end_time = params.end_time();
    let start_time = params
        .start_time()
        .unwrap_or_else(|| end_time - 24 * 60 * 60 * 1000);
    let limit = params.limit();
    let margin_pool_id_filter = params.get("margin_pool_id").cloned().unwrap_or_default();
    let owner_filter = params.get("owner").cloned().unwrap_or_default();

    let results = state
        .reader
        .get_supply_referral_minted(
            start_time,
            end_time,
            limit,
            margin_pool_id_filter,
            owner_filter,
        )
        .await?;

    Ok(Json(results))
}

async fn pause_cap_updated(
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<PauseCapUpdated>>, DeepBookError> {
    let end_time = params.end_time();
    let start_time = params
        .start_time()
        .unwrap_or_else(|| end_time - 24 * 60 * 60 * 1000);
    let limit = params.limit();
    let pause_cap_id_filter = params.get("pause_cap_id").cloned().unwrap_or_default();

    let results = state
        .reader
        .get_pause_cap_updated(start_time, end_time, limit, pause_cap_id_filter)
        .await?;

    Ok(Json(results))
}

async fn protocol_fees_increased(
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<ProtocolFeesIncreasedEvent>>, DeepBookError> {
    let end_time = params.end_time();
    let start_time = params
        .start_time()
        .unwrap_or_else(|| end_time - 24 * 60 * 60 * 1000);
    let limit = params.limit();
    let margin_pool_id_filter = params.get("margin_pool_id").cloned().unwrap_or_default();

    let results = state
        .reader
        .get_protocol_fees_increased(start_time, end_time, limit, margin_pool_id_filter)
        .await?;

    Ok(Json(results))
}

async fn referral_fees_claimed(
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<ReferralFeesClaimedEvent>>, DeepBookError> {
    let end_time = params.end_time();
    let start_time = params
        .start_time()
        .unwrap_or_else(|| end_time - 24 * 60 * 60 * 1000);
    let limit = params.limit();
    let referral_id_filter = params.get("referral_id").cloned().unwrap_or_default();
    let owner_filter = params.get("owner").cloned().unwrap_or_default();

    let results = state
        .reader
        .get_referral_fees_claimed(
            start_time,
            end_time,
            limit,
            referral_id_filter,
            owner_filter,
        )
        .await?;

    Ok(Json(results))
}

async fn referral_fee_events(
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<ReferralFeeEvent>>, DeepBookError> {
    let end_time = params.end_time();
    let start_time = params
        .start_time()
        .unwrap_or_else(|| end_time - 24 * 60 * 60 * 1000);
    let limit = params.limit();
    let pool_id_filter = params.get("pool_id").cloned().unwrap_or_default();
    let referral_id_filter = params.get("referral_id").cloned().unwrap_or_default();

    let results = state
        .reader
        .get_referral_fee_events(
            start_time,
            end_time,
            limit,
            pool_id_filter,
            referral_id_filter,
        )
        .await?;

    Ok(Json(results))
}

async fn deepbook_pool_registered(
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<DeepbookPoolRegistered>>, DeepBookError> {
    let end_time = params.end_time();
    let start_time = params
        .start_time()
        .unwrap_or_else(|| end_time - 24 * 60 * 60 * 1000);
    let limit = params.limit();
    let pool_id_filter = params.get("pool_id").cloned().unwrap_or_default();

    let results = state
        .reader
        .get_deepbook_pool_registered(start_time, end_time, limit, pool_id_filter)
        .await?;

    Ok(Json(results))
}

async fn deepbook_pool_updated_registry(
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<DeepbookPoolUpdatedRegistry>>, DeepBookError> {
    let end_time = params.end_time();
    let start_time = params
        .start_time()
        .unwrap_or_else(|| end_time - 24 * 60 * 60 * 1000);
    let limit = params.limit();
    let pool_id_filter = params.get("pool_id").cloned().unwrap_or_default();

    let results = state
        .reader
        .get_deepbook_pool_updated_registry(start_time, end_time, limit, pool_id_filter)
        .await?;

    Ok(Json(results))
}

async fn deepbook_pool_config_updated(
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<DeepbookPoolConfigUpdated>>, DeepBookError> {
    let end_time = params.end_time();
    let start_time = params
        .start_time()
        .unwrap_or_else(|| end_time - 24 * 60 * 60 * 1000);
    let limit = params.limit();
    let pool_id_filter = params.get("pool_id").cloned().unwrap_or_default();

    let results = state
        .reader
        .get_deepbook_pool_config_updated(start_time, end_time, limit, pool_id_filter)
        .await?;

    Ok(Json(results))
}

async fn margin_managers_info(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<HashMap<String, Value>>>, DeepBookError> {
    let results = state.reader.get_margin_managers_info().await?;

    let data: Vec<HashMap<String, Value>> = results
        .into_iter()
        .map(
            |(
                margin_manager_id,
                deepbook_pool_id,
                base_asset_id,
                base_asset_symbol,
                quote_asset_id,
                quote_asset_symbol,
                base_margin_pool_id,
                quote_margin_pool_id,
            )| {
                HashMap::from([
                    (
                        "margin_manager_id".to_string(),
                        Value::from(margin_manager_id),
                    ),
                    (
                        "deepbook_pool_id".to_string(),
                        deepbook_pool_id.map_or(Value::Null, Value::from),
                    ),
                    (
                        "base_asset_id".to_string(),
                        base_asset_id.map_or(Value::Null, Value::from),
                    ),
                    (
                        "base_asset_symbol".to_string(),
                        base_asset_symbol.map_or(Value::Null, Value::from),
                    ),
                    (
                        "quote_asset_id".to_string(),
                        quote_asset_id.map_or(Value::Null, Value::from),
                    ),
                    (
                        "quote_asset_symbol".to_string(),
                        quote_asset_symbol.map_or(Value::Null, Value::from),
                    ),
                    (
                        "base_margin_pool_id".to_string(),
                        base_margin_pool_id.map_or(Value::Null, Value::from),
                    ),
                    (
                        "quote_margin_pool_id".to_string(),
                        quote_margin_pool_id.map_or(Value::Null, Value::from),
                    ),
                ])
            },
        )
        .collect();

    Ok(Json(data))
}

async fn margin_manager_states(
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<MarginManagerState>>, DeepBookError> {
    let max_risk_ratio = params
        .get("max_risk_ratio")
        .and_then(|v| v.parse::<f64>().ok());
    let deepbook_pool_id = params.get("deepbook_pool_id").cloned();

    // Parse pool parameter (e.g., "SUI_USDC" -> base="SUI", quote="USDC")
    let (base_asset_symbol, quote_asset_symbol) = params
        .get("pool")
        .map(|p| {
            let parts: Vec<&str> = p.split('_').collect();
            if parts.len() == 2 {
                (Some(parts[0].to_string()), Some(parts[1].to_string()))
            } else {
                (None, None)
            }
        })
        .unwrap_or((None, None));

    let states = state
        .reader
        .get_margin_manager_states(
            max_risk_ratio,
            deepbook_pool_id,
            base_asset_symbol,
            quote_asset_symbol,
        )
        .await?;

    Ok(Json(states))
}

#[derive(serde::Serialize)]
struct BalanceManagerDepositedAssets {
    balance_manager_id: String,
    assets: Vec<String>,
}

async fn deposited_assets(
    Path(balance_manager_ids): Path<String>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<BalanceManagerDepositedAssets>>, DeepBookError> {
    let ids: Vec<String> = balance_manager_ids
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();

    if ids.is_empty() {
        return Err(DeepBookError::bad_request(
            "No balance manager IDs provided",
        ));
    }

    let results = state
        .reader
        .get_deposited_assets_by_balance_managers(&ids)
        .await?;

    let mut assets_by_manager: HashMap<String, Vec<String>> = HashMap::new();
    for (balance_manager_id, asset) in results {
        assets_by_manager
            .entry(balance_manager_id)
            .or_default()
            .push(asset);
    }

    let response: Vec<BalanceManagerDepositedAssets> = ids
        .into_iter()
        .map(|id| {
            let assets = assets_by_manager.remove(&id).unwrap_or_default();
            BalanceManagerDepositedAssets {
                balance_manager_id: id,
                assets,
            }
        })
        .collect();

    Ok(Json(response))
}

async fn collateral_events(
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<CollateralEvent>>, DeepBookError> {
    let end_time = params.end_time();
    let start_time = params
        .start_time()
        .unwrap_or_else(|| end_time - 24 * 60 * 60 * 1000);
    let limit = params.limit();
    let margin_manager_id_filter = params.get("margin_manager_id").cloned().unwrap_or_default();
    let event_type_filter = params.get("type").cloned().unwrap_or_default();
    let is_base_filter = params.get("is_base").and_then(|v| v.parse::<bool>().ok());

    let results = state
        .reader
        .get_collateral_events(
            start_time,
            end_time,
            limit,
            margin_manager_id_filter,
            event_type_filter,
            is_base_filter,
        )
        .await?;

    Ok(Json(results))
}

// === Points ===
#[derive(Deserialize)]
struct GetPointsQuery {
    addresses: Option<String>,
}

async fn get_points(
    Query(params): Query<GetPointsQuery>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<serde_json::Value>>, DeepBookError> {
    let addresses = params
        .addresses
        .map(|s| {
            s.split(',')
                .map(|a| a.trim().to_string())
                .filter(|a| !a.is_empty())
                .collect::<Vec<_>>()
        })
        .filter(|v| !v.is_empty());

    let Some(requested) = addresses else {
        return Ok(Json(vec![]));
    };

    let results = state.reader.get_points(Some(&requested)).await?;
    let results_map: std::collections::HashMap<_, _> = results.into_iter().collect();

    let response = requested
        .iter()
        .map(|addr| {
            serde_json::json!({
                "address": addr,
                "total_points": results_map.get(addr).copied().unwrap_or(0)
            })
        })
        .collect();

    Ok(Json(response))
}
