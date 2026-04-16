use crate::schema::{
    oracle_activated, oracle_ask_bounds_cleared, oracle_ask_bounds_set, oracle_created,
    oracle_prices_updated, oracle_settled, oracle_svi_updated, position_minted,
    position_redeemed, predict_created, predict_manager_created, pricing_config_updated,
    quote_asset_disabled, quote_asset_enabled, range_minted, range_redeemed, risk_config_updated,
    supplied, trading_pause_updated, withdrawn,
};
use diesel::{Identifiable, Insertable, Queryable, Selectable};
use serde::Serialize;
use sui_field_count::FieldCount;

// === Oracle tables ===

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = oracle_activated, primary_key(event_digest))]
pub struct OracleActivatedRow {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub oracle_id: String,
    pub expiry: i64,
    pub onchain_timestamp: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = oracle_settled, primary_key(event_digest))]
pub struct OracleSettledRow {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub oracle_id: String,
    pub expiry: i64,
    pub settlement_price: i64,
    pub onchain_timestamp: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = oracle_prices_updated, primary_key(event_digest))]
pub struct OraclePricesUpdatedRow {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub oracle_id: String,
    pub spot: i64,
    pub forward: i64,
    pub onchain_timestamp: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = oracle_svi_updated, primary_key(event_digest))]
pub struct OracleSviUpdatedRow {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub oracle_id: String,
    pub a: i64,
    pub b: i64,
    pub rho: i64,
    pub rho_negative: bool,
    pub m: i64,
    pub m_negative: bool,
    pub sigma: i64,
    pub onchain_timestamp: i64,
}

// === Registry tables ===

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = predict_created, primary_key(event_digest))]
pub struct PredictCreatedRow {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub predict_id: String,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = oracle_created, primary_key(event_digest))]
pub struct OracleCreatedRow {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub oracle_id: String,
    pub oracle_cap_id: String,
    pub underlying_asset: String,
    pub expiry: i64,
    pub min_strike: i64,
    pub tick_size: i64,
}

// === Trading tables ===

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = position_minted, primary_key(event_digest))]
pub struct PositionMintedRow {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub predict_id: String,
    pub manager_id: String,
    pub trader: String,
    pub quote_asset: String,
    pub oracle_id: String,
    pub expiry: i64,
    pub strike: i64,
    pub is_up: bool,
    pub quantity: i64,
    pub cost: i64,
    pub ask_price: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = position_redeemed, primary_key(event_digest))]
pub struct PositionRedeemedRow {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub predict_id: String,
    pub manager_id: String,
    pub owner: String,
    pub executor: String,
    pub quote_asset: String,
    pub oracle_id: String,
    pub expiry: i64,
    pub strike: i64,
    pub is_up: bool,
    pub quantity: i64,
    pub payout: i64,
    pub bid_price: i64,
    pub is_settled: bool,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = range_minted, primary_key(event_digest))]
pub struct RangeMintedRow {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub predict_id: String,
    pub manager_id: String,
    pub trader: String,
    pub quote_asset: String,
    pub oracle_id: String,
    pub expiry: i64,
    pub lower_strike: i64,
    pub higher_strike: i64,
    pub quantity: i64,
    pub cost: i64,
    pub ask_price: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = range_redeemed, primary_key(event_digest))]
pub struct RangeRedeemedRow {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub predict_id: String,
    pub manager_id: String,
    pub trader: String,
    pub quote_asset: String,
    pub oracle_id: String,
    pub expiry: i64,
    pub lower_strike: i64,
    pub higher_strike: i64,
    pub quantity: i64,
    pub payout: i64,
    pub bid_price: i64,
    pub is_settled: bool,
}

// === LP vault tables ===

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = supplied, primary_key(event_digest))]
pub struct SuppliedRow {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub predict_id: String,
    pub supplier: String,
    pub quote_asset: String,
    pub amount: i64,
    pub shares_minted: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = withdrawn, primary_key(event_digest))]
pub struct WithdrawnRow {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub predict_id: String,
    pub withdrawer: String,
    pub quote_asset: String,
    pub amount: i64,
    pub shares_burned: i64,
}

// === Admin tables ===

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = trading_pause_updated, primary_key(event_digest))]
pub struct TradingPauseUpdatedRow {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub predict_id: String,
    pub paused: bool,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = pricing_config_updated, primary_key(event_digest))]
pub struct PricingConfigUpdatedRow {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub predict_id: String,
    pub base_spread: i64,
    pub min_spread: i64,
    pub utilization_multiplier: i64,
    pub min_ask_price: i64,
    pub max_ask_price: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = risk_config_updated, primary_key(event_digest))]
pub struct RiskConfigUpdatedRow {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub predict_id: String,
    pub max_total_exposure_pct: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = oracle_ask_bounds_set, primary_key(event_digest))]
pub struct OracleAskBoundsSetRow {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub predict_id: String,
    pub oracle_id: String,
    pub min_ask_price: i64,
    pub max_ask_price: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = oracle_ask_bounds_cleared, primary_key(event_digest))]
pub struct OracleAskBoundsClearedRow {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub predict_id: String,
    pub oracle_id: String,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = quote_asset_enabled, primary_key(event_digest))]
pub struct QuoteAssetEnabledRow {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub predict_id: String,
    pub quote_asset: String,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = quote_asset_disabled, primary_key(event_digest))]
pub struct QuoteAssetDisabledRow {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub predict_id: String,
    pub quote_asset: String,
}

// === User tables ===

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = predict_manager_created, primary_key(event_digest))]
pub struct PredictManagerCreatedRow {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub manager_id: String,
    pub owner: String,
}
