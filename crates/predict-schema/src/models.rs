use diesel::prelude::*;
use serde::{Deserialize, Serialize};
use crate::schema::*;

#[derive(Queryable, Selectable, Insertable, Serialize, Deserialize, Debug, Clone)]
#[diesel(table_name = predict_managers)]
pub struct PredictManager {
    pub object_id: String,
    pub owner_address: String,
    pub checkpoint: i64,
    pub timestamp: i64,
}

#[derive(Queryable, Selectable, Insertable, Serialize, Deserialize, Debug, Clone)]
#[diesel(table_name = predict_user_positions)]
pub struct PredictUserPosition {
    pub manager_id: String,
    pub oracle_id: String,
    pub expiry: i64,
    pub strike: i64,
    pub is_up: bool,
    pub free_quantity: i64,
    pub locked_quantity: i64,
    pub checkpoint: i64,
    pub timestamp: i64,
}

#[derive(Queryable, Selectable, Insertable, Serialize, Deserialize, Debug, Clone)]
#[diesel(table_name = predict_collateral)]
pub struct PredictCollateral {
    pub manager_id: String,
    pub oracle_id: String,
    pub expiry: i64,
    pub strike: i64,
    pub quantity: i64,
    pub checkpoint: i64,
    pub timestamp: i64,
}

#[derive(Queryable, Selectable, Insertable, Serialize, Deserialize, Debug, Clone)]
#[diesel(table_name = predict_oracles)]
pub struct PredictOracle {
    pub object_id: String,
    pub underlying_asset: String,
    pub pyth_lazer_feed_id: i32,
    pub expiry: i64,
    pub min_strike: i64,
    pub tick_size: i64,
    pub status: i16,
    pub settlement_price: Option<i64>,
    pub checkpoint: i64,
    pub timestamp: i64,
}

#[derive(Queryable, Selectable, Insertable, Serialize, Deserialize, Debug, Clone)]
#[diesel(table_name = predict_vaults)]
pub struct PredictVault {
    pub object_id: String,
    pub quote_asset: String,
    pub balance: i64,
    pub total_mtm: i64,
    pub total_max_payout: i64,
    pub total_lp_supply: i64,
    pub base_fee: i64,
    pub min_fee: i64,
    pub utilization_multiplier: i64,
    pub max_total_exposure_pct: i64,
    pub mtm_freshness_ms: i64,
    pub total_fees_accrued: i64,
    pub lp_fees_accrued: i64,
    pub protocol_fees_accrued: i64,
    pub insurance_fees_accrued: i64,
    pub trading_paused: bool,
    pub checkpoint: i64,
    pub timestamp: i64,
}

#[derive(Queryable, Selectable, Insertable, Serialize, Deserialize, Debug, Clone)]
#[diesel(table_name = predict_events_minted)]
pub struct PredictEventMinted {
    pub tx_digest: String,
    pub event_index: i64,
    pub checkpoint: i64,
    pub timestamp: i64,
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
    pub fee_amount: i64,
}

#[derive(Queryable, Selectable, Insertable, Serialize, Deserialize, Debug, Clone)]
#[diesel(table_name = predict_events_redeemed)]
pub struct PredictEventRedeemed {
    pub tx_digest: String,
    pub event_index: i64,
    pub checkpoint: i64,
    pub timestamp: i64,
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
    pub fee_amount: i64,
    pub is_settled: bool,
}

#[derive(Queryable, Selectable, Insertable, Serialize, Deserialize, Debug, Clone)]
#[diesel(table_name = predict_events_oracle_settled)]
pub struct PredictEventOracleSettled {
    pub tx_digest: String,
    pub event_index: i64,
    pub checkpoint: i64,
    pub timestamp: i64,
    pub oracle_id: String,
    pub expiry: i64,
    pub settlement_price: i64,
    pub spot_timestamp_ms: i64,
}

#[derive(Queryable, Selectable, Insertable, Serialize, Deserialize, Debug, Clone)]
#[diesel(table_name = predict_events_supplied)]
pub struct PredictEventSupplied {
    pub tx_digest: String,
    pub event_index: i64,
    pub checkpoint: i64,
    pub timestamp: i64,
    pub predict_id: String,
    pub supplier: String,
    pub quote_asset: String,
    pub amount: i64,
    pub shares_minted: i64,
}

#[derive(Queryable, Selectable, Insertable, Serialize, Deserialize, Debug, Clone)]
#[diesel(table_name = predict_events_withdrawn)]
pub struct PredictEventWithdrawn {
    pub tx_digest: String,
    pub event_index: i64,
    pub checkpoint: i64,
    pub timestamp: i64,
    pub predict_id: String,
    pub withdrawer: String,
    pub quote_asset: String,
    pub amount: i64,
    pub shares_burned: i64,
}
