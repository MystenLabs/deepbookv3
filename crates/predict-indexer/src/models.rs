use crate::traits::MoveStruct;
use serde::{Deserialize, Serialize};
use sui_sdk_types::Address;
use sui_types::base_types::ObjectID;

/// Mirrors BCS layout of `std::type_name::TypeName { name: ascii::String { bytes: vector<u8> } }`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MoveTypeName {
    pub name: MoveAsciiString,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MoveAsciiString {
    pub bytes: Vec<u8>,
}

impl MoveTypeName {
    pub fn as_string(&self) -> String {
        String::from_utf8_lossy(&self.name.bytes).into_owned()
    }
}

/// Mirrors BCS layout of `deepbook_predict::i64::I64`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MoveI64 {
    pub magnitude: u64,
    pub is_negative: bool,
}

// === oracle module ===

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
    pub rho: MoveI64,
    pub m: MoveI64,
    pub sigma: u64,
    pub timestamp: u64,
}
impl MoveStruct for OracleSVIUpdated {
    const MODULE: &'static str = "oracle";
    const NAME: &'static str = "OracleSVIUpdated";
}

// === registry module ===

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
    pub underlying_asset: String,
    pub expiry: u64,
    pub min_strike: u64,
    pub tick_size: u64,
}
impl MoveStruct for OracleCreated {
    const MODULE: &'static str = "registry";
    const NAME: &'static str = "OracleCreated";
}

// === predict module ===

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ManagerCreated {
    pub manager_id: ObjectID,
    pub owner: Address,
}
impl MoveStruct for ManagerCreated {
    const MODULE: &'static str = "predict";
    const NAME: &'static str = "ManagerCreated";
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PositionMinted {
    pub predict_id: ObjectID,
    pub manager_id: ObjectID,
    pub trader: Address,
    pub quote_asset: MoveTypeName,
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
    pub owner: Address,
    pub executor: Address,
    pub quote_asset: MoveTypeName,
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
pub struct RangeMinted {
    pub predict_id: ObjectID,
    pub manager_id: ObjectID,
    pub trader: Address,
    pub quote_asset: MoveTypeName,
    pub oracle_id: ObjectID,
    pub expiry: u64,
    pub lower_strike: u64,
    pub higher_strike: u64,
    pub quantity: u64,
    pub cost: u64,
    pub ask_price: u64,
}
impl MoveStruct for RangeMinted {
    const MODULE: &'static str = "predict";
    const NAME: &'static str = "RangeMinted";
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RangeRedeemed {
    pub predict_id: ObjectID,
    pub manager_id: ObjectID,
    pub trader: Address,
    pub quote_asset: MoveTypeName,
    pub oracle_id: ObjectID,
    pub expiry: u64,
    pub lower_strike: u64,
    pub higher_strike: u64,
    pub quantity: u64,
    pub payout: u64,
    pub bid_price: u64,
    pub is_settled: bool,
}
impl MoveStruct for RangeRedeemed {
    const MODULE: &'static str = "predict";
    const NAME: &'static str = "RangeRedeemed";
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
    pub min_spread: u64,
    pub utilization_multiplier: u64,
    pub min_ask_price: u64,
    pub max_ask_price: u64,
}
impl MoveStruct for PricingConfigUpdated {
    const MODULE: &'static str = "predict";
    const NAME: &'static str = "PricingConfigUpdated";
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OracleAskBoundsSet {
    pub predict_id: ObjectID,
    pub oracle_id: ObjectID,
    pub min_ask_price: u64,
    pub max_ask_price: u64,
}
impl MoveStruct for OracleAskBoundsSet {
    const MODULE: &'static str = "predict";
    const NAME: &'static str = "OracleAskBoundsSet";
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OracleAskBoundsCleared {
    pub predict_id: ObjectID,
    pub oracle_id: ObjectID,
}
impl MoveStruct for OracleAskBoundsCleared {
    const MODULE: &'static str = "predict";
    const NAME: &'static str = "OracleAskBoundsCleared";
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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QuoteAssetEnabled {
    pub predict_id: ObjectID,
    pub quote_asset: MoveTypeName,
}
impl MoveStruct for QuoteAssetEnabled {
    const MODULE: &'static str = "predict";
    const NAME: &'static str = "QuoteAssetEnabled";
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QuoteAssetDisabled {
    pub predict_id: ObjectID,
    pub quote_asset: MoveTypeName,
}
impl MoveStruct for QuoteAssetDisabled {
    const MODULE: &'static str = "predict";
    const NAME: &'static str = "QuoteAssetDisabled";
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Supplied {
    pub predict_id: ObjectID,
    pub supplier: Address,
    pub quote_asset: MoveTypeName,
    pub amount: u64,
    pub shares_minted: u64,
}
impl MoveStruct for Supplied {
    const MODULE: &'static str = "predict";
    const NAME: &'static str = "Supplied";
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Withdrawn {
    pub predict_id: ObjectID,
    pub withdrawer: Address,
    pub quote_asset: MoveTypeName,
    pub amount: u64,
    pub shares_burned: u64,
}
impl MoveStruct for Withdrawn {
    const MODULE: &'static str = "predict";
    const NAME: &'static str = "Withdrawn";
}

// === predict_manager module ===

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PredictManagerCreated {
    pub manager_id: ObjectID,
    pub owner: Address,
}
impl MoveStruct for PredictManagerCreated {
    const MODULE: &'static str = "predict_manager";
    const NAME: &'static str = "PredictManagerCreated";
}
