use crate::schema::block_scholes_observation;
use crate::schema::{
    builder_code_created, builder_code_set, builder_fees_claimed, deep_staked, deep_unstaked,
    ewma_config_updated, expiry_cash_rebalanced, expiry_cash_received,
    expiry_cash_template_config_updated, expiry_market_mint_paused_updated,
    expiry_profit_materialized, flush_executed, liquidated_order_redeemed, liquidation_stats_1h,
    live_order_redeemed, lp_request_state, market_activity_1h, market_config_snapshot,
    market_created, market_settled, oracle_bound, oracle_source_registered, oracle_spot_1m,
    order_liquidated, order_minted, order_state, position_cashflow, predict_deposit_cap_minted,
    predict_manager_created, predict_trade_cap_minted, predict_withdraw_cap_minted,
    pricing_config_updated, pyth_observation, request_cancelled, risk_config_updated,
    settled_order_redeemed, stake_config_updated, strike_exposure_template_config_updated,
    supply_filled, supply_requested, trading_paused_updated, vault_flows_1h, withdraw_filled,
    withdraw_requested,
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
    pub lower_tick: i64,
    pub higher_tick: i64,
    pub leverage: i64,
    pub entry_probability: i64,
    pub quantity: BigDecimal,
    pub net_premium: BigDecimal,
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
    pub block_scholes_surface_freshness_ms: i64,
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
    pub trade_liquidation_budget: i64,
    pub protocol_reserve_profit_share: i64,
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
    pub penalty_rate: BigDecimal,
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
    pub pool_vault_id: String,
    pub propbook_underlying_id: i64,
    pub expiry: i64,
    pub tick_size: BigDecimal,
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
#[diesel(table_name = market_settled, primary_key(event_digest))]
pub struct MarketSettled {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub expiry_market_id: String,
    pub propbook_underlying_id: i64,
    pub expiry: i64,
    pub settlement_price: BigDecimal,
    pub settled_at_ms: i64,
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
    pub protocol_reserve_balance_after: BigDecimal,
    pub pending_protocol_profit_after: BigDecimal,
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
    pub pending_protocol_profit_after: BigDecimal,
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
#[diesel(table_name = supply_requested, primary_key(event_digest))]
pub struct SupplyRequested {
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
    pub recipient: String,
    pub request_index: i64,
    pub amount: BigDecimal,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = withdraw_requested, primary_key(event_digest))]
pub struct WithdrawRequested {
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
    pub recipient: String,
    pub request_index: i64,
    pub amount: BigDecimal,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = request_cancelled, primary_key(event_digest))]
pub struct RequestCancelled {
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
    pub recipient: String,
    pub request_index: i64,
    pub amount: BigDecimal,
    pub is_supply: bool,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = supply_filled, primary_key(event_digest))]
pub struct SupplyFilled {
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
    pub recipient: String,
    pub request_index: i64,
    pub dusdc_amount: BigDecimal,
    pub shares_minted: BigDecimal,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = withdraw_filled, primary_key(event_digest))]
pub struct WithdrawFilled {
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
    pub recipient: String,
    pub request_index: i64,
    pub shares_burned: BigDecimal,
    pub dusdc_amount: BigDecimal,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = flush_executed, primary_key(event_digest))]
pub struct FlushExecuted {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub pool_vault_id: String,
    pub epoch: i64,
    pub pool_value: BigDecimal,
    pub total_supply: BigDecimal,
    pub active_market_nav: BigDecimal,
    pub market_count: i64,
    pub idle_balance_before: BigDecimal,
    pub supplies_filled: i64,
    pub withdrawals_filled: i64,
    pub requests_processed: i64,
    pub idle_balance_after: BigDecimal,
}

/// `order_state.status` values, shared by the indexer pipeline that writes
/// them and the server queries that filter on them.
pub mod order_status {
    pub const OPEN: &str = "open";
    pub const REPLACED: &str = "replaced";
    pub const CLOSED: &str = "closed";
    pub const LIQUIDATED: &str = "liquidated";
    pub const LIQUIDATED_REDEEMED: &str = "liquidated_redeemed";
    pub const SETTLED_REDEEMED: &str = "settled_redeemed";
}

/// `lp_request_state.status` values, shared by the indexer pipeline that writes
/// them and the server queries that filter on them.
pub mod lp_request_status {
    pub const OPEN: &str = "open";
    pub const CANCELLED: &str = "cancelled";
    pub const FILLED: &str = "filled";
}

/// Maintained current-state row for one packed order id (`order_state`).
///
/// Keyed by `(expiry_market_id, order_id)`: packed order ids are expiry-local
/// (sequence/opened_at_ms), so the same id can occur in two markets.
///
/// Unlike the raw event rows above, this row is upserted by the `order_state`
/// pipeline (raw SQL, not diesel inserts) with write-once identity/entry
/// columns and an LWW-guarded `(checkpoint, tx_index, event_index)` triple.
/// `Clone`/`PartialEq` support the pipeline's in-memory fold and its unit
/// tests.
#[derive(Queryable, Selectable, Debug, Clone, PartialEq, FieldCount, Serialize)]
#[diesel(table_name = order_state)]
pub struct OrderState {
    pub expiry_market_id: String,
    pub order_id: String,
    pub predict_manager_id: Option<String>,
    pub position_root_id: Option<String>,
    pub owner: Option<String>,
    pub status: String,
    pub replacement_order_id: Option<String>,
    pub opened_at_ms: i64,
    pub lower_boundary_index: i64,
    pub higher_boundary_index: i64,
    pub floor_shares: BigDecimal,
    pub quantity: BigDecimal,
    pub sequence: i64,
    pub leverage: Option<i64>,
    pub entry_probability: Option<i64>,
    pub net_premium: Option<BigDecimal>,
    pub updated_at_ms: i64,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
}

/// Maintained current-state row for one async LP request (`lp_request_state`).
///
/// Keyed by `(pool_vault_id, is_supply, request_index)`: the queue handle is
/// unique only within (vault, is_supply). Upserted by the `lp_request_state`
/// pipeline (raw SQL) with write-once identity/amount columns (from the
/// Requested event, since fills carry no manager id) and an LWW-guarded
/// `(checkpoint, tx_index, event_index)` triple. `Clone`/`PartialEq` support
/// the pipeline's in-memory fold and its unit tests.
#[derive(Queryable, Selectable, Debug, Clone, PartialEq, FieldCount, Serialize)]
#[diesel(table_name = lp_request_state)]
pub struct LpRequestState {
    pub pool_vault_id: String,
    pub is_supply: bool,
    pub request_index: i64,
    pub predict_manager_id: Option<String>,
    pub recipient: Option<String>,
    pub requested_amount: Option<BigDecimal>,
    pub status: String,
    pub filled_dusdc: Option<BigDecimal>,
    pub filled_shares: Option<BigDecimal>,
    pub opened_at_ms: i64,
    pub updated_at_ms: i64,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
}

// Read-only models over the materialized views (refreshed by the indexer's
// materialized-view refresh service; never inserted from Rust).

#[derive(Queryable, Selectable, Debug, Serialize)]
#[diesel(table_name = market_activity_1h)]
pub struct MarketActivity1h {
    pub expiry_market_id: String,
    pub bucket_ms: i64,
    pub mint_count: i64,
    pub mint_quantity: BigDecimal,
    pub mint_premium: BigDecimal,
    pub mint_fees: BigDecimal,
    pub unique_minters: i64,
    pub live_redeem_count: i64,
    pub live_redeem_quantity: BigDecimal,
    pub live_redeem_amount: BigDecimal,
    pub live_redeem_fees: BigDecimal,
    pub settled_redeem_count: i64,
    pub settled_redeem_quantity: BigDecimal,
    pub settled_redeem_payout: BigDecimal,
}

#[derive(Queryable, Selectable, Debug, Serialize)]
#[diesel(table_name = vault_flows_1h)]
pub struct VaultFlows1h {
    pub pool_vault_id: String,
    pub bucket_ms: i64,
    pub supply_count: i64,
    pub supply_amount: BigDecimal,
    pub shares_minted: BigDecimal,
    pub withdraw_count: i64,
    pub withdraw_amount: BigDecimal,
    pub shares_burned: BigDecimal,
    pub total_supply_after: BigDecimal,
    pub idle_balance_after: BigDecimal,
}

#[derive(Queryable, Selectable, Debug, Serialize)]
#[diesel(table_name = liquidation_stats_1h)]
pub struct LiquidationStats1h {
    pub expiry_market_id: String,
    pub bucket_ms: i64,
    pub liquidated_count: i64,
    pub liquidated_quantity: BigDecimal,
    pub gross_value: BigDecimal,
    pub floor_amount: BigDecimal,
    pub surplus: BigDecimal,
    pub gap: BigDecimal,
}

#[derive(Queryable, Selectable, Debug, Serialize)]
#[diesel(table_name = position_cashflow)]
pub struct PositionCashflow {
    pub expiry_market_id: String,
    pub position_root_id: String,
    pub predict_manager_id: String,
    pub owner: String,
    pub minted_quantity: BigDecimal,
    pub net_premium: BigDecimal,
    pub mint_fees: BigDecimal,
    pub live_redeem_amount: BigDecimal,
    pub live_redeem_fees: BigDecimal,
    pub live_quantity_closed: BigDecimal,
    pub settled_payout: BigDecimal,
    pub settled_quantity_closed: BigDecimal,
    pub liquidated_quantity_closed: BigDecimal,
}

// Oracle-lane raw models, inserted by the standalone oracle-indexer. As with
// the predict raw models, the DB-default `timestamp` column is omitted.

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = pyth_observation, primary_key(event_digest))]
pub struct PythObservation {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub propbook_oracle_id: String,
    pub pyth_source_id: i64,
    pub price_magnitude: BigDecimal,
    pub price_is_negative: bool,
    pub exponent_magnitude: i32,
    pub exponent_is_negative: bool,
    pub source_timestamp_us: BigDecimal,
    pub normalized_spot: Option<BigDecimal>,
    pub source_timestamp_ms: i64,
    pub update_timestamp_ms: i64,
    pub is_exact: bool,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = block_scholes_observation, primary_key(event_digest))]
pub struct BlockScholesObservation {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub propbook_oracle_id: String,
    pub bs_source_id: i64,
    pub expiry_ms: i64,
    pub spot: BigDecimal,
    pub forward: BigDecimal,
    pub svi_a: BigDecimal,
    pub svi_b: BigDecimal,
    pub svi_rho: BigDecimal,
    pub svi_m: BigDecimal,
    pub svi_sigma: BigDecimal,
    pub normalized_spot: Option<BigDecimal>,
    pub normalized_forward: Option<BigDecimal>,
    pub source_timestamp_ms: i64,
    pub update_timestamp_ms: i64,
    pub is_exact: bool,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = oracle_source_registered, primary_key(event_digest))]
pub struct OracleSourceRegistered {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub oracle_kind: i16,
    pub source_id: i64,
    pub propbook_oracle_id: String,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = oracle_bound, primary_key(event_digest))]
pub struct OracleBound {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub propbook_underlying_id: i64,
    pub oracle_kind: i16,
    pub source_id: i64,
    pub propbook_oracle_id: String,
    pub value_kind: i16,
}

#[derive(Queryable, Selectable, Debug, Serialize)]
#[diesel(table_name = oracle_spot_1m)]
pub struct OracleSpot1m {
    pub propbook_oracle_id: String,
    pub expiry_ms: i64,
    pub bucket_ms: i64,
    pub open: BigDecimal,
    pub high: BigDecimal,
    pub low: BigDecimal,
    pub close: BigDecimal,
    pub forward: BigDecimal,
    pub update_count: i64,
}
