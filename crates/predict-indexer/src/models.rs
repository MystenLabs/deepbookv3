use crate::traits::MoveStruct;
use serde::{Deserialize, Serialize};
use sui_sdk_types::Address;
use sui_types::base_types::ObjectID;

// === Oracle module events ===

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OracleActivated {
    pub oracle_id: ObjectID,
    pub expiry: u64,
    pub timestamp: u64,
}

impl MoveStruct for OracleActivated {
    const MODULE: &'static str = "oracle";
    const NAME: &'static str = "OracleActivated";
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OracleSettled {
    pub oracle_id: ObjectID,
    pub expiry: u64,
    pub settlement_price: u64,
    pub timestamp: u64,
}

impl MoveStruct for OracleSettled {
    const MODULE: &'static str = "oracle";
    const NAME: &'static str = "OracleSettled";
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OraclePricesUpdated {
    pub oracle_id: ObjectID,
    pub spot: u64,
    pub forward: u64,
    pub timestamp: u64,
}

impl MoveStruct for OraclePricesUpdated {
    const MODULE: &'static str = "oracle";
    const NAME: &'static str = "OraclePricesUpdated";
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OracleSVIUpdated {
    pub oracle_id: ObjectID,
    pub a: u64,
    pub b: u64,
    pub rho: u64,
    pub rho_negative: bool,
    pub m: u64,
    pub m_negative: bool,
    pub sigma: u64,
    pub risk_free_rate: u64,
    pub timestamp: u64,
}

impl MoveStruct for OracleSVIUpdated {
    const MODULE: &'static str = "oracle";
    const NAME: &'static str = "OracleSVIUpdated";
}

// === Registry module events ===

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PredictCreated {
    pub predict_id: ObjectID,
}

impl MoveStruct for PredictCreated {
    const MODULE: &'static str = "registry";
    const NAME: &'static str = "PredictCreated";
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OracleCreated {
    pub oracle_id: ObjectID,
    pub oracle_cap_id: ObjectID,
    pub expiry: u64,
}

impl MoveStruct for OracleCreated {
    const MODULE: &'static str = "registry";
    const NAME: &'static str = "OracleCreated";
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AdminVaultBalanceChanged {
    pub predict_id: ObjectID,
    pub amount: u64,
    pub deposit: bool,
}

impl MoveStruct for AdminVaultBalanceChanged {
    const MODULE: &'static str = "registry";
    const NAME: &'static str = "AdminVaultBalanceChanged";
}

// === Predict module events ===

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PositionMinted {
    pub predict_id: ObjectID,
    pub manager_id: ObjectID,
    pub trader: Address,
    pub oracle_id: ObjectID,
    pub expiry: u64,
    pub strike: u64,
    pub is_up: bool,
    pub quantity: u64,
    pub cost: u64,
    pub ask_price: u64,
}

impl MoveStruct for PositionMinted {
    const MODULE: &'static str = "predict";
    const NAME: &'static str = "PositionMinted";
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PositionRedeemed {
    pub predict_id: ObjectID,
    pub manager_id: ObjectID,
    pub trader: Address,
    pub oracle_id: ObjectID,
    pub expiry: u64,
    pub strike: u64,
    pub is_up: bool,
    pub quantity: u64,
    pub payout: u64,
    pub bid_price: u64,
    pub is_settled: bool,
}

impl MoveStruct for PositionRedeemed {
    const MODULE: &'static str = "predict";
    const NAME: &'static str = "PositionRedeemed";
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CollateralizedPositionMinted {
    pub predict_id: ObjectID,
    pub manager_id: ObjectID,
    pub trader: Address,
    pub oracle_id: ObjectID,
    pub locked_expiry: u64,
    pub locked_strike: u64,
    pub locked_is_up: bool,
    pub minted_expiry: u64,
    pub minted_strike: u64,
    pub minted_is_up: bool,
    pub quantity: u64,
}

impl MoveStruct for CollateralizedPositionMinted {
    const MODULE: &'static str = "predict";
    const NAME: &'static str = "CollateralizedPositionMinted";
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CollateralizedPositionRedeemed {
    pub predict_id: ObjectID,
    pub manager_id: ObjectID,
    pub trader: Address,
    pub oracle_id: ObjectID,
    pub locked_expiry: u64,
    pub locked_strike: u64,
    pub locked_is_up: bool,
    pub minted_expiry: u64,
    pub minted_strike: u64,
    pub minted_is_up: bool,
    pub quantity: u64,
}

impl MoveStruct for CollateralizedPositionRedeemed {
    const MODULE: &'static str = "predict";
    const NAME: &'static str = "CollateralizedPositionRedeemed";
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TradingPauseUpdated {
    pub predict_id: ObjectID,
    pub paused: bool,
}

impl MoveStruct for TradingPauseUpdated {
    const MODULE: &'static str = "predict";
    const NAME: &'static str = "TradingPauseUpdated";
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PricingConfigUpdated {
    pub predict_id: ObjectID,
    pub base_spread: u64,
    pub max_skew_multiplier: u64,
    pub utilization_multiplier: u64,
}

impl MoveStruct for PricingConfigUpdated {
    const MODULE: &'static str = "predict";
    const NAME: &'static str = "PricingConfigUpdated";
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RiskConfigUpdated {
    pub predict_id: ObjectID,
    pub max_total_exposure_pct: u64,
}

impl MoveStruct for RiskConfigUpdated {
    const MODULE: &'static str = "predict";
    const NAME: &'static str = "RiskConfigUpdated";
}

// === PredictManager module events ===

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PredictManagerCreated {
    pub manager_id: ObjectID,
    pub owner: Address,
}

impl MoveStruct for PredictManagerCreated {
    const MODULE: &'static str = "predict_manager";
    const NAME: &'static str = "PredictManagerCreated";
}
