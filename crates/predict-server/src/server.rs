use crate::error::PredictError;
use crate::metrics::middleware::track_metrics;
use crate::metrics::RpcMetrics;
use crate::reader::{PositionAggregateRow, Reader};
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
use std::collections::{HashMap, HashSet};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::str::FromStr;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use sui_futures::service::Service;
use sui_indexer_alt_metrics::{MetricsArgs, MetricsService};
use sui_json_rpc_types::{SuiObjectData, SuiObjectDataOptions, SuiParsedData, SuiParsedMoveObject};
use sui_pg_db::DbArgs;
use sui_sdk::SuiClientBuilder;
use sui_types::base_types::{ObjectID, SequenceNumber, SuiAddress};
use sui_types::programmable_transaction_builder::ProgrammableTransactionBuilder;
use sui_types::transaction::{
    Argument, CallArg, Command, ObjectArg, ProgrammableMoveCall, TransactionKind,
};
use sui_types::type_input::TypeInput;
use sui_types::TypeTag;
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
pub const MANAGER_SUMMARY_PATH: &str = "/managers/:manager_id/summary";
pub const MANAGER_POSITION_SUMMARY_PATH: &str = "/managers/:manager_id/positions/summary";
pub const MANAGER_PNL_PATH: &str = "/managers/:manager_id/pnl";
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
pub const PREDICT_ORACLES_PATH: &str = "/predicts/:predict_id/oracles";
pub const PREDICT_VAULT_SUMMARY_PATH: &str = "/predicts/:predict_id/vault/summary";
pub const PREDICT_VAULT_PERFORMANCE_PATH: &str = "/predicts/:predict_id/vault/performance";

const SUI_CLOCK_OBJECT_ID: &str =
    "0x0000000000000000000000000000000000000000000000000000000000000006";
const PREDICT_PRICE_SCALE: i64 = 1_000_000_000;

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
        .route(MANAGER_SUMMARY_PATH, get(get_manager_summary))
        .route(
            MANAGER_POSITION_SUMMARY_PATH,
            get(get_manager_positions_summary),
        )
        .route(MANAGER_RANGES_PATH, get(get_manager_ranges))
        .route(MANAGER_PNL_PATH, get(get_manager_pnl))
        // Predict endpoints
        .route(PREDICT_QUOTE_ASSETS_PATH, get(get_predict_quote_assets))
        .route(PREDICT_STATE_PATH, get(get_predict_state))
        .route(PREDICT_ORACLES_PATH, get(get_predict_oracles))
        .route(PREDICT_VAULT_SUMMARY_PATH, get(get_predict_vault_summary))
        .route(
            PREDICT_VAULT_PERFORMANCE_PATH,
            get(get_predict_vault_performance),
        )
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

#[derive(Debug, Deserialize)]
pub struct RangeQueryParams {
    pub range: Option<String>,
}

// === Response types ===

#[derive(Clone, Serialize)]
pub struct OracleInfo {
    pub predict_id: String,
    pub oracle_id: String,
    pub oracle_cap_id: String,
    pub underlying_asset: String,
    pub expiry: i64,
    pub min_strike: i64,
    pub tick_size: i64,
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

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct PositionKey {
    oracle_id: String,
    expiry: i64,
    strike: i64,
    is_up: bool,
}

impl PositionKey {
    fn new(oracle_id: impl Into<String>, expiry: i64, strike: i64, is_up: bool) -> Self {
        Self {
            oracle_id: oracle_id.into(),
            expiry,
            strike,
            is_up,
        }
    }
}

#[derive(Clone, Debug)]
pub struct PositionMark {
    mark_value: i64,
    mark_price: i64,
}

#[derive(Serialize)]
pub struct ManagerPositionSummaryRow {
    pub predict_id: String,
    pub manager_id: String,
    pub quote_asset: String,
    pub oracle_id: String,
    pub underlying_asset: Option<String>,
    pub expiry: i64,
    pub strike: i64,
    pub is_up: bool,
    pub minted_quantity: i64,
    pub redeemed_quantity: i64,
    pub open_quantity: i64,
    pub total_cost: i64,
    pub total_payout: i64,
    pub realized_pnl: i64,
    pub unrealized_pnl: i64,
    pub open_cost_basis: i64,
    pub average_entry_price: Option<i64>,
    pub average_exit_price: Option<i64>,
    pub mark_price: Option<i64>,
    pub mark_value: Option<i64>,
    pub status: String,
    pub first_minted_at: i64,
    pub last_activity_at: i64,
}

#[derive(Serialize)]
pub struct AssetBalanceSummary {
    pub quote_asset: String,
    pub balance: i64,
}

#[derive(Serialize)]
pub struct ManagerSummaryResponse {
    pub manager_id: String,
    pub owner: String,
    pub balances: Vec<AssetBalanceSummary>,
    pub trading_balance: i64,
    pub open_exposure: i64,
    pub redeemable_value: i64,
    pub realized_pnl: i64,
    pub unrealized_pnl: i64,
    pub account_value: i64,
    pub open_positions: usize,
    pub awaiting_settlement_positions: usize,
}

#[derive(Serialize)]
pub struct VaultSummaryResponse {
    pub predict_id: String,
    pub quote_assets: Vec<String>,
    pub vault_balance: i64,
    pub vault_value: i64,
    pub total_mtm: i64,
    pub total_max_payout: i64,
    pub available_liquidity: i64,
    pub available_withdrawal: i64,
    pub plp_total_supply: i64,
    pub plp_share_price: f64,
    pub utilization: f64,
    pub max_payout_utilization: f64,
    pub net_deposits: i64,
    pub total_supplied: i64,
    pub total_withdrawn: i64,
}

#[derive(Clone, Serialize)]
pub struct VaultPerformancePoint {
    pub timestamp_ms: i64,
    pub share_price: f64,
    pub vault_value: i64,
    pub total_shares: i64,
}

#[derive(Serialize)]
pub struct VaultPerformanceResponse {
    pub predict_id: String,
    pub range: String,
    pub points: Vec<VaultPerformancePoint>,
}

#[derive(Clone, Serialize)]
pub struct ManagerPnlPoint {
    pub timestamp_ms: i64,
    pub realized_pnl: i64,
    pub cumulative_realized_pnl: i64,
}

#[derive(Serialize)]
pub struct ManagerPnlResponse {
    pub manager_id: String,
    pub range: String,
    pub series_type: String,
    pub points: Vec<ManagerPnlPoint>,
    pub current_unrealized_pnl: i64,
    pub current_total_pnl: i64,
}

#[derive(Clone)]
struct SharedMoveObjectContext {
    object_id: ObjectID,
    shared_version: SequenceNumber,
    package_id: ObjectID,
    parsed: SuiParsedMoveObject,
}

#[derive(Clone)]
struct PredictSnapshot {
    quote_assets: Vec<String>,
    vault_balance: i64,
    total_mtm: i64,
    total_max_payout: i64,
    available_liquidity: i64,
    available_withdrawal: i64,
    plp_total_supply: i64,
    plp_share_price: f64,
    utilization: f64,
    max_payout_utilization: f64,
}

#[derive(Serialize)]
struct MarketKeyCallArg {
    oracle_id: ObjectID,
    expiry: u64,
    strike: u64,
    direction: u8,
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

fn current_time_ms() -> Result<i64, PredictError> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| PredictError::internal("System time error"))?
        .as_millis() as i64)
}

fn normalize_type_tag(type_str: &str) -> String {
    if type_str.starts_with("0x") || type_str.starts_with("0X") {
        type_str.to_string()
    } else {
        format!("0x{}", type_str)
    }
}

fn parse_type_input(type_str: &str) -> Result<TypeInput, PredictError> {
    let type_tag = TypeTag::from_str(&normalize_type_tag(type_str))
        .map_err(|e| PredictError::internal(format!("invalid type tag {}: {}", type_str, e)))?;
    Ok(TypeInput::from(type_tag))
}

fn clock_object_arg() -> Result<CallArg, PredictError> {
    Ok(CallArg::Object(ObjectArg::SharedObject {
        id: ObjectID::from_hex_literal(SUI_CLOCK_OBJECT_ID)
            .map_err(|e| PredictError::internal(format!("invalid clock object id: {}", e)))?,
        initial_shared_version: SequenceNumber::from_u64(1),
        mutability: sui_types::transaction::SharedObjectMutability::Immutable,
    }))
}

fn u64_to_i64(value: u64, field: &str) -> Result<i64, PredictError> {
    i64::try_from(value).map_err(|_| PredictError::internal(format!("{} exceeds i64 range", field)))
}

fn json_at_path<'a>(
    value: &'a serde_json::Value,
    path: &[&str],
) -> Result<&'a serde_json::Value, PredictError> {
    let mut current = value;
    for segment in path {
        current = current
            .get(*segment)
            .ok_or_else(|| PredictError::internal(format!("missing field {}", path.join("."))))?;
    }
    Ok(current)
}

fn json_bool(value: &serde_json::Value, path: &[&str]) -> Result<bool, PredictError> {
    json_at_path(value, path)?
        .as_bool()
        .ok_or_else(|| PredictError::internal(format!("field {} is not a bool", path.join("."))))
}

fn json_u64(value: &serde_json::Value, path: &[&str]) -> Result<u64, PredictError> {
    let raw = json_at_path(value, path)?;
    if let Some(number) = raw.as_u64() {
        return Ok(number);
    }

    raw.as_str()
        .ok_or_else(|| PredictError::internal(format!("field {} is not numeric", path.join("."))))?
        .parse::<u64>()
        .map_err(|e| {
            PredictError::internal(format!("invalid integer at {}: {}", path.join("."), e))
        })
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
        predict_id: created.predict_id,
        oracle_id: created.oracle_id,
        oracle_cap_id: created.oracle_cap_id,
        underlying_asset: created.underlying_asset,
        expiry: created.expiry,
        min_strike: created.min_strike,
        tick_size: created.tick_size,
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

fn position_status_rank(status: &str) -> i32 {
    match status {
        "awaiting_settlement" => 0,
        "active" => 1,
        "redeemable" => 2,
        "lost" => 3,
        "redeemed" => 4,
        _ => 5,
    }
}

fn scale_position_price(amount: i64, quantity: i64) -> Option<i64> {
    if quantity <= 0 {
        return None;
    }

    let scaled = i128::from(amount)
        .checked_mul(i128::from(PREDICT_PRICE_SCALE))?
        .checked_div(i128::from(quantity))?;

    i64::try_from(scaled).ok()
}

fn build_position_summary_rows(
    aggregates: Vec<PositionAggregateRow>,
    oracle_infos: &HashMap<String, OracleInfo>,
    marks: &HashMap<PositionKey, PositionMark>,
    current_time_ms: i64,
) -> Vec<ManagerPositionSummaryRow> {
    let mut rows = aggregates
        .into_iter()
        .map(|aggregate| {
            let minted_quantity = aggregate.minted_quantity.max(0);
            let redeemed_quantity = aggregate.redeemed_quantity.max(0).min(minted_quantity);
            let open_quantity = minted_quantity - redeemed_quantity;
            let closed_cost_basis = if minted_quantity > 0 {
                aggregate.total_cost * redeemed_quantity / minted_quantity
            } else {
                0
            };
            let open_cost_basis = aggregate.total_cost - closed_cost_basis;
            let realized_pnl = aggregate.total_payout - closed_cost_basis;
            let average_entry_price = scale_position_price(aggregate.total_cost, minted_quantity);
            let average_exit_price =
                scale_position_price(aggregate.total_payout, redeemed_quantity);

            let position_key = PositionKey::new(
                aggregate.oracle_id.clone(),
                aggregate.expiry,
                aggregate.strike,
                aggregate.is_up,
            );
            let mark = if open_quantity > 0 {
                marks.get(&position_key)
            } else {
                None
            };
            let mark_value = mark.map(|value| value.mark_value);
            let mark_price = mark.map(|value| value.mark_price);
            let unrealized_pnl = if open_quantity > 0 {
                mark_value.unwrap_or(0) - open_cost_basis
            } else {
                0
            };

            let oracle_info = oracle_infos.get(&aggregate.oracle_id);
            let status = if open_quantity == 0 {
                "redeemed".to_string()
            } else if oracle_info
                .as_ref()
                .map(|info| info.status.as_str() == "settled")
                .unwrap_or(false)
            {
                if mark_value.unwrap_or(0) > 0 {
                    "redeemable".to_string()
                } else {
                    "lost".to_string()
                }
            } else if current_time_ms >= aggregate.expiry {
                "awaiting_settlement".to_string()
            } else {
                "active".to_string()
            };

            ManagerPositionSummaryRow {
                predict_id: aggregate.predict_id,
                manager_id: aggregate.manager_id,
                quote_asset: aggregate.quote_asset,
                oracle_id: aggregate.oracle_id.clone(),
                underlying_asset: oracle_info.map(|info| info.underlying_asset.clone()),
                expiry: aggregate.expiry,
                strike: aggregate.strike,
                is_up: aggregate.is_up,
                minted_quantity,
                redeemed_quantity,
                open_quantity,
                total_cost: aggregate.total_cost,
                total_payout: aggregate.total_payout,
                realized_pnl,
                unrealized_pnl,
                open_cost_basis,
                average_entry_price,
                average_exit_price,
                mark_price,
                mark_value,
                status,
                first_minted_at: aggregate.first_minted_at,
                last_activity_at: aggregate.last_activity_at,
            }
        })
        .collect::<Vec<_>>();

    rows.sort_by_key(|row| {
        (
            position_status_rank(&row.status),
            row.expiry,
            row.strike,
            if row.is_up { 0 } else { 1 },
        )
    });
    rows
}

fn build_manager_summary_response(
    manager: &PredictManagerCreatedRow,
    balances: Vec<AssetBalanceSummary>,
    positions: &[ManagerPositionSummaryRow],
) -> ManagerSummaryResponse {
    let trading_balance = balances.iter().map(|balance| balance.balance).sum::<i64>();
    let open_exposure = positions
        .iter()
        .filter(|position| position.open_quantity > 0)
        .map(|position| position.open_cost_basis)
        .sum::<i64>();
    let redeemable_value = positions
        .iter()
        .filter(|position| position.status == "redeemable")
        .map(|position| position.mark_value.unwrap_or(0))
        .sum::<i64>();
    let realized_pnl = positions
        .iter()
        .map(|position| position.realized_pnl)
        .sum::<i64>();
    let unrealized_pnl = positions
        .iter()
        .map(|position| position.unrealized_pnl)
        .sum::<i64>();
    let account_value = trading_balance
        + positions
            .iter()
            .filter(|position| position.open_quantity > 0)
            .map(|position| position.mark_value.unwrap_or(0))
            .sum::<i64>();

    ManagerSummaryResponse {
        manager_id: manager.manager_id.clone(),
        owner: manager.owner.clone(),
        balances,
        trading_balance,
        open_exposure,
        redeemable_value,
        realized_pnl,
        unrealized_pnl,
        account_value,
        open_positions: positions
            .iter()
            .filter(|position| position.open_quantity > 0)
            .count(),
        awaiting_settlement_positions: positions
            .iter()
            .filter(|position| position.status == "awaiting_settlement")
            .count(),
    }
}

fn build_vault_performance_points(
    supplies: Vec<SuppliedRow>,
    withdrawals: Vec<WithdrawnRow>,
    snapshot_timestamp_ms: i64,
    snapshot_share_price: f64,
    snapshot_vault_value: i64,
    snapshot_total_shares: i64,
) -> Vec<VaultPerformancePoint> {
    #[derive(Clone)]
    struct VaultEvent {
        timestamp_ms: i64,
        tx_index: i64,
        event_index: i64,
        amount_delta: i64,
        shares_delta: i64,
    }

    let mut events = supplies
        .into_iter()
        .map(|row| VaultEvent {
            timestamp_ms: row.checkpoint_timestamp_ms,
            tx_index: row.tx_index,
            event_index: row.event_index,
            amount_delta: row.amount,
            shares_delta: row.shares_minted,
        })
        .chain(withdrawals.into_iter().map(|row| VaultEvent {
            timestamp_ms: row.checkpoint_timestamp_ms,
            tx_index: row.tx_index,
            event_index: row.event_index,
            amount_delta: -row.amount,
            shares_delta: -row.shares_burned,
        }))
        .collect::<Vec<_>>();

    events.sort_by_key(|event| (event.timestamp_ms, event.tx_index, event.event_index));

    let mut vault_value = 0i64;
    let mut total_shares = 0i64;
    let mut points = Vec::with_capacity(events.len() + 1);

    for event in events {
        vault_value += event.amount_delta;
        total_shares += event.shares_delta;
        let share_price = if event.shares_delta != 0 {
            (event.amount_delta.abs() as f64) / (event.shares_delta.abs() as f64)
        } else if total_shares > 0 {
            vault_value as f64 / total_shares as f64
        } else {
            1.0
        };

        points.push(VaultPerformancePoint {
            timestamp_ms: event.timestamp_ms,
            share_price,
            vault_value,
            total_shares,
        });
    }

    points.push(VaultPerformancePoint {
        timestamp_ms: snapshot_timestamp_ms,
        share_price: snapshot_share_price,
        vault_value: snapshot_vault_value,
        total_shares: snapshot_total_shares,
    });

    points
}

fn compute_realized_pnl_points(
    minted: Vec<PositionMintedRow>,
    redeemed: Vec<PositionRedeemedRow>,
    start_time_ms: Option<i64>,
) -> Vec<ManagerPnlPoint> {
    enum PositionEvent {
        Mint(PositionMintedRow),
        Redeem(PositionRedeemedRow),
    }

    let mut events = minted
        .into_iter()
        .map(PositionEvent::Mint)
        .chain(redeemed.into_iter().map(PositionEvent::Redeem))
        .collect::<Vec<_>>();

    events.sort_by_key(|event| match event {
        PositionEvent::Mint(row) => (row.checkpoint, row.tx_index, row.event_index),
        PositionEvent::Redeem(row) => (row.checkpoint, row.tx_index, row.event_index),
    });

    let mut open_books: HashMap<PositionKey, (i64, i64)> = HashMap::new();
    let mut cumulative_realized_pnl = 0i64;
    let mut points = Vec::new();

    for event in events {
        match event {
            PositionEvent::Mint(row) => {
                let entry = open_books
                    .entry(PositionKey::new(
                        row.oracle_id,
                        row.expiry,
                        row.strike,
                        row.is_up,
                    ))
                    .or_insert((0, 0));
                entry.0 += row.quantity;
                entry.1 += row.cost;
            }
            PositionEvent::Redeem(row) => {
                let key =
                    PositionKey::new(row.oracle_id.clone(), row.expiry, row.strike, row.is_up);
                let entry = open_books.entry(key).or_insert((0, 0));
                let available_qty = entry.0.max(0);
                let quantity = row.quantity.max(0).min(available_qty);
                let cost_basis = if available_qty > 0 {
                    entry.1 * quantity / available_qty
                } else {
                    0
                };
                entry.0 -= quantity;
                entry.1 -= cost_basis;
                let realized_pnl = row.payout - cost_basis;
                cumulative_realized_pnl += realized_pnl;

                if start_time_ms
                    .map(|start| row.checkpoint_timestamp_ms >= start)
                    .unwrap_or(true)
                {
                    points.push(ManagerPnlPoint {
                        timestamp_ms: row.checkpoint_timestamp_ms,
                        realized_pnl,
                        cumulative_realized_pnl,
                    });
                }
            }
        }
    }

    points
}

fn range_start_time(range: Option<&str>, now_ms: i64) -> Option<i64> {
    let day_ms = 24 * 60 * 60 * 1000;
    match range.unwrap_or("ALL").to_ascii_uppercase().as_str() {
        "1D" => Some(now_ms - day_ms),
        "1W" => Some(now_ms - 7 * day_ms),
        "1M" => Some(now_ms - 30 * day_ms),
        "3M" => Some(now_ms - 90 * day_ms),
        "ALL" => None,
        _ => None,
    }
}

fn normalized_range_label(range: Option<&str>) -> String {
    range.unwrap_or("ALL").to_ascii_uppercase()
}

async fn fetch_shared_move_object(
    state: &AppState,
    object_id: &str,
) -> Result<SharedMoveObjectContext, PredictError> {
    let object_id = ObjectID::from_hex_literal(object_id)
        .map_err(|e| PredictError::internal(format!("invalid object id {}: {}", object_id, e)))?;
    let response = state
        .sui_client()
        .await?
        .read_api()
        .get_object_with_options(object_id, SuiObjectDataOptions::full_content().with_owner())
        .await
        .map_err(|e| {
            PredictError::internal(format!("failed to fetch object {}: {}", object_id, e))
        })?;

    let data: &SuiObjectData = response
        .data
        .as_ref()
        .ok_or_else(|| PredictError::not_found(format!("object {}", object_id.to_hex_literal())))?;

    let shared_version = match &data.owner {
        Some(sui_types::object::Owner::Shared {
            initial_shared_version,
        }) => *initial_shared_version,
        _ => {
            return Err(PredictError::internal(format!(
                "object {} is not shared",
                object_id.to_hex_literal()
            )))
        }
    };

    let parsed = match data.content.as_ref() {
        Some(SuiParsedData::MoveObject(object)) => object.clone(),
        _ => {
            return Err(PredictError::internal(format!(
                "object {} is not a move object",
                object_id.to_hex_literal()
            )))
        }
    };

    Ok(SharedMoveObjectContext {
        object_id: data.object_id,
        shared_version,
        package_id: ObjectID::from(parsed.type_.address),
        parsed,
    })
}

fn shared_object_call_arg(context: &SharedMoveObjectContext) -> CallArg {
    CallArg::Object(ObjectArg::SharedObject {
        id: context.object_id,
        initial_shared_version: context.shared_version,
        mutability: sui_types::transaction::SharedObjectMutability::Immutable,
    })
}

fn extract_u64_result(
    results: &[sui_json_rpc_types::SuiExecutionResult],
    result_index: usize,
    return_value_index: usize,
    label: &str,
) -> Result<u64, PredictError> {
    let result = results.get(result_index).ok_or_else(|| {
        PredictError::internal(format!(
            "missing result {} at index {}",
            label, result_index
        ))
    })?;
    let return_value = result
        .return_values
        .get(return_value_index)
        .ok_or_else(|| {
            PredictError::internal(format!(
                "missing return value {} at index {}",
                label, return_value_index
            ))
        })?;

    bcs::from_bytes::<u64>(&return_value.0)
        .map_err(|e| PredictError::internal(format!("failed to decode {}: {}", label, e)))
}

async fn fetch_predict_snapshot(
    state: &AppState,
    predict_id: &str,
    fallback_quote_assets: Vec<String>,
) -> Result<PredictSnapshot, PredictError> {
    let context = fetch_shared_move_object(state, predict_id).await?;
    let fields = context.parsed.fields.clone().to_json_value();

    let quote_assets =
        match json_at_path(&fields, &["treasury_config", "accepted_quotes", "contents"]) {
            Ok(value) => value
                .as_array()
                .map(|items| {
                    items
                        .iter()
                        .filter_map(|item| {
                            item.get("name")
                                .and_then(|name| name.as_str())
                                .map(ToString::to_string)
                        })
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default(),
            Err(_) => fallback_quote_assets,
        };

    let vault_balance = u64_to_i64(json_u64(&fields, &["vault", "balance"])?, "vault.balance")?;
    let total_mtm = u64_to_i64(
        json_u64(&fields, &["vault", "total_mtm"])?,
        "vault.total_mtm",
    )?;
    let total_max_payout = u64_to_i64(
        json_u64(&fields, &["vault", "total_max_payout"])?,
        "vault.total_max_payout",
    )?;
    let plp_total_supply = u64_to_i64(
        json_u64(&fields, &["treasury_cap", "total_supply", "value"])?,
        "treasury_cap.total_supply",
    )?;
    let limiter_enabled = json_bool(&fields, &["withdrawal_limiter", "enabled"])?;
    let limiter_available = json_u64(&fields, &["withdrawal_limiter", "available"])?;
    let limiter_capacity = json_u64(&fields, &["withdrawal_limiter", "capacity"])?;
    let refill_rate_per_ms = json_u64(&fields, &["withdrawal_limiter", "refill_rate_per_ms"])?;
    let last_updated_ms = json_u64(&fields, &["withdrawal_limiter", "last_updated_ms"])?;

    let now_ms = current_time_ms()? as u64;
    let limiter_available_now = if limiter_enabled {
        let elapsed = now_ms.saturating_sub(last_updated_ms);
        let refill = (elapsed as u128) * (refill_rate_per_ms as u128);
        ((limiter_available as u128) + refill).min(limiter_capacity as u128) as u64
    } else {
        u64::MAX
    };

    let available_liquidity = (vault_balance - total_max_payout).max(0);
    let available_withdrawal = u64_to_i64(
        limiter_available_now.min(available_liquidity.max(0) as u64),
        "available_withdrawal",
    )?;
    let vault_value = (vault_balance - total_mtm).max(0);
    let plp_share_price = if plp_total_supply > 0 {
        vault_value as f64 / plp_total_supply as f64
    } else {
        1.0
    };
    let utilization = if vault_balance > 0 {
        total_mtm as f64 / vault_balance as f64
    } else {
        0.0
    };
    let max_payout_utilization = if vault_balance > 0 {
        total_max_payout as f64 / vault_balance as f64
    } else {
        0.0
    };

    Ok(PredictSnapshot {
        quote_assets,
        vault_balance,
        total_mtm,
        total_max_payout,
        available_liquidity,
        available_withdrawal,
        plp_total_supply,
        plp_share_price,
        utilization,
        max_payout_utilization,
    })
}

async fn fetch_manager_balances(
    state: &AppState,
    manager_id: &str,
    quote_assets: &[String],
) -> Result<Vec<AssetBalanceSummary>, PredictError> {
    let deduped = quote_assets
        .iter()
        .cloned()
        .collect::<HashSet<_>>()
        .into_iter()
        .collect::<Vec<_>>();

    if deduped.is_empty() {
        return Ok(Vec::new());
    }

    let context = fetch_shared_move_object(state, manager_id).await?;
    let mut ptb = ProgrammableTransactionBuilder::new();
    ptb.input(shared_object_call_arg(&context))
        .map_err(|e| PredictError::internal(format!("failed to add manager input: {}", e)))?;

    for quote_asset in &deduped {
        ptb.command(Command::MoveCall(Box::new(ProgrammableMoveCall {
            package: context.package_id,
            module: "predict_manager".to_string(),
            function: "balance".to_string(),
            type_arguments: vec![parse_type_input(quote_asset)?],
            arguments: vec![Argument::Input(0)],
        })));
    }

    let tx = TransactionKind::ProgrammableTransaction(ptb.finish());
    let result = state
        .sui_client()
        .await?
        .read_api()
        .dev_inspect_transaction_block(SuiAddress::default(), tx, None, None, None)
        .await
        .map_err(|e| {
            PredictError::internal(format!("manager balance dev inspect failed: {}", e))
        })?;
    let results = result.results.ok_or_else(|| {
        PredictError::internal("missing results from manager balance dev inspect")
    })?;

    deduped
        .iter()
        .enumerate()
        .map(|(index, quote_asset)| {
            let balance = extract_u64_result(&results, index, 0, quote_asset)?;
            Ok(AssetBalanceSummary {
                quote_asset: quote_asset.clone(),
                balance: u64_to_i64(balance, quote_asset)?,
            })
        })
        .collect()
}

async fn quote_position_marks(
    state: &AppState,
    positions: &[PositionAggregateRow],
) -> Result<HashMap<PositionKey, PositionMark>, PredictError> {
    let mut grouped: HashMap<String, Vec<&PositionAggregateRow>> = HashMap::new();
    for position in positions
        .iter()
        .filter(|position| position.minted_quantity - position.redeemed_quantity > 0)
    {
        grouped
            .entry(position.predict_id.clone())
            .or_default()
            .push(position);
    }

    let mut marks = HashMap::new();
    for (predict_id, predict_positions) in grouped {
        let predict_context = fetch_shared_move_object(state, &predict_id).await?;
        let mut ptb = ProgrammableTransactionBuilder::new();
        ptb.input(shared_object_call_arg(&predict_context))
            .map_err(|e| PredictError::internal(format!("failed to add predict input: {}", e)))?;
        ptb.input(clock_object_arg()?)
            .map_err(|e| PredictError::internal(format!("failed to add clock input: {}", e)))?;

        let mut oracle_input_indexes = HashMap::new();
        for oracle_id in predict_positions
            .iter()
            .map(|position| position.oracle_id.clone())
            .collect::<HashSet<_>>()
        {
            let oracle_context = fetch_shared_move_object(state, &oracle_id).await?;
            let input_index = ptb
                .input(shared_object_call_arg(&oracle_context))
                .map_err(|e| {
                    PredictError::internal(format!("failed to add oracle input: {}", e))
                })?;
            oracle_input_indexes.insert(oracle_id, input_index);
        }

        let mut call_positions = Vec::new();
        for position in predict_positions {
            let open_quantity = position.minted_quantity - position.redeemed_quantity;
            if open_quantity <= 0 {
                continue;
            }

            let key_bytes = bcs::to_bytes(&MarketKeyCallArg {
                oracle_id: ObjectID::from_hex_literal(&position.oracle_id).map_err(|e| {
                    PredictError::internal(format!(
                        "invalid oracle id {}: {}",
                        position.oracle_id, e
                    ))
                })?,
                expiry: u64::try_from(position.expiry)
                    .map_err(|_| PredictError::internal("negative expiry on position"))?,
                strike: u64::try_from(position.strike)
                    .map_err(|_| PredictError::internal("negative strike on position"))?,
                direction: if position.is_up { 0 } else { 1 },
            })
            .map_err(|e| PredictError::internal(format!("failed to encode market key: {}", e)))?;
            let key_input = ptb.input(CallArg::Pure(key_bytes)).map_err(|e| {
                PredictError::internal(format!("failed to add market key input: {}", e))
            })?;
            let quantity_input = ptb
                .input(CallArg::Pure(
                    bcs::to_bytes(
                        &u64::try_from(open_quantity)
                            .map_err(|_| PredictError::internal("negative open quantity"))?,
                    )
                    .map_err(|e| {
                        PredictError::internal(format!("failed to encode quantity: {}", e))
                    })?,
                ))
                .map_err(|e| {
                    PredictError::internal(format!("failed to add quantity input: {}", e))
                })?;

            let oracle_input = *oracle_input_indexes
                .get(&position.oracle_id)
                .ok_or_else(|| PredictError::internal("missing oracle input index"))?;

            ptb.command(Command::MoveCall(Box::new(ProgrammableMoveCall {
                package: predict_context.package_id,
                module: "predict".to_string(),
                function: "get_trade_amounts".to_string(),
                type_arguments: vec![],
                arguments: vec![
                    Argument::Input(0),
                    oracle_input,
                    key_input,
                    quantity_input,
                    Argument::Input(1),
                ],
            })));

            call_positions.push((
                PositionKey::new(
                    position.oracle_id.clone(),
                    position.expiry,
                    position.strike,
                    position.is_up,
                ),
                open_quantity,
            ));
        }

        if call_positions.is_empty() {
            continue;
        }

        let tx = TransactionKind::ProgrammableTransaction(ptb.finish());
        let result = state
            .sui_client()
            .await?
            .read_api()
            .dev_inspect_transaction_block(SuiAddress::default(), tx, None, None, None)
            .await
            .map_err(|e| PredictError::internal(format!("mark quote dev inspect failed: {}", e)))?;
        let results = result
            .results
            .ok_or_else(|| PredictError::internal("missing mark quote results"))?;

        for (index, (key, quantity)) in call_positions.into_iter().enumerate() {
            let payout = extract_u64_result(&results, index, 1, "redeem_payout")?;
            let mark_value = u64_to_i64(payout, "redeem_payout")?;
            marks.insert(
                key,
                PositionMark {
                    mark_value,
                    mark_price: scale_position_price(mark_value, quantity).unwrap_or(0),
                },
            );
        }
    }

    Ok(marks)
}

async fn load_oracle_infos_for_ids(
    state: &Arc<AppState>,
    oracle_ids: &[String],
) -> Result<HashMap<String, OracleInfo>, PredictError> {
    let mut infos = HashMap::new();
    for oracle_id in oracle_ids {
        let created = state.reader.get_oracle_created(oracle_id).await?;
        let activated = state.reader.get_latest_oracle_activated(oracle_id).await?;
        let settled = state.reader.get_latest_oracle_settled(oracle_id).await?;
        infos.insert(
            oracle_id.clone(),
            build_oracle_info(created, activated.as_ref(), settled.as_ref()),
        );
    }
    Ok(infos)
}

async fn load_manager_position_summaries(
    state: &Arc<AppState>,
    manager_id: &str,
) -> Result<Vec<ManagerPositionSummaryRow>, PredictError> {
    let aggregates = state
        .reader
        .get_position_aggregates_for_manager(manager_id)
        .await?;
    let oracle_ids = aggregates
        .iter()
        .map(|row| row.oracle_id.clone())
        .collect::<HashSet<_>>()
        .into_iter()
        .collect::<Vec<_>>();
    let oracle_infos = load_oracle_infos_for_ids(state, &oracle_ids).await?;
    let marks = quote_position_marks(state, &aggregates).await?;
    let now_ms = current_time_ms()?;
    Ok(build_position_summary_rows(
        aggregates,
        &oracle_infos,
        &marks,
        now_ms,
    ))
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

async fn get_manager_positions_summary(
    Path(manager_id): Path<String>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<ManagerPositionSummaryRow>>, PredictError> {
    state.reader.get_manager(&manager_id).await?;
    Ok(Json(
        load_manager_position_summaries(&state, &manager_id).await?,
    ))
}

async fn get_manager_summary(
    Path(manager_id): Path<String>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<ManagerSummaryResponse>, PredictError> {
    let manager = state.reader.get_manager(&manager_id).await?;
    let positions = load_manager_position_summaries(&state, &manager_id).await?;
    let quote_assets = state.reader.get_all_enabled_quote_assets().await?;
    let balances = fetch_manager_balances(&state, &manager_id, &quote_assets).await?;

    Ok(Json(build_manager_summary_response(
        &manager, balances, &positions,
    )))
}

async fn get_manager_ranges(
    Path(manager_id): Path<String>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<ManagerRanges>, PredictError> {
    let (minted, redeemed) = state.reader.get_ranges_for_manager(&manager_id).await?;
    Ok(Json(ManagerRanges { minted, redeemed }))
}

async fn get_manager_pnl(
    Path(manager_id): Path<String>,
    Query(params): Query<RangeQueryParams>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<ManagerPnlResponse>, PredictError> {
    state.reader.get_manager(&manager_id).await?;
    let now_ms = current_time_ms()?;
    let start_time_ms = range_start_time(params.range.as_deref(), now_ms);
    let positions = load_manager_position_summaries(&state, &manager_id).await?;
    let minted = state
        .reader
        .get_all_positions_minted_for_manager(&manager_id)
        .await?;
    let redeemed = state
        .reader
        .get_all_positions_redeemed_for_manager(&manager_id)
        .await?;
    let points = compute_realized_pnl_points(minted, redeemed, start_time_ms);
    let current_unrealized_pnl = positions.iter().map(|row| row.unrealized_pnl).sum::<i64>();
    let current_realized_pnl = positions.iter().map(|row| row.realized_pnl).sum::<i64>();

    Ok(Json(ManagerPnlResponse {
        manager_id,
        range: normalized_range_label(params.range.as_deref()),
        series_type: "realized_pnl".to_string(),
        points,
        current_unrealized_pnl,
        current_total_pnl: current_realized_pnl + current_unrealized_pnl,
    }))
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

async fn get_predict_oracles(
    Path(predict_id): Path<String>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<OracleInfo>>, PredictError> {
    let created = state
        .reader
        .get_oracles_created_for_predict(&predict_id)
        .await?;
    let activated = state.reader.get_oracles_activated().await?;
    let settled = state.reader.get_oracles_settled().await?;

    Ok(Json(assemble_oracle_infos(created, activated, settled)))
}

async fn get_predict_vault_summary(
    Path(predict_id): Path<String>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<VaultSummaryResponse>, PredictError> {
    let quote_assets = state.reader.get_enabled_quote_assets(&predict_id).await?;
    let snapshot = fetch_predict_snapshot(&state, &predict_id, quote_assets.clone()).await?;
    let supplies = state
        .reader
        .get_lp_supplies_for_predict(&predict_id)
        .await?;
    let withdrawals = state
        .reader
        .get_lp_withdrawals_for_predict(&predict_id)
        .await?;
    let total_supplied = supplies.iter().map(|row| row.amount).sum::<i64>();
    let total_withdrawn = withdrawals.iter().map(|row| row.amount).sum::<i64>();

    Ok(Json(VaultSummaryResponse {
        predict_id,
        quote_assets: if snapshot.quote_assets.is_empty() {
            quote_assets
        } else {
            snapshot.quote_assets
        },
        vault_balance: snapshot.vault_balance,
        vault_value: (snapshot.vault_balance - snapshot.total_mtm).max(0),
        total_mtm: snapshot.total_mtm,
        total_max_payout: snapshot.total_max_payout,
        available_liquidity: snapshot.available_liquidity,
        available_withdrawal: snapshot.available_withdrawal,
        plp_total_supply: snapshot.plp_total_supply,
        plp_share_price: snapshot.plp_share_price,
        utilization: snapshot.utilization,
        max_payout_utilization: snapshot.max_payout_utilization,
        net_deposits: total_supplied - total_withdrawn,
        total_supplied,
        total_withdrawn,
    }))
}

async fn get_predict_vault_performance(
    Path(predict_id): Path<String>,
    Query(params): Query<RangeQueryParams>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<VaultPerformanceResponse>, PredictError> {
    let quote_assets = state.reader.get_enabled_quote_assets(&predict_id).await?;
    let snapshot = fetch_predict_snapshot(&state, &predict_id, quote_assets).await?;
    let now_ms = current_time_ms()?;
    let start_time_ms = range_start_time(params.range.as_deref(), now_ms);
    let supplies = state
        .reader
        .get_lp_supplies_for_predict(&predict_id)
        .await?
        .into_iter()
        .filter(|row| {
            start_time_ms
                .map(|start| row.checkpoint_timestamp_ms >= start)
                .unwrap_or(true)
        })
        .collect::<Vec<_>>();
    let withdrawals = state
        .reader
        .get_lp_withdrawals_for_predict(&predict_id)
        .await?
        .into_iter()
        .filter(|row| {
            start_time_ms
                .map(|start| row.checkpoint_timestamp_ms >= start)
                .unwrap_or(true)
        })
        .collect::<Vec<_>>();

    let points = build_vault_performance_points(
        supplies,
        withdrawals,
        now_ms,
        snapshot.plp_share_price,
        (snapshot.vault_balance - snapshot.total_mtm).max(0),
        snapshot.plp_total_supply,
    );

    Ok(Json(VaultPerformanceResponse {
        predict_id,
        range: normalized_range_label(params.range.as_deref()),
        points,
    }))
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
    use predict_schema::models::{
        OracleActivatedRow, OracleCreatedRow, OracleSettledRow, SuppliedRow, WithdrawnRow,
    };
    use std::collections::HashMap;

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
            predict_id: "0xpredict".into(),
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
        assert_eq!(infos[0].predict_id, "0xpredict");
        assert_eq!(infos[0].underlying_asset, "BTC");
        assert_eq!(infos[0].min_strike, 50);
        assert_eq!(infos[0].tick_size, 1);
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

    #[test]
    fn build_position_summary_rows_tracks_open_and_realized_pnl() {
        let aggregates = vec![
            PositionAggregateRow {
                predict_id: "0xpredict".into(),
                manager_id: "0xmanager".into(),
                quote_asset: "0x2::sui::SUI".into(),
                oracle_id: "0xoracle-live".into(),
                expiry: 1_700_000_100_000,
                strike: 65_000,
                is_up: true,
                minted_quantity: 10_000_000,
                redeemed_quantity: 4_000_000,
                total_cost: 7_000_000,
                total_payout: 2_800_000,
                first_minted_at: 1_000,
                last_activity_at: 2_000,
            },
            PositionAggregateRow {
                predict_id: "0xpredict".into(),
                manager_id: "0xmanager".into(),
                quote_asset: "0x2::sui::SUI".into(),
                oracle_id: "0xoracle-settled".into(),
                expiry: 1_700_000_200_000,
                strike: 66_000,
                is_up: false,
                minted_quantity: 5_000_000,
                redeemed_quantity: 0,
                total_cost: 200_000,
                total_payout: 0,
                first_minted_at: 3_000,
                last_activity_at: 3_000,
            },
        ];
        let oracle_infos = HashMap::from([
            (
                "0xoracle-live".to_string(),
                OracleInfo {
                    predict_id: "0xpredict".into(),
                    oracle_id: "0xoracle-live".into(),
                    oracle_cap_id: "0xcap-live".into(),
                    underlying_asset: "BTC".into(),
                    expiry: 1_700_000_100_000,
                    min_strike: 60_000,
                    tick_size: 500,
                    status: "active".into(),
                    activated_at: Some(1_500),
                    settlement_price: None,
                    settled_at: None,
                    created_checkpoint: 10,
                },
            ),
            (
                "0xoracle-settled".to_string(),
                OracleInfo {
                    predict_id: "0xpredict".into(),
                    oracle_id: "0xoracle-settled".into(),
                    oracle_cap_id: "0xcap-settled".into(),
                    underlying_asset: "BTC".into(),
                    expiry: 1_700_000_200_000,
                    min_strike: 60_000,
                    tick_size: 500,
                    status: "settled".into(),
                    activated_at: Some(1_500),
                    settlement_price: Some(1_000_000_000),
                    settled_at: Some(4_000),
                    created_checkpoint: 11,
                },
            ),
        ]);
        let marks = HashMap::from([
            (
                PositionKey::new("0xoracle-live", 1_700_000_100_000, 65_000, true),
                PositionMark {
                    mark_value: 4_200_000,
                    mark_price: 700_000_000,
                },
            ),
            (
                PositionKey::new("0xoracle-settled", 1_700_000_200_000, 66_000, false),
                PositionMark {
                    mark_value: 500_000,
                    mark_price: 100_000_000,
                },
            ),
        ]);

        let rows =
            build_position_summary_rows(aggregates, &oracle_infos, &marks, 1_700_000_150_000);

        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].status, "awaiting_settlement");
        assert_eq!(rows[0].open_quantity, 6_000_000);
        assert_eq!(rows[0].realized_pnl, 0);
        assert_eq!(rows[0].unrealized_pnl, 0);
        assert_eq!(rows[0].average_entry_price, Some(700_000_000));
        assert_eq!(rows[0].average_exit_price, Some(700_000_000));
        assert_eq!(rows[0].mark_price, Some(700_000_000));
        assert_eq!(rows[0].mark_value, Some(4_200_000));
        assert_eq!(rows[1].status, "redeemable");
        assert_eq!(rows[1].open_quantity, 5_000_000);
        assert_eq!(rows[1].realized_pnl, 0);
        assert_eq!(rows[1].unrealized_pnl, 300_000);
        assert_eq!(rows[1].average_entry_price, Some(40_000_000));
        assert_eq!(rows[1].mark_price, Some(100_000_000));
    }

    #[test]
    fn scale_position_price_restores_fixed_point_units() {
        assert_eq!(
            scale_position_price(47_833_202, 100_000_000),
            Some(478_332_020)
        );
        assert_eq!(
            scale_position_price(43_089_546, 100_000_000),
            Some(430_895_460)
        );
        assert_eq!(scale_position_price(0, 100_000_000), Some(0));
        assert_eq!(scale_position_price(1, 0), None);
    }

    #[test]
    fn build_vault_performance_points_orders_events_and_appends_snapshot() {
        let supplies = vec![
            SuppliedRow {
                event_digest: "supply-0".into(),
                digest: "digest-supply-0".into(),
                sender: "0xsender".into(),
                checkpoint: 1,
                checkpoint_timestamp_ms: 1_000,
                tx_index: 0,
                event_index: 0,
                package: "0xpackage".into(),
                predict_id: "0xpredict".into(),
                supplier: "0xlp".into(),
                quote_asset: "0x2::sui::SUI".into(),
                amount: 100,
                shares_minted: 100,
            },
            SuppliedRow {
                event_digest: "supply-1".into(),
                digest: "digest-supply-1".into(),
                sender: "0xsender".into(),
                checkpoint: 3,
                checkpoint_timestamp_ms: 3_000,
                tx_index: 0,
                event_index: 0,
                package: "0xpackage".into(),
                predict_id: "0xpredict".into(),
                supplier: "0xlp".into(),
                quote_asset: "0x2::sui::SUI".into(),
                amount: 120,
                shares_minted: 100,
            },
        ];
        let withdrawals = vec![WithdrawnRow {
            event_digest: "withdraw-0".into(),
            digest: "digest-withdraw-0".into(),
            sender: "0xsender".into(),
            checkpoint: 2,
            checkpoint_timestamp_ms: 2_000,
            tx_index: 0,
            event_index: 0,
            package: "0xpackage".into(),
            predict_id: "0xpredict".into(),
            withdrawer: "0xlp".into(),
            quote_asset: "0x2::sui::SUI".into(),
            amount: 55,
            shares_burned: 50,
        }];

        let points = build_vault_performance_points(supplies, withdrawals, 4_000, 1.3, 260, 200);

        assert_eq!(points.len(), 4);
        assert_eq!(points[0].timestamp_ms, 1_000);
        assert!((points[0].share_price - 1.0).abs() < f64::EPSILON);
        assert_eq!(points[1].timestamp_ms, 2_000);
        assert!((points[1].share_price - 1.1).abs() < 1e-9);
        assert_eq!(points[2].timestamp_ms, 3_000);
        assert!((points[2].share_price - 1.2).abs() < 1e-9);
        assert_eq!(points[3].timestamp_ms, 4_000);
        assert!((points[3].share_price - 1.3).abs() < 1e-9);
        assert_eq!(points[3].vault_value, 260);
        assert_eq!(points[3].total_shares, 200);
    }
}
