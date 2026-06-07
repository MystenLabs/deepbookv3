//! Decode structs for Predict on-chain events.
//!
//! Each struct mirrors the field layout of the corresponding Move struct under
//! `packages/predict/sources/events/`. BCS decoding is positional, so field
//! order must be kept in exact sync with the Move source.

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

/// Emitted when a derived PredictManager is created.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PredictManagerCreated {
    pub predict_manager_id: ObjectID,
    pub balance_manager_id: ObjectID,
    pub owner: Address,
}

impl MoveStruct for PredictManagerCreated {
    const MODULE: &'static str = "account_events";
    const NAME: &'static str = "PredictManagerCreated";
}

/// Emitted when a derived BuilderCode is created.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BuilderCodeCreated {
    pub builder_code_id: ObjectID,
    pub owner: Address,
    pub builder_code_index: u64,
}

impl MoveStruct for BuilderCodeCreated {
    const MODULE: &'static str = "account_events";
    const NAME: &'static str = "BuilderCodeCreated";
}

/// Emitted when a manager owner changes sticky builder-code attribution.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BuilderCodeSet {
    pub predict_manager_id: ObjectID,
    pub owner: Address,
    pub builder_code_id: Option<ObjectID>,
}

impl MoveStruct for BuilderCodeSet {
    const MODULE: &'static str = "account_events";
    const NAME: &'static str = "BuilderCodeSet";
}

/// Emitted when a `PredictTradeCap` is minted.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PredictTradeCapMinted {
    pub predict_manager_id: ObjectID,
    pub cap_id: ObjectID,
}

impl MoveStruct for PredictTradeCapMinted {
    const MODULE: &'static str = "account_events";
    const NAME: &'static str = "PredictTradeCapMinted";
}

/// Emitted when a `PredictDepositCap` is minted.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PredictDepositCapMinted {
    pub predict_manager_id: ObjectID,
    pub cap_id: ObjectID,
}

impl MoveStruct for PredictDepositCapMinted {
    const MODULE: &'static str = "account_events";
    const NAME: &'static str = "PredictDepositCapMinted";
}

/// Emitted when a `PredictWithdrawCap` is minted.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PredictWithdrawCapMinted {
    pub predict_manager_id: ObjectID,
    pub cap_id: ObjectID,
}

impl MoveStruct for PredictWithdrawCapMinted {
    const MODULE: &'static str = "account_events";
    const NAME: &'static str = "PredictWithdrawCapMinted";
}

/// Emitted when quote-freshness config changes.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PricingConfigUpdated {
    pub protocol_config_id: ObjectID,
    pub pyth_spot_freshness_ms: u64,
    pub block_scholes_prices_freshness_ms: u64,
    pub block_scholes_svi_freshness_ms: u64,
}

impl MoveStruct for PricingConfigUpdated {
    const MODULE: &'static str = "config_events";
    const NAME: &'static str = "PricingConfigUpdated";
}

/// Emitted when pool profit-reserve policy changes.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FeeConfigUpdated {
    pub protocol_config_id: ObjectID,
    pub protocol_reserve_profit_share: u64,
}

impl MoveStruct for FeeConfigUpdated {
    const MODULE: &'static str = "config_events";
    const NAME: &'static str = "FeeConfigUpdated";
}

/// Emitted when liquidation-budget policy changes.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RiskConfigUpdated {
    pub protocol_config_id: ObjectID,
    pub valuation_liquidation_budget: u64,
    pub trade_liquidation_budget: u64,
}

impl MoveStruct for RiskConfigUpdated {
    const MODULE: &'static str = "config_events";
    const NAME: &'static str = "RiskConfigUpdated";
}

/// Emitted when future expiry-cash template policy changes.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExpiryCashTemplateConfigUpdated {
    pub protocol_config_id: ObjectID,
    pub trading_loss_rebate_rate: u64,
}

impl MoveStruct for ExpiryCashTemplateConfigUpdated {
    const MODULE: &'static str = "config_events";
    const NAME: &'static str = "ExpiryCashTemplateConfigUpdated";
}

/// Emitted when future strike-exposure template policy changes.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StrikeExposureTemplateConfigUpdated {
    pub protocol_config_id: ObjectID,
    pub terminal_floor_index: u64,
    pub liquidation_ltv: u64,
    pub base_fee: u64,
    pub min_fee: u64,
    pub min_ask_price: u64,
    pub max_ask_price: u64,
    pub expiry_fee_window_ms: u64,
    pub expiry_fee_max_multiplier: u64,
}

impl MoveStruct for StrikeExposureTemplateConfigUpdated {
    const MODULE: &'static str = "config_events";
    const NAME: &'static str = "StrikeExposureTemplateConfigUpdated";
}

/// Emitted when future market-oracle template policy changes.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MarketOracleTemplateConfigUpdated {
    pub protocol_config_id: ObjectID,
    pub settlement_freshness_ms: u64,
    pub max_spot_deviation: u64,
    pub max_basis_deviation: u64,
    pub min_basis: u64,
    pub max_basis: u64,
}

impl MoveStruct for MarketOracleTemplateConfigUpdated {
    const MODULE: &'static str = "config_events";
    const NAME: &'static str = "MarketOracleTemplateConfigUpdated";
}

/// Emitted when the EWMA gas-price penalty config changes.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EwmaConfigUpdated {
    pub protocol_config_id: ObjectID,
    pub alpha: u64,
    pub z_score_threshold: u64,
    pub additional_fee: u64,
    pub enabled: bool,
}

impl MoveStruct for EwmaConfigUpdated {
    const MODULE: &'static str = "config_events";
    const NAME: &'static str = "EwmaConfigUpdated";
}

/// Emitted when the DEEP-stake benefit config changes.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StakeConfigUpdated {
    pub protocol_config_id: ObjectID,
    pub lower_benefit_power: u64,
    pub upper_benefit_power: u64,
}

impl MoveStruct for StakeConfigUpdated {
    const MODULE: &'static str = "config_events";
    const NAME: &'static str = "StakeConfigUpdated";
}

/// Emitted when global trading pause state changes.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TradingPausedUpdated {
    pub protocol_config_id: ObjectID,
    pub paused: bool,
}

impl MoveStruct for TradingPausedUpdated {
    const MODULE: &'static str = "config_events";
    const NAME: &'static str = "TradingPausedUpdated";
}

/// Emitted when a new expiry market and its oracle are created.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MarketCreated {
    pub expiry_market_id: ObjectID,
    pub market_oracle_id: ObjectID,
    pub pool_vault_id: ObjectID,
    pub pyth_source_id: ObjectID,
    pub pyth_lazer_feed_id: u32,
    pub expiry: u64,
    pub min_strike: u64,
    pub tick_size: u64,
    pub max_strike: u64,
}

impl MoveStruct for MarketCreated {
    const MODULE: &'static str = "config_events";
    const NAME: &'static str = "MarketCreated";
}

/// Emitted alongside `MarketCreated` with the per-market policy snapshot.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MarketConfigSnapshot {
    pub expiry_market_id: ObjectID,
    pub market_oracle_id: ObjectID,
    pub terminal_floor_index: u64,
    pub liquidation_ltv: u64,
    pub base_fee: u64,
    pub min_fee: u64,
    pub min_ask_price: u64,
    pub max_ask_price: u64,
    pub expiry_fee_window_ms: u64,
    pub expiry_fee_max_multiplier: u64,
    pub trading_loss_rebate_rate: u64,
}

impl MoveStruct for MarketConfigSnapshot {
    const MODULE: &'static str = "config_events";
    const NAME: &'static str = "MarketConfigSnapshot";
}

/// Emitted when admin updates one live oracle's bounds.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MarketOracleBoundsUpdated {
    pub market_oracle_id: ObjectID,
    pub settlement_freshness_ms: u64,
    pub max_spot_deviation: u64,
    pub max_basis_deviation: u64,
    pub min_basis: u64,
    pub max_basis: u64,
}

impl MoveStruct for MarketOracleBoundsUpdated {
    const MODULE: &'static str = "config_events";
    const NAME: &'static str = "MarketOracleBoundsUpdated";
}

/// Emitted when minting pause state changes for one expiry market.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExpiryMarketMintPausedUpdated {
    pub expiry_market_id: ObjectID,
    pub paused: bool,
}

impl MoveStruct for ExpiryMarketMintPausedUpdated {
    const MODULE: &'static str = "config_events";
    const NAME: &'static str = "ExpiryMarketMintPausedUpdated";
}

/// Mirrors `deepbook_predict::i64::I64`: a signed magnitude. BCS decodes the
/// `magnitude` u64 then the `is_negative` bool, so field order must match.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct I64 {
    pub magnitude: u64,
    pub is_negative: bool,
}

/// Emitted when Block Scholes spot/forward data is accepted.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BlockScholesPricesUpdated {
    pub market_oracle_id: ObjectID,
    pub spot: u64,
    pub forward: u64,
    pub basis: u64,
    pub source_timestamp_ms: u64,
    pub update_timestamp_ms: u64,
}

impl MoveStruct for BlockScholesPricesUpdated {
    const MODULE: &'static str = "oracle_events";
    const NAME: &'static str = "BlockScholesPricesUpdated";
}

/// Emitted when Block Scholes SVI data is accepted.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BlockScholesSVIUpdated {
    pub market_oracle_id: ObjectID,
    pub a: u64,
    pub b: u64,
    pub rho: I64,
    pub m: I64,
    pub sigma: u64,
    pub source_timestamp_ms: u64,
    pub update_timestamp_ms: u64,
}

impl MoveStruct for BlockScholesSVIUpdated {
    const MODULE: &'static str = "oracle_events";
    const NAME: &'static str = "BlockScholesSVIUpdated";
}

/// Emitted when a verified Pyth Lazer spot update is accepted.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PythSourceUpdated {
    pub pyth_source_id: ObjectID,
    pub feed_id: u32,
    pub spot: u64,
    pub source_timestamp_ms: u64,
    pub update_timestamp_ms: u64,
}

impl MoveStruct for PythSourceUpdated {
    const MODULE: &'static str = "oracle_events";
    const NAME: &'static str = "PythSourceUpdated";
}

/// Emitted when the oracle records terminal settlement.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MarketOracleSettled {
    pub market_oracle_id: ObjectID,
    pub expiry: u64,
    pub settlement_price: u64,
    pub spot_source: u8,
    pub source_timestamp_ms: u64,
    pub update_timestamp_ms: u64,
}

impl MoveStruct for MarketOracleSettled {
    const MODULE: &'static str = "oracle_events";
    const NAME: &'static str = "MarketOracleSettled";
}

/// Emitted when DUSDC is supplied and PLP shares are minted.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SupplyExecuted {
    pub pool_vault_id: ObjectID,
    pub payment: u64,
    pub shares_minted: u64,
    pub pool_value_before: u64,
    pub incentive_value: u64,
    pub total_supply_after: u64,
    pub idle_balance_after: u64,
}

impl MoveStruct for SupplyExecuted {
    const MODULE: &'static str = "vault_events";
    const NAME: &'static str = "SupplyExecuted";
}

/// Emitted when PLP shares are burned and DUSDC is withdrawn.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WithdrawExecuted {
    pub pool_vault_id: ObjectID,
    pub shares_burned: u64,
    pub payout: u64,
    pub pool_value_before: u64,
    pub total_supply_after: u64,
    pub idle_balance_after: u64,
}

impl MoveStruct for WithdrawExecuted {
    const MODULE: &'static str = "vault_events";
    const NAME: &'static str = "WithdrawExecuted";
}

/// Emitted when live expiry cash is rebalanced against current backing needs.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExpiryCashRebalanced {
    pub pool_vault_id: ObjectID,
    pub expiry_market_id: ObjectID,
    pub amount: u64,
    pub to_expiry: bool,
    pub target_cash: u64,
    pub expiry_cash_after: u64,
    pub idle_balance_after: u64,
    pub sent_to_expiry_after: u64,
    pub received_from_expiry_after: u64,
}

impl MoveStruct for ExpiryCashRebalanced {
    const MODULE: &'static str = "vault_events";
    const NAME: &'static str = "ExpiryCashRebalanced";
}

/// Emitted when an expiry's max net pool funding cap changes.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExpiryMaxFundingUpdated {
    pub pool_vault_id: ObjectID,
    pub expiry_market_id: ObjectID,
    pub max_expiry_funding: u64,
    pub net_funding: u64,
}

impl MoveStruct for ExpiryMaxFundingUpdated {
    const MODULE: &'static str = "vault_events";
    const NAME: &'static str = "ExpiryMaxFundingUpdated";
}

/// Emitted when an expiry returns cash to the pool.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExpiryCashReceived {
    pub pool_vault_id: ObjectID,
    pub expiry_market_id: ObjectID,
    pub settlement_price: u64,
    pub amount: u64,
    pub idle_balance_after: u64,
    pub sent_to_expiry_after: u64,
    pub received_from_expiry_after: u64,
}

impl MoveStruct for ExpiryCashReceived {
    const MODULE: &'static str = "vault_events";
    const NAME: &'static str = "ExpiryCashReceived";
}

/// Emitted when terminal expiry profit is split between LPs and protocol reserves.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExpiryProfitMaterialized {
    pub pool_vault_id: ObjectID,
    pub expiry_market_id: ObjectID,
    pub lp_profit: u64,
    pub protocol_profit: u64,
    pub idle_balance_after: u64,
    pub protocol_reserve_balance_after: u64,
    pub profit_basis_after: u64,
}

impl MoveStruct for ExpiryProfitMaterialized {
    const MODULE: &'static str = "vault_events";
    const NAME: &'static str = "ExpiryProfitMaterialized";
}

/// Emitted when a manager stakes DEEP for trading benefits.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeepStaked {
    pub pool_vault_id: ObjectID,
    pub predict_manager_id: ObjectID,
    pub amount: u64,
    pub active_stake_after: u64,
    pub inactive_stake_after: u64,
}

impl MoveStruct for DeepStaked {
    const MODULE: &'static str = "vault_events";
    const NAME: &'static str = "DeepStaked";
}

/// Emitted when a manager unstakes all of its DEEP (active and inactive).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeepUnstaked {
    pub pool_vault_id: ObjectID,
    pub predict_manager_id: ObjectID,
    pub amount: u64,
}

impl MoveStruct for DeepUnstaked {
    const MODULE: &'static str = "vault_events";
    const NAME: &'static str = "DeepUnstaked";
}

/// Emitted when a builder code owner claims accumulated builder fees.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BuilderFeesClaimed {
    pub builder_code_id: ObjectID,
    pub owner: Address,
    pub amount: u64,
}

impl MoveStruct for BuilderFeesClaimed {
    const MODULE: &'static str = "claim_events";
    const NAME: &'static str = "BuilderFeesClaimed";
}

/// Emitted when an expiry trading-loss rebate is resolved for one manager.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TradingLossRebateClaimed {
    pub expiry_market_id: ObjectID,
    pub predict_manager_id: ObjectID,
    pub trading_fees_paid: u64,
    pub gross_profit: u64,
    pub eligible_rebate: u64,
    pub rebate_amount: u64,
}

impl MoveStruct for TradingLossRebateClaimed {
    const MODULE: &'static str = "claim_events";
    const NAME: &'static str = "TradingLossRebateClaimed";
}
