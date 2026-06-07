use crate::schema::{
    liquidated_order_redeemed, live_order_redeemed, order_liquidated, order_minted,
    settled_order_redeemed,
};
use bigdecimal::BigDecimal;
use diesel::{Identifiable, Insertable, Queryable, Selectable};
use serde::Serialize;
use sui_field_count::FieldCount;

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = order_minted, primary_key(event_digest))]
pub struct OrderMinted {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub expiry_market_id: String,
    pub predict_manager_id: String,
    pub order_id: String,
    pub position_root_id: String,
    pub owner: String,
    pub lower_strike: BigDecimal,
    pub higher_strike: BigDecimal,
    pub leverage: i64,
    pub entry_probability: i64,
    pub quantity: BigDecimal,
    pub contribution: BigDecimal,
    pub trading_fee: BigDecimal,
    pub builder_fee: BigDecimal,
    pub penalty_fee: BigDecimal,
    pub builder_code_id: Option<String>,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = live_order_redeemed, primary_key(event_digest))]
pub struct LiveOrderRedeemed {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub expiry_market_id: String,
    pub predict_manager_id: String,
    pub order_id: String,
    pub position_root_id: String,
    pub owner: String,
    pub quantity_closed: BigDecimal,
    pub remaining_quantity: BigDecimal,
    pub replacement_order_id: Option<String>,
    pub redeem_amount: BigDecimal,
    pub trading_fee: BigDecimal,
    pub builder_fee: BigDecimal,
    pub penalty_fee: BigDecimal,
    pub builder_code_id: Option<String>,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = settled_order_redeemed, primary_key(event_digest))]
pub struct SettledOrderRedeemed {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub expiry_market_id: String,
    pub predict_manager_id: String,
    pub order_id: String,
    pub position_root_id: String,
    pub owner: String,
    pub quantity_closed: BigDecimal,
    pub settlement_price: BigDecimal,
    pub payout_amount: BigDecimal,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = liquidated_order_redeemed, primary_key(event_digest))]
pub struct LiquidatedOrderRedeemed {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub expiry_market_id: String,
    pub predict_manager_id: String,
    pub order_id: String,
    pub position_root_id: String,
    pub owner: String,
    pub quantity_closed: BigDecimal,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = order_liquidated, primary_key(event_digest))]
pub struct OrderLiquidated {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub expiry_market_id: String,
    pub order_id: String,
    pub quantity: BigDecimal,
    pub gross_value: BigDecimal,
    pub floor_amount: BigDecimal,
    pub liquidation_ltv: i64,
}
