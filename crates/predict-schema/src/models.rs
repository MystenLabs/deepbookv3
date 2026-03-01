use crate::schema::{
    admin_vault_balance_changed, collateralized_position_minted,
    collateralized_position_redeemed, oracle_activated, oracle_created, oracle_prices_updated,
    oracle_settled, oracle_svi_updated, position_minted, position_redeemed, predict_created,
    predict_manager_created, pricing_config_updated, risk_config_updated, trading_pause_updated,
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
    pub risk_free_rate: i64,
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
    pub expiry: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = admin_vault_balance_changed, primary_key(event_digest))]
pub struct AdminVaultBalanceChangedRow {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub predict_id: String,
    pub amount: i64,
    pub deposit: bool,
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
    pub trader: String,
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
#[diesel(table_name = collateralized_position_minted, primary_key(event_digest))]
pub struct CollateralizedPositionMintedRow {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub predict_id: String,
    pub manager_id: String,
    pub trader: String,
    pub oracle_id: String,
    pub locked_expiry: i64,
    pub locked_strike: i64,
    pub locked_is_up: bool,
    pub minted_expiry: i64,
    pub minted_strike: i64,
    pub minted_is_up: bool,
    pub quantity: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = collateralized_position_redeemed, primary_key(event_digest))]
pub struct CollateralizedPositionRedeemedRow {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub predict_id: String,
    pub manager_id: String,
    pub trader: String,
    pub oracle_id: String,
    pub locked_expiry: i64,
    pub locked_strike: i64,
    pub locked_is_up: bool,
    pub minted_expiry: i64,
    pub minted_strike: i64,
    pub minted_is_up: bool,
    pub quantity: i64,
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
    pub max_skew_multiplier: i64,
    pub utilization_multiplier: i64,
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
