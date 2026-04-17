use crate::error::PredictError;
use crate::metrics::middleware::track_metrics;
use crate::metrics::RpcMetrics;
use crate::reader::Reader;
use axum::extract::{Path, Query, State};
use axum::http::{Method, StatusCode};
use axum::middleware::from_fn_with_state;
use axum::routing::get;
use axum::{Json, Router};
use predict_schema::models::{
    OracleAskBoundsSetRow, OraclePricesUpdatedRow, OracleSviUpdatedRow, PositionMintedRow,
    PositionRedeemedRow, PredictManagerCreatedRow, RangeMintedRow, RangeRedeemedRow, SuppliedRow,
    WithdrawnRow,
};
use prometheus::Registry;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use sui_futures::service::Service;
use sui_indexer_alt_metrics::{MetricsArgs, MetricsService};
use sui_pg_db::DbArgs;
use sui_sdk::SuiClientBuilder;
use tokio::net::TcpListener;
use tokio::sync::{oneshot, OnceCell};
use tower_http::cors::{AllowMethods, Any, CorsLayer};
use url::Url;

// === Path constants ===

pub const HEALTH_PATH: &str = "/health";
pub const ORACLES_PATH: &str = "/oracles";
pub const ORACLE_PRICES_PATH: &str = "/oracles/:oracle_id/prices";
pub const ORACLE_LATEST_PRICE_PATH: &str = "/oracles/:oracle_id/prices/latest";
pub const ORACLE_SVI_PATH: &str = "/oracles/:oracle_id/svi";
pub const ORACLE_LATEST_SVI_PATH: &str = "/oracles/:oracle_id/svi/latest";
pub const ORACLE_STATE_PATH: &str = "/oracles/:oracle_id/state";
pub const POSITIONS_MINTED_PATH: &str = "/positions/minted";
pub const POSITIONS_REDEEMED_PATH: &str = "/positions/redeemed";
pub const TRADES_PATH: &str = "/trades/:oracle_id";
pub const MANAGERS_PATH: &str = "/managers";
pub const MANAGER_POSITIONS_PATH: &str = "/managers/:manager_id/positions";
pub const STATUS_PATH: &str = "/status";
pub const CONFIG_PATH: &str = "/config";

pub const RANGES_MINTED_PATH: &str = "/ranges/minted";
pub const RANGES_REDEEMED_PATH: &str = "/ranges/redeemed";
pub const MANAGER_RANGES_PATH: &str = "/managers/:manager_id/ranges";
pub const LP_SUPPLIES_PATH: &str = "/lp/supplies";
pub const LP_WITHDRAWALS_PATH: &str = "/lp/withdrawals";
pub const ORACLE_ASK_BOUNDS_PATH: &str = "/oracles/:oracle_id/ask-bounds";
pub const PREDICT_QUOTE_ASSETS_PATH: &str = "/predicts/:predict_id/quote-assets";
pub const PREDICT_STATE_PATH: &str = "/predicts/:predict_id/state";

// === AppState ===

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
        rpc_url: Url,
        registry: &Registry,
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

    pub(crate) fn metrics(&self) -> &RpcMetrics {
        &self.metrics
    }

    pub async fn sui_client(&self) -> Result<&sui_sdk::SuiClient, PredictError> {
        self.sui_client
            .get_or_try_init(|| async {
                SuiClientBuilder::default()
                    .build(self.rpc_url.as_str())
                    .await
            })
            .await
            .map_err(|e| PredictError::internal(format!("failed to build Sui client: {}", e)))
    }
}

// === Server lifecycle ===

pub async fn run_server(
    server_port: u16,
    database_url: Url,
    db_arg: DbArgs,
    metrics_address: SocketAddr,
    rpc_url: Url,
) -> Result<(), anyhow::Error> {
    let registry = Registry::new_custom(Some("predict_api".into()), None)
        .expect("Failed to create Prometheus registry.");

    let metrics = MetricsService::new(MetricsArgs { metrics_address }, registry);

    let state = AppState::new(database_url, db_arg, rpc_url, metrics.registry()).await?;
    let socket_address = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(0, 0, 0, 0)), server_port);

    println!(
        "Predict server started successfully on port {}",
        server_port
    );

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
        .allow_methods(AllowMethods::list(vec![Method::GET, Method::OPTIONS]))
        .allow_headers(Any)
        .allow_origin(Any);

    let routes = Router::new()
        .route("/", get(health_check))
        .route(HEALTH_PATH, get(health_check))
        // Oracle endpoints
        .route(ORACLES_PATH, get(get_oracles))
        .route(ORACLE_PRICES_PATH, get(get_oracle_prices))
        .route(ORACLE_LATEST_PRICE_PATH, get(get_oracle_latest_price))
        .route(ORACLE_SVI_PATH, get(get_oracle_svi))
        .route(ORACLE_LATEST_SVI_PATH, get(get_oracle_latest_svi))
        .route(ORACLE_STATE_PATH, get(get_oracle_state))
        .route(ORACLE_ASK_BOUNDS_PATH, get(get_oracle_ask_bounds))
        // Trading endpoints
        .route(POSITIONS_MINTED_PATH, get(get_positions_minted))
        .route(POSITIONS_REDEEMED_PATH, get(get_positions_redeemed))
        .route(RANGES_MINTED_PATH, get(get_ranges_minted))
        .route(RANGES_REDEEMED_PATH, get(get_ranges_redeemed))
        .route(TRADES_PATH, get(get_trades))
        // LP endpoints
        .route(LP_SUPPLIES_PATH, get(get_lp_supplies))
        .route(LP_WITHDRAWALS_PATH, get(get_lp_withdrawals))
        // User endpoints
        .route(MANAGERS_PATH, get(get_managers))
        .route(MANAGER_POSITIONS_PATH, get(get_manager_positions))
        .route(MANAGER_RANGES_PATH, get(get_manager_ranges))
        // Predict endpoints
        .route(PREDICT_QUOTE_ASSETS_PATH, get(get_predict_quote_assets))
        .route(PREDICT_STATE_PATH, get(get_predict_state))
        // System endpoints
        .route(STATUS_PATH, get(get_status))
        .route(CONFIG_PATH, get(get_config))
        .with_state(state.clone());

    routes
        .layer(cors)
        .layer(from_fn_with_state(state, track_metrics))
}

// === Query parameter types ===

#[derive(Debug, Deserialize)]
pub struct PaginationParams {
    pub limit: Option<i64>,
    pub start_time: Option<i64>,
    pub end_time: Option<i64>,
}

#[derive(Debug, Deserialize)]
pub struct PositionFilterParams {
    pub oracle_id: Option<String>,
    pub trader: Option<String>,
    pub manager_id: Option<String>,
    pub limit: Option<i64>,
}

#[derive(Debug, Deserialize)]
pub struct ManagerFilterParams {
    pub owner: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct LimitParams {
    pub limit: Option<i64>,
}

#[derive(Debug, Deserialize)]
pub struct LpFilterParams {
    pub supplier: Option<String>,
    pub withdrawer: Option<String>,
    pub limit: Option<i64>,
}

#[derive(Debug, Deserialize)]
pub struct StatusQueryParams {
    #[serde(default = "default_max_checkpoint_lag")]
    pub max_checkpoint_lag: i64,
    #[serde(default = "default_max_time_lag_seconds")]
    pub max_time_lag_seconds: i64,
}

// === Response types ===

#[derive(Serialize)]
pub struct OracleInfo {
    pub oracle_id: String,
    pub oracle_cap_id: String,
    pub expiry: i64,
    pub status: String,
    pub activated_at: Option<i64>,
    pub settlement_price: Option<i64>,
    pub settled_at: Option<i64>,
    pub created_checkpoint: i64,
}

#[derive(Serialize)]
#[serde(tag = "type")]
pub enum TradeEvent {
    #[serde(rename = "mint")]
    Mint(PositionMintedRow),
    #[serde(rename = "redeem")]
    Redeem(PositionRedeemedRow),
}

#[derive(Serialize)]
pub struct ManagerPositions {
    pub minted: Vec<PositionMintedRow>,
    pub redeemed: Vec<PositionRedeemedRow>,
}

#[derive(Serialize)]
pub struct ManagerRanges {
    pub minted: Vec<RangeMintedRow>,
    pub redeemed: Vec<RangeRedeemedRow>,
}

#[derive(Serialize)]
pub struct ConfigResponse {
    pub predict_id: String,
    pub pricing: Option<serde_json::Value>,
    pub risk: Option<serde_json::Value>,
    pub trading_paused: Option<bool>,
    pub quote_assets: Vec<String>,
}

#[derive(Serialize)]
pub struct OracleStateResponse {
    pub oracle: OracleInfo,
    pub latest_price: Option<OraclePricesUpdatedRow>,
    pub latest_svi: Option<OracleSviUpdatedRow>,
    pub ask_bounds: Option<OracleAskBoundsSetRow>,
}

// === Default helpers ===

fn default_limit(limit: Option<i64>) -> i64 {
    limit.unwrap_or(100)
}

fn default_max_checkpoint_lag() -> i64 {
    100
}

fn default_max_time_lag_seconds() -> i64 {
    60
}

fn build_oracle_info(
    created: predict_schema::models::OracleCreatedRow,
    activated: Option<&predict_schema::models::OracleActivatedRow>,
    settled: Option<&predict_schema::models::OracleSettledRow>,
) -> OracleInfo {
    let status = if settled.is_some() {
        "settled"
    } else if activated.is_some() {
        "active"
    } else {
        "created"
    }
    .to_string();

    OracleInfo {
        oracle_id: created.oracle_id,
        oracle_cap_id: created.oracle_cap_id,
        expiry: created.expiry,
        status,
        activated_at: activated.as_ref().map(|row| row.onchain_timestamp),
        settlement_price: settled.as_ref().map(|row| row.settlement_price),
        settled_at: settled.as_ref().map(|row| row.onchain_timestamp),
        created_checkpoint: created.checkpoint,
    }
}

fn assemble_oracle_infos(
    created: Vec<predict_schema::models::OracleCreatedRow>,
    activated: Vec<predict_schema::models::OracleActivatedRow>,
    settled: Vec<predict_schema::models::OracleSettledRow>,
) -> Vec<OracleInfo> {
    let activated_map: HashMap<String, predict_schema::models::OracleActivatedRow> = activated
        .into_iter()
        .map(|row| (row.oracle_id.clone(), row))
        .collect();

    let settled_map: HashMap<String, predict_schema::models::OracleSettledRow> = settled
        .into_iter()
        .map(|row| (row.oracle_id.clone(), row))
        .collect();

    created
        .into_iter()
        .map(|created_row| {
            let oracle_id = created_row.oracle_id.clone();
            build_oracle_info(
                created_row,
                activated_map.get(&oracle_id),
                settled_map.get(&oracle_id),
            )
        })
        .collect()
}

fn build_predict_state_response(
    predict_id: String,
    pricing: Option<serde_json::Value>,
    risk: Option<serde_json::Value>,
    trading_paused: Option<bool>,
    quote_assets: Vec<String>,
) -> ConfigResponse {
    ConfigResponse {
        predict_id,
        pricing,
        risk,
        trading_paused,
        quote_assets,
    }
}

fn build_status_payload(
    current_time_ms: i64,
    latest_onchain_checkpoint: i64,
    watermarks: Vec<(String, i64, i64, i64)>,
    params: &StatusQueryParams,
) -> serde_json::Value {
    let mut pipelines = Vec::new();
    let mut min_checkpoint = i64::MAX;
    let mut max_lag_pipeline_name = String::new();
    let mut max_checkpoint_lag = 0i64;

    for (pipeline, checkpoint_hi, timestamp_ms_hi, epoch_hi) in watermarks {
        let checkpoint_lag = latest_onchain_checkpoint - checkpoint_hi;
        let time_lag_ms = current_time_ms - timestamp_ms_hi;
        let time_lag_seconds = time_lag_ms / 1000;
        let is_backfill = pipeline.contains("@backfill");

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
            "checkpoint_hi_inclusive": checkpoint_hi,
            "timestamp_ms_hi_inclusive": timestamp_ms_hi,
            "epoch_hi_inclusive": epoch_hi,
            "checkpoint_lag": checkpoint_lag,
            "time_lag_ms": time_lag_ms,
            "time_lag_seconds": time_lag_seconds,
            "latest_onchain_checkpoint": latest_onchain_checkpoint,
            "is_backfill": is_backfill,
        }));
    }

    let max_time_lag_seconds = pipelines
        .iter()
        .filter_map(|pipeline| {
            if pipeline["is_backfill"].as_bool() == Some(true) {
                None
            } else {
                pipeline["time_lag_seconds"].as_i64()
            }
        })
        .max()
        .unwrap_or(0);

    let earliest_checkpoint = if min_checkpoint == i64::MAX {
        0
    } else {
        min_checkpoint
    };

    let is_healthy = max_checkpoint_lag < params.max_checkpoint_lag
        && max_time_lag_seconds < params.max_time_lag_seconds;

    serde_json::json!({
        "status": if is_healthy { "OK" } else { "UNHEALTHY" },
        "latest_onchain_checkpoint": latest_onchain_checkpoint,
        "current_time_ms": current_time_ms,
        "earliest_checkpoint": earliest_checkpoint,
        "max_lag_pipeline": max_lag_pipeline_name,
        "max_checkpoint_lag": max_checkpoint_lag,
        "max_time_lag_seconds": max_time_lag_seconds,
        "pipelines": pipelines,
    })
}

fn trade_sort_key(event: &TradeEvent) -> (i64, i64, i64) {
    match event {
        TradeEvent::Mint(row) => (row.checkpoint, row.tx_index, row.event_index),
        TradeEvent::Redeem(row) => (row.checkpoint, row.tx_index, row.event_index),
    }
}

// === Handlers ===

async fn health_check() -> StatusCode {
    StatusCode::OK
}

// -- Oracle endpoints --

async fn get_oracles(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<OracleInfo>>, PredictError> {
    let created = state.reader.get_oracles_created().await?;
    let activated = state.reader.get_oracles_activated().await?;
    let settled = state.reader.get_oracles_settled().await?;

    Ok(Json(assemble_oracle_infos(created, activated, settled)))
}

async fn get_oracle_prices(
    Path(oracle_id): Path<String>,
    Query(params): Query<PaginationParams>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<OraclePricesUpdatedRow>>, PredictError> {
    let prices = state
        .reader
        .get_oracle_prices(
            &oracle_id,
            default_limit(params.limit),
            params.start_time,
            params.end_time,
        )
        .await?;

    Ok(Json(prices))
}

async fn get_oracle_latest_price(
    Path(oracle_id): Path<String>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<OraclePricesUpdatedRow>, PredictError> {
    let price = state.reader.get_oracle_latest_price(&oracle_id).await?;
    Ok(Json(price))
}

async fn get_oracle_svi(
    Path(oracle_id): Path<String>,
    Query(params): Query<LimitParams>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<OracleSviUpdatedRow>>, PredictError> {
    let svi = state
        .reader
        .get_oracle_svi(&oracle_id, default_limit(params.limit))
        .await?;

    Ok(Json(svi))
}

async fn get_oracle_latest_svi(
    Path(oracle_id): Path<String>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<OracleSviUpdatedRow>, PredictError> {
    let svi = state.reader.get_oracle_latest_svi(&oracle_id).await?;
    Ok(Json(svi))
}

async fn get_oracle_ask_bounds(
    Path(oracle_id): Path<String>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Option<OracleAskBoundsSetRow>>, PredictError> {
    let row_opt = state
        .reader
        .get_latest_oracle_ask_bounds(&oracle_id)
        .await?;
    Ok(Json(row_opt))
}

async fn get_oracle_state(
    Path(oracle_id): Path<String>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<OracleStateResponse>, PredictError> {
    let created = state.reader.get_oracle_created(&oracle_id).await?;
    let (activated, settled, latest_price, latest_svi, ask_bounds) = tokio::join!(
        state.reader.get_latest_oracle_activated(&oracle_id),
        state.reader.get_latest_oracle_settled(&oracle_id),
        state.reader.maybe_get_oracle_latest_price(&oracle_id),
        state.reader.maybe_get_oracle_latest_svi(&oracle_id),
        state.reader.get_latest_oracle_ask_bounds(&oracle_id),
    );

    let activated = activated?;
    let settled = settled?;
    Ok(Json(OracleStateResponse {
        oracle: build_oracle_info(created, activated.as_ref(), settled.as_ref()),
        latest_price: latest_price?,
        latest_svi: latest_svi?,
        ask_bounds: ask_bounds?,
    }))
}

// -- Trading endpoints --

async fn get_positions_minted(
    Query(params): Query<PositionFilterParams>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<PositionMintedRow>>, PredictError> {
    let positions = state
        .reader
        .get_positions_minted(
            params.oracle_id.as_deref(),
            params.trader.as_deref(),
            params.manager_id.as_deref(),
            default_limit(params.limit),
        )
        .await?;

    Ok(Json(positions))
}

async fn get_positions_redeemed(
    Query(params): Query<PositionFilterParams>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<PositionRedeemedRow>>, PredictError> {
    let positions = state
        .reader
        .get_positions_redeemed(
            params.oracle_id.as_deref(),
            params.trader.as_deref(),
            params.manager_id.as_deref(),
            default_limit(params.limit),
        )
        .await?;

    Ok(Json(positions))
}

async fn get_ranges_minted(
    Query(params): Query<PositionFilterParams>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<RangeMintedRow>>, PredictError> {
    let v = state
        .reader
        .get_ranges_minted(
            params.oracle_id.as_deref(),
            params.trader.as_deref(),
            params.manager_id.as_deref(),
            default_limit(params.limit),
        )
        .await?;
    Ok(Json(v))
}

async fn get_ranges_redeemed(
    Query(params): Query<PositionFilterParams>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<RangeRedeemedRow>>, PredictError> {
    let v = state
        .reader
        .get_ranges_redeemed(
            params.oracle_id.as_deref(),
            params.trader.as_deref(),
            params.manager_id.as_deref(),
            default_limit(params.limit),
        )
        .await?;
    Ok(Json(v))
}

async fn get_trades(
    Path(oracle_id): Path<String>,
    Query(params): Query<LimitParams>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<TradeEvent>>, PredictError> {
    let limit = default_limit(params.limit);

    let mints = state
        .reader
        .get_positions_minted(Some(&oracle_id), None, None, limit)
        .await?;

    let redeems = state
        .reader
        .get_positions_redeemed(Some(&oracle_id), None, None, limit)
        .await?;

    // Interleave mints and redeems by event order descending.
    let mut events: Vec<TradeEvent> = Vec::with_capacity(mints.len() + redeems.len());
    events.extend(mints.into_iter().map(TradeEvent::Mint));
    events.extend(redeems.into_iter().map(TradeEvent::Redeem));

    events.sort_by_key(|event| std::cmp::Reverse(trade_sort_key(event)));

    events.truncate(limit as usize);
    Ok(Json(events))
}

// -- LP endpoints --

async fn get_lp_supplies(
    Query(p): Query<LpFilterParams>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<SuppliedRow>>, PredictError> {
    let v = state
        .reader
        .get_lp_supplies(p.supplier.as_deref(), default_limit(p.limit))
        .await?;
    Ok(Json(v))
}

async fn get_lp_withdrawals(
    Query(p): Query<LpFilterParams>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<WithdrawnRow>>, PredictError> {
    let v = state
        .reader
        .get_lp_withdrawals(p.withdrawer.as_deref(), default_limit(p.limit))
        .await?;
    Ok(Json(v))
}

// -- User endpoints --

async fn get_managers(
    Query(params): Query<ManagerFilterParams>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<PredictManagerCreatedRow>>, PredictError> {
    let managers = state.reader.get_managers(params.owner.as_deref()).await?;

    Ok(Json(managers))
}

async fn get_manager_positions(
    Path(manager_id): Path<String>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<ManagerPositions>, PredictError> {
    let (minted, redeemed) = state.reader.get_positions_for_manager(&manager_id).await?;

    Ok(Json(ManagerPositions { minted, redeemed }))
}

async fn get_manager_ranges(
    Path(manager_id): Path<String>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<ManagerRanges>, PredictError> {
    let (minted, redeemed) = state.reader.get_ranges_for_manager(&manager_id).await?;
    Ok(Json(ManagerRanges { minted, redeemed }))
}

// -- Predict endpoints --

async fn get_predict_quote_assets(
    Path(predict_id): Path<String>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<String>>, PredictError> {
    let v = state.reader.get_enabled_quote_assets(&predict_id).await?;
    Ok(Json(v))
}

async fn get_predict_state(
    Path(predict_id): Path<String>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<ConfigResponse>, PredictError> {
    let (pricing, risk, trading_pause, quote_assets) = tokio::join!(
        state
            .reader
            .get_latest_pricing_config_for_predict(&predict_id),
        state.reader.get_latest_risk_config_for_predict(&predict_id),
        state
            .reader
            .get_trading_pause_status_for_predict(&predict_id),
        state.reader.get_enabled_quote_assets(&predict_id),
    );

    Ok(Json(build_predict_state_response(
        predict_id,
        pricing?
            .map(serde_json::to_value)
            .transpose()
            .map_err(|e| PredictError::internal(e.to_string()))?,
        risk?
            .map(serde_json::to_value)
            .transpose()
            .map_err(|e| PredictError::internal(e.to_string()))?,
        trading_pause?.map(|row| row.paused),
        quote_assets?,
    )))
}

// -- System endpoints --

async fn get_status(
    Query(params): Query<StatusQueryParams>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<serde_json::Value>, PredictError> {
    let watermarks = state.reader.get_watermarks().await?;
    let latest_checkpoint = state
        .sui_client()
        .await?
        .read_api()
        .get_latest_checkpoint_sequence_number()
        .await
        .map_err(|e| PredictError::internal(format!("failed to get latest checkpoint: {}", e)))?
        as i64;

    let current_time_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| PredictError::internal("System time error"))?
        .as_millis() as i64;

    Ok(Json(build_status_payload(
        current_time_ms,
        latest_checkpoint,
        watermarks,
        &params,
    )))
}

async fn get_config(
    State(state): State<Arc<AppState>>,
) -> Result<Json<ConfigResponse>, PredictError> {
    let predict = state.reader.get_latest_predict_created().await?;
    let predict_id = predict.predict_id;

    let (pricing, risk, trading_pause, quote_assets) = tokio::join!(
        state
            .reader
            .get_latest_pricing_config_for_predict(&predict_id),
        state.reader.get_latest_risk_config_for_predict(&predict_id),
        state
            .reader
            .get_trading_pause_status_for_predict(&predict_id),
        state.reader.get_enabled_quote_assets(&predict_id),
    );

    Ok(Json(build_predict_state_response(
        predict_id,
        pricing?
            .map(serde_json::to_value)
            .transpose()
            .map_err(|e| PredictError::internal(e.to_string()))?,
        risk?
            .map(serde_json::to_value)
            .transpose()
            .map_err(|e| PredictError::internal(e.to_string()))?,
        trading_pause?.map(|row| row.paused),
        quote_assets?,
    )))
}

#[cfg(test)]
mod tests {
    use super::*;
    use predict_schema::models::{OracleActivatedRow, OracleCreatedRow, OracleSettledRow};

    fn created_row() -> OracleCreatedRow {
        OracleCreatedRow {
            event_digest: "created-0".into(),
            digest: "digest-created".into(),
            sender: "0xsender".into(),
            checkpoint: 10,
            checkpoint_timestamp_ms: 1_000,
            tx_index: 0,
            event_index: 0,
            package: "0xpackage".into(),
            oracle_id: "0xoracle".into(),
            oracle_cap_id: "0xcap".into(),
            underlying_asset: "BTC".into(),
            expiry: 1_700_000_000_000,
            min_strike: 50,
            tick_size: 1,
        }
    }

    #[test]
    fn build_status_payload_ignores_backfill_pipelines() {
        let payload = build_status_payload(
            10_000,
            120,
            vec![
                ("oracle_prices_updated@backfill".into(), 5, 1_000, 1),
                ("oracle_prices_updated".into(), 115, 9_000, 1),
            ],
            &StatusQueryParams {
                max_checkpoint_lag: 10,
                max_time_lag_seconds: 5,
            },
        );

        assert_eq!(payload["status"], "OK");
        assert_eq!(payload["latest_onchain_checkpoint"], 120);
        assert_eq!(payload["max_lag_pipeline"], "oracle_prices_updated");
        assert_eq!(payload["max_checkpoint_lag"], 5);
    }

    #[test]
    fn assemble_oracle_infos_prefers_settled_status() {
        let infos = assemble_oracle_infos(
            vec![created_row()],
            vec![OracleActivatedRow {
                event_digest: "activated-0".into(),
                digest: "digest-activated".into(),
                sender: "0xsender".into(),
                checkpoint: 11,
                checkpoint_timestamp_ms: 2_000,
                tx_index: 0,
                event_index: 0,
                package: "0xpackage".into(),
                oracle_id: "0xoracle".into(),
                expiry: 1_700_000_000_000,
                onchain_timestamp: 2_500,
            }],
            vec![OracleSettledRow {
                event_digest: "settled-0".into(),
                digest: "digest-settled".into(),
                sender: "0xsender".into(),
                checkpoint: 12,
                checkpoint_timestamp_ms: 3_000,
                tx_index: 0,
                event_index: 0,
                package: "0xpackage".into(),
                oracle_id: "0xoracle".into(),
                expiry: 1_700_000_000_000,
                settlement_price: 123,
                onchain_timestamp: 3_500,
            }],
        );

        assert_eq!(infos.len(), 1);
        assert_eq!(infos[0].status, "settled");
        assert_eq!(infos[0].activated_at, Some(2_500));
        assert_eq!(infos[0].settlement_price, Some(123));
        assert_eq!(infos[0].settled_at, Some(3_500));
    }

    #[test]
    fn build_predict_state_response_keeps_predict_scope() {
        let response = build_predict_state_response(
            "0xpredict".into(),
            Some(serde_json::json!({ "predict_id": "0xpredict", "base_spread": 10 })),
            Some(serde_json::json!({ "predict_id": "0xpredict", "max_total_exposure_pct": 25 })),
            Some(true),
            vec!["0x2::sui::SUI".into()],
        );

        assert_eq!(response.predict_id, "0xpredict");
        assert_eq!(response.trading_paused, Some(true));
        assert_eq!(response.quote_assets, vec!["0x2::sui::SUI"]);
        assert_eq!(response.pricing.unwrap()["predict_id"], "0xpredict");
    }
}
