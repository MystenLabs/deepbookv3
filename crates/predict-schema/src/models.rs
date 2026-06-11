use crate::schema::{
    block_scholes_prices_updated, block_scholes_svi_updated, builder_code_created,
    builder_code_set, builder_fees_claimed, deep_staked, deep_unstaked, ewma_config_updated,
    expiry_cash_rebalanced, expiry_cash_received, expiry_cash_template_config_updated,
    expiry_market_mint_paused_updated, expiry_max_funding_updated, expiry_profit_materialized,
    fee_config_updated, liquidated_order_redeemed, live_order_redeemed, market_config_snapshot,
    market_created, market_oracle_config_updated, market_oracle_settled,
    market_oracle_template_config_updated, order_liquidated, order_minted,
    predict_deposit_cap_minted, predict_manager_created, predict_trade_cap_minted,
    predict_withdraw_cap_minted, pricing_config_updated, pyth_source_updated, risk_config_updated,
    settled_order_redeemed, stake_config_updated, strike_exposure_template_config_updated,
    supply_executed, trading_loss_rebate_claimed, trading_paused_updated, withdraw_executed,
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

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = predict_manager_created, primary_key(event_digest))]
pub struct PredictManagerCreated {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub predict_manager_id: String,
    pub balance_manager_id: String,
    pub owner: String,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = builder_code_created, primary_key(event_digest))]
pub struct BuilderCodeCreated {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub builder_code_id: String,
    pub owner: String,
    pub builder_code_index: BigDecimal,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = builder_code_set, primary_key(event_digest))]
pub struct BuilderCodeSet {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub predict_manager_id: String,
    pub owner: String,
    pub builder_code_id: Option<String>,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = predict_trade_cap_minted, primary_key(event_digest))]
pub struct PredictTradeCapMinted {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub predict_manager_id: String,
    pub cap_id: String,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = predict_deposit_cap_minted, primary_key(event_digest))]
pub struct PredictDepositCapMinted {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub predict_manager_id: String,
    pub cap_id: String,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = predict_withdraw_cap_minted, primary_key(event_digest))]
pub struct PredictWithdrawCapMinted {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub predict_manager_id: String,
    pub cap_id: String,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = pricing_config_updated, primary_key(event_digest))]
pub struct PricingConfigUpdated {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub protocol_config_id: String,
    pub pyth_spot_freshness_ms: i64,
    pub block_scholes_prices_freshness_ms: i64,
    pub block_scholes_svi_freshness_ms: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = fee_config_updated, primary_key(event_digest))]
pub struct FeeConfigUpdated {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub protocol_config_id: String,
    pub protocol_reserve_profit_share: i64,
    pub withdraw_fee_alpha: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = risk_config_updated, primary_key(event_digest))]
pub struct RiskConfigUpdated {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub protocol_config_id: String,
    pub valuation_liquidation_budget: i64,
    pub trade_liquidation_budget: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = expiry_cash_template_config_updated, primary_key(event_digest))]
pub struct ExpiryCashTemplateConfigUpdated {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub protocol_config_id: String,
    pub trading_loss_rebate_rate: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = strike_exposure_template_config_updated, primary_key(event_digest))]
pub struct StrikeExposureTemplateConfigUpdated {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub protocol_config_id: String,
    pub terminal_floor_index: i64,
    pub liquidation_ltv: i64,
    pub backing_buffer_lambda: i64,
    pub base_fee: BigDecimal,
    pub min_fee: BigDecimal,
    pub min_ask_price: BigDecimal,
    pub max_ask_price: BigDecimal,
    pub expiry_fee_window_ms: i64,
    pub expiry_fee_max_multiplier: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = market_oracle_template_config_updated, primary_key(event_digest))]
pub struct MarketOracleTemplateConfigUpdated {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub protocol_config_id: String,
    pub settlement_freshness_ms: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = ewma_config_updated, primary_key(event_digest))]
pub struct EwmaConfigUpdated {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub protocol_config_id: String,
    pub alpha: i64,
    pub z_score_threshold: i64,
    pub additional_fee: BigDecimal,
    pub enabled: bool,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = stake_config_updated, primary_key(event_digest))]
pub struct StakeConfigUpdated {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub protocol_config_id: String,
    pub lower_benefit_power: BigDecimal,
    pub upper_benefit_power: BigDecimal,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = trading_paused_updated, primary_key(event_digest))]
pub struct TradingPausedUpdated {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub protocol_config_id: String,
    pub paused: bool,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = market_created, primary_key(event_digest))]
pub struct MarketCreated {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub expiry_market_id: String,
    pub market_oracle_id: String,
    pub pool_vault_id: String,
    pub pyth_source_id: String,
    pub pyth_lazer_feed_id: i64,
    pub expiry: i64,
    pub min_strike: BigDecimal,
    pub tick_size: BigDecimal,
    pub max_strike: BigDecimal,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = market_config_snapshot, primary_key(event_digest))]
pub struct MarketConfigSnapshot {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub expiry_market_id: String,
    pub market_oracle_id: String,
    pub terminal_floor_index: i64,
    pub liquidation_ltv: i64,
    pub backing_buffer_lambda: i64,
    pub base_fee: BigDecimal,
    pub min_fee: BigDecimal,
    pub min_ask_price: BigDecimal,
    pub max_ask_price: BigDecimal,
    pub expiry_fee_window_ms: i64,
    pub expiry_fee_max_multiplier: i64,
    pub trading_loss_rebate_rate: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = market_oracle_config_updated, primary_key(event_digest))]
pub struct MarketOracleConfigUpdated {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub market_oracle_id: String,
    pub settlement_freshness_ms: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = expiry_market_mint_paused_updated, primary_key(event_digest))]
pub struct ExpiryMarketMintPausedUpdated {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub expiry_market_id: String,
    pub paused: bool,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = block_scholes_prices_updated, primary_key(event_digest))]
pub struct BlockScholesPricesUpdated {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub market_oracle_id: String,
    pub spot: BigDecimal,
    pub forward: BigDecimal,
    pub basis: BigDecimal,
    pub source_timestamp_ms: i64,
    pub update_timestamp_ms: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = block_scholes_svi_updated, primary_key(event_digest))]
pub struct BlockScholesSVIUpdated {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub market_oracle_id: String,
    pub a: BigDecimal,
    pub b: BigDecimal,
    pub rho: BigDecimal,
    pub m: BigDecimal,
    pub sigma: BigDecimal,
    pub source_timestamp_ms: i64,
    pub update_timestamp_ms: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = pyth_source_updated, primary_key(event_digest))]
pub struct PythSourceUpdated {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub pyth_source_id: String,
    pub feed_id: i64,
    pub spot: BigDecimal,
    pub source_timestamp_ms: i64,
    pub update_timestamp_ms: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = market_oracle_settled, primary_key(event_digest))]
pub struct MarketOracleSettled {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub market_oracle_id: String,
    pub expiry: i64,
    pub settlement_price: BigDecimal,
    pub spot_source: i16,
    pub source_timestamp_ms: i64,
    pub update_timestamp_ms: i64,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = supply_executed, primary_key(event_digest))]
pub struct SupplyExecuted {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub pool_vault_id: String,
    pub payment: BigDecimal,
    pub shares_minted: BigDecimal,
    pub pool_value_before: BigDecimal,
    pub incentive_value: BigDecimal,
    pub total_supply_after: BigDecimal,
    pub idle_balance_after: BigDecimal,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = withdraw_executed, primary_key(event_digest))]
pub struct WithdrawExecuted {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub pool_vault_id: String,
    pub shares_burned: BigDecimal,
    pub payout: BigDecimal,
    pub withdraw_fee: BigDecimal,
    pub pool_value_before: BigDecimal,
    pub total_supply_after: BigDecimal,
    pub idle_balance_after: BigDecimal,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = expiry_cash_rebalanced, primary_key(event_digest))]
pub struct ExpiryCashRebalanced {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub pool_vault_id: String,
    pub expiry_market_id: String,
    pub amount: BigDecimal,
    pub to_expiry: bool,
    pub target_cash: BigDecimal,
    pub expiry_cash_after: BigDecimal,
    pub idle_balance_after: BigDecimal,
    pub sent_to_expiry_after: BigDecimal,
    pub received_from_expiry_after: BigDecimal,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = expiry_max_funding_updated, primary_key(event_digest))]
pub struct ExpiryMaxFundingUpdated {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub pool_vault_id: String,
    pub expiry_market_id: String,
    pub max_expiry_funding: BigDecimal,
    pub net_funding: BigDecimal,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = expiry_cash_received, primary_key(event_digest))]
pub struct ExpiryCashReceived {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub pool_vault_id: String,
    pub expiry_market_id: String,
    pub settlement_price: BigDecimal,
    pub amount: BigDecimal,
    pub idle_balance_after: BigDecimal,
    pub sent_to_expiry_after: BigDecimal,
    pub received_from_expiry_after: BigDecimal,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = expiry_profit_materialized, primary_key(event_digest))]
pub struct ExpiryProfitMaterialized {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub pool_vault_id: String,
    pub expiry_market_id: String,
    pub lp_profit: BigDecimal,
    pub protocol_profit: BigDecimal,
    pub idle_balance_after: BigDecimal,
    pub protocol_reserve_balance_after: BigDecimal,
    pub profit_basis_after: BigDecimal,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = deep_staked, primary_key(event_digest))]
pub struct DeepStaked {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub pool_vault_id: String,
    pub predict_manager_id: String,
    pub amount: BigDecimal,
    pub active_stake_after: BigDecimal,
    pub inactive_stake_after: BigDecimal,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = deep_unstaked, primary_key(event_digest))]
pub struct DeepUnstaked {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub pool_vault_id: String,
    pub predict_manager_id: String,
    pub amount: BigDecimal,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = builder_fees_claimed, primary_key(event_digest))]
pub struct BuilderFeesClaimed {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub builder_code_id: String,
    pub owner: String,
    pub amount: BigDecimal,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = trading_loss_rebate_claimed, primary_key(event_digest))]
pub struct TradingLossRebateClaimed {
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
    pub trading_fees_paid: BigDecimal,
    pub gross_profit: BigDecimal,
    pub eligible_rebate: BigDecimal,
    pub rebate_amount: BigDecimal,
}
