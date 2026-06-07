//! Decode structs for Predict on-chain events.
//!
//! Each struct mirrors the field layout of the corresponding Move struct in
//! `packages/predict/sources/events/order_events.move`. BCS decoding is
//! positional, so field order must be kept in exact sync with the Move source.

use crate::traits::MoveStruct;
use move_core_types::u256::U256;
use serde::{Deserialize, Serialize};
use sui_sdk_types::Address;
use sui_types::base_types::ObjectID;

/// Emitted when a live position interval is minted.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OrderMinted {
    pub expiry_market_id: ObjectID,
    pub predict_manager_id: ObjectID,
    pub order_id: U256,
    pub position_root_id: U256,
    pub owner: Address,
    pub lower_strike: u64,
    pub higher_strike: u64,
    pub leverage: u64,
    pub entry_probability: u64,
    pub quantity: u64,
    pub contribution: u64,
    pub trading_fee: u64,
    pub builder_fee: u64,
    pub penalty_fee: u64,
    pub builder_code_id: Option<ObjectID>,
}

impl MoveStruct for OrderMinted {
    const MODULE: &'static str = "order_events";
    const NAME: &'static str = "OrderMinted";
}

/// Emitted when a live position is closed fully or partially.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LiveOrderRedeemed {
    pub expiry_market_id: ObjectID,
    pub predict_manager_id: ObjectID,
    pub order_id: U256,
    pub position_root_id: U256,
    pub owner: Address,
    pub quantity_closed: u64,
    pub remaining_quantity: u64,
    pub replacement_order_id: Option<U256>,
    pub redeem_amount: u64,
    pub trading_fee: u64,
    pub builder_fee: u64,
    pub penalty_fee: u64,
    pub builder_code_id: Option<ObjectID>,
}

impl MoveStruct for LiveOrderRedeemed {
    const MODULE: &'static str = "order_events";
    const NAME: &'static str = "LiveOrderRedeemed";
}

/// Emitted when a settled position is redeemed for terminal payout.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SettledOrderRedeemed {
    pub expiry_market_id: ObjectID,
    pub predict_manager_id: ObjectID,
    pub order_id: U256,
    pub position_root_id: U256,
    pub owner: Address,
    pub quantity_closed: u64,
    pub settlement_price: u64,
    pub payout_amount: u64,
}

impl MoveStruct for SettledOrderRedeemed {
    const MODULE: &'static str = "order_events";
    const NAME: &'static str = "SettledOrderRedeemed";
}

/// Emitted when a manager clears a liquidated position with zero payout.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LiquidatedOrderRedeemed {
    pub expiry_market_id: ObjectID,
    pub predict_manager_id: ObjectID,
    pub order_id: U256,
    pub position_root_id: U256,
    pub owner: Address,
    pub quantity_closed: u64,
}

impl MoveStruct for LiquidatedOrderRedeemed {
    const MODULE: &'static str = "order_events";
    const NAME: &'static str = "LiquidatedOrderRedeemed";
}

/// Emitted once per order removed by liquidation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OrderLiquidated {
    pub expiry_market_id: ObjectID,
    pub order_id: U256,
    pub quantity: u64,
    pub gross_value: u64,
    pub floor_amount: u64,
    pub liquidation_ltv: u64,
}

impl MoveStruct for OrderLiquidated {
    const MODULE: &'static str = "order_events";
    const NAME: &'static str = "OrderLiquidated";
}
