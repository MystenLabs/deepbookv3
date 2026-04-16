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
    OracleAskBoundsSetRow, OraclePricesUpdatedRow, OracleSviUpdatedRow,
    PositionMintedRow, PositionRedeemedRow, PredictManagerCreatedRow, RangeMintedRow,
    RangeRedeemedRow, SuppliedRow, WithdrawnRow,
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
use tokio::net::TcpListener;
use tokio::sync::oneshot;
use tower_http::cors::{AllowMethods, Any, CorsLayer};
use url::Url;

// === Path constants ===

pub const HEALTH_PATH: &str = "/health";
pub const ORACLES_PATH: &str = "/oracles";
pub const ORACLE_PRICES_PATH: &str = "/oracles/:oracle_id/prices";
pub const ORACLE_LATEST_PRICE_PATH: &str = "/oracles/:oracle_id/prices/latest";
pub const ORACLE_SVI_PATH: &str = "/oracles/:oracle_id/svi";
pub const ORACLE_LATEST_SVI_PATH: &str = "/oracles/:oracle_id/svi/latest";
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

// === AppState ===

#[derive(Clone)]
pub struct AppState {
    reader: Reader,
    metrics: Arc<RpcMetrics>,
}

impl AppState {
    pub async fn new(
        database_url: Url,
        args: DbArgs,
        registry: &Registry,
    ) -> Result<Self, anyhow::Error> {
        let metrics = RpcMetrics::new(registry);
        let reader = Reader::new(database_url, args, metrics.clone(), registry).await?;
        Ok(Self { reader, metrics })
    }

    pub(crate) fn metrics(&self) -> &RpcMetrics {
        &self.metrics
    }
}

// === Server lifecycle ===

pub async fn run_server(
    server_port: u16,
    database_url: Url,
    db_arg: DbArgs,
    metrics_address: SocketAddr,
) -> Result<(), anyhow::Error> {
    let registry = Registry::new_custom(Some("predict_api".into()), None)
        .expect("Failed to create Prometheus registry.");

    let metrics = MetricsService::new(MetricsArgs { metrics_address }, registry);

    let state = AppState::new(database_url, db_arg, metrics.registry()).await?;
    let socket_address = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(0, 0, 0, 0)), server_port);

    println!("Predict server started successfully on port {}", server_port);

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
    pub pricing: Option<serde_json::Value>,
    pub risk: Option<serde_json::Value>,
    pub trading_paused: Option<bool>,
}

// === Default helpers ===

fn default_limit(limit: Option<i64>) -> i64 {
    limit.unwrap_or(100)
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

    let activated_map: HashMap<String, i64> = activated
        .into_iter()
        .map(|a| (a.oracle_id.clone(), a.onchain_timestamp))
        .collect();

    let settled_map: HashMap<String, (i64, i64)> = settled
        .into_iter()
        .map(|s| {
            (
                s.oracle_id.clone(),
                (s.settlement_price, s.onchain_timestamp),
            )
        })
        .collect();

    let oracles: Vec<OracleInfo> = created
        .into_iter()
        .map(|c| {
            let is_settled = settled_map.contains_key(&c.oracle_id);
            let is_activated = activated_map.contains_key(&c.oracle_id);

            let status = if is_settled {
                "settled"
            } else if is_activated {
                "active"
            } else {
                "created"
            }
            .to_string();

            OracleInfo {
                oracle_id: c.oracle_id.clone(),
                oracle_cap_id: c.oracle_cap_id,
                expiry: c.expiry,
                status,
                activated_at: activated_map.get(&c.oracle_id).copied(),
                settlement_price: settled_map.get(&c.oracle_id).map(|(p, _)| *p),
                settled_at: settled_map.get(&c.oracle_id).map(|(_, t)| *t),
                created_checkpoint: c.checkpoint,
            }
        })
        .collect();

    Ok(Json(oracles))
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

    // Interleave mints and redeems by checkpoint descending
    let mut events: Vec<TradeEvent> = Vec::with_capacity(mints.len() + redeems.len());
    events.extend(mints.into_iter().map(TradeEvent::Mint));
    events.extend(redeems.into_iter().map(TradeEvent::Redeem));

    events.sort_by(|a, b| {
        let cp_a = match a {
            TradeEvent::Mint(m) => m.checkpoint,
            TradeEvent::Redeem(r) => r.checkpoint,
        };
        let cp_b = match b {
            TradeEvent::Mint(m) => m.checkpoint,
            TradeEvent::Redeem(r) => r.checkpoint,
        };
        cp_b.cmp(&cp_a)
    });

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
    let managers = state
        .reader
        .get_managers(params.owner.as_deref())
        .await?;

    Ok(Json(managers))
}

async fn get_manager_positions(
    Path(manager_id): Path<String>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<ManagerPositions>, PredictError> {
    let (minted, redeemed) = state
        .reader
        .get_positions_for_manager(&manager_id)
        .await?;

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

// -- System endpoints --

async fn get_status(
    State(state): State<Arc<AppState>>,
) -> Result<Json<serde_json::Value>, PredictError> {
    let watermarks = state.reader.get_watermarks().await?;

    let current_time_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| PredictError::internal("System time error"))?
        .as_millis() as i64;

    let pipelines: Vec<serde_json::Value> = watermarks
        .iter()
        .map(|(pipeline, checkpoint, timestamp_ms, epoch)| {
            let time_lag_ms = current_time_ms - timestamp_ms;
            serde_json::json!({
                "pipeline": pipeline,
                "checkpoint_hi_inclusive": checkpoint,
                "timestamp_ms_hi_inclusive": timestamp_ms,
                "epoch_hi_inclusive": epoch,
                "time_lag_ms": time_lag_ms,
                "time_lag_seconds": time_lag_ms / 1000,
            })
        })
        .collect();

    Ok(Json(serde_json::json!({
        "status": "ok",
        "current_time_ms": current_time_ms,
        "pipelines": pipelines,
    })))
}

async fn get_config(
    State(state): State<Arc<AppState>>,
) -> Result<Json<ConfigResponse>, PredictError> {
    let pricing = state
        .reader
        .get_latest_pricing_config()
        .await
        .ok()
        .and_then(|p| serde_json::to_value(p).ok());

    let risk = state
        .reader
        .get_latest_risk_config()
        .await
        .ok()
        .and_then(|r| serde_json::to_value(r).ok());

    let trading_paused = state
        .reader
        .get_trading_pause_status()
        .await
        .ok()
        .map(|t| t.paused);

    Ok(Json(ConfigResponse {
        pricing,
        risk,
        trading_paused,
    }))
}
