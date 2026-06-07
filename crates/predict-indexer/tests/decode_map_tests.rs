//! Decode + `map()` unit tests for the Predict order-event handlers.
//!
//! Stubbed this round (fixture-free): each test will build a decode struct +
//! `PredictEventMeta::for_test(...)`, call the handler's `map()`, and assert the
//! resulting Row fields (u256 -> decimal string, ids -> canonical 0x,
//! tx_index/event_index, Option handling, NUMERIC vs BIGINT columns).

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn order_minted_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (u256->decimal string, tx_index/event_index, Option handling).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn live_order_redeemed_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (u256->decimal string, tx_index/event_index, Option handling).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn settled_order_redeemed_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (u256->decimal string, tx_index/event_index, Option handling).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn liquidated_order_redeemed_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (u256->decimal string, tx_index/event_index, Option handling).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn order_liquidated_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (u256->decimal string, tx_index/event_index, Option handling).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn predict_manager_created_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (ids -> canonical 0x, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn builder_code_created_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (ids -> canonical 0x, builder_code_index NUMERIC, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn builder_code_set_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (ids -> canonical 0x, builder_code_id Option handling, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn predict_trade_cap_minted_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (ids -> canonical 0x, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn predict_deposit_cap_minted_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (ids -> canonical 0x, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn predict_withdraw_cap_minted_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (ids -> canonical 0x, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn pricing_config_updated_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (config id -> canonical 0x, *_freshness_ms BIGINT, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn fee_config_updated_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (config id -> canonical 0x, protocol_reserve_profit_share BIGINT, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn risk_config_updated_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (config id -> canonical 0x, liquidation budgets BIGINT, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn expiry_cash_template_config_updated_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (config id -> canonical 0x, trading_loss_rebate_rate BIGINT, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn strike_exposure_template_config_updated_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (config id -> canonical 0x, fee/ask-price NUMERIC, index/ltv/window/multiplier BIGINT, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn market_oracle_template_config_updated_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (config id -> canonical 0x, deviations/freshness BIGINT, min/max basis NUMERIC, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn ewma_config_updated_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (config id -> canonical 0x, alpha/z_score BIGINT, additional_fee NUMERIC, enabled BOOLEAN, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn stake_config_updated_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (config id -> canonical 0x, benefit powers NUMERIC, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn trading_paused_updated_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (config id -> canonical 0x, paused BOOLEAN, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn market_created_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (4 ids -> canonical 0x in expiry_market/market_oracle/pool_vault/pyth_source order, pyth_lazer_feed_id/expiry BIGINT, strike grid NUMERIC, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn market_config_snapshot_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (expiry_market_id THEN market_oracle_id -> canonical 0x, fee/ask-price NUMERIC, index/ltv/window/multiplier/rebate BIGINT, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn market_oracle_bounds_updated_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (oracle id -> canonical 0x, deviations/freshness BIGINT, min/max basis NUMERIC, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn expiry_market_mint_paused_updated_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (expiry_market_id -> canonical 0x, paused BOOLEAN, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn block_scholes_prices_updated_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (market_oracle_id -> canonical 0x, spot/forward/basis NUMERIC, source/update_timestamp_ms BIGINT, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn block_scholes_svi_updated_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (market_oracle_id -> canonical 0x, a/b/sigma NUMERIC, rho/m signed NUMERIC from I64 magnitude/is_negative incl. a negative case, source/update_timestamp_ms BIGINT, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn pyth_source_updated_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (pyth_source_id -> canonical 0x, feed_id BIGINT (u32), spot NUMERIC, source/update_timestamp_ms BIGINT, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn market_oracle_settled_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (market_oracle_id -> canonical 0x, expiry BIGINT, settlement_price NUMERIC, spot_source SMALLINT (u8), source/update_timestamp_ms BIGINT, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn supply_executed_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (pool_vault_id -> canonical 0x, payment/shares_minted/pool_value_before/incentive_value/total_supply_after/idle_balance_after NUMERIC, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn withdraw_executed_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (pool_vault_id -> canonical 0x, shares_burned/payout/pool_value_before/total_supply_after/idle_balance_after NUMERIC, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn expiry_cash_rebalanced_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (pool_vault_id THEN expiry_market_id -> canonical 0x, amount/target_cash/expiry_cash_after/idle_balance_after/sent_to_expiry_after/received_from_expiry_after NUMERIC, to_expiry BOOLEAN between amount and target_cash, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn expiry_max_funding_updated_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (pool_vault_id THEN expiry_market_id -> canonical 0x, max_expiry_funding/net_funding NUMERIC, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn expiry_cash_received_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (pool_vault_id THEN expiry_market_id -> canonical 0x, settlement_price/amount/idle_balance_after/sent_to_expiry_after/received_from_expiry_after NUMERIC, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn expiry_profit_materialized_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (pool_vault_id THEN expiry_market_id -> canonical 0x, lp_profit/protocol_profit/idle_balance_after/protocol_reserve_balance_after/profit_basis_after NUMERIC, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn deep_staked_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (pool_vault_id THEN predict_manager_id -> canonical 0x, amount/active_stake_after/inactive_stake_after NUMERIC, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn deep_unstaked_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (pool_vault_id THEN predict_manager_id -> canonical 0x, amount NUMERIC, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn builder_fees_claimed_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (builder_code_id -> canonical 0x, owner -> canonical 0x address, amount NUMERIC, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn trading_loss_rebate_claimed_map() {
    // TODO(testnet-deploy): build a decode struct + PredictEventMeta::for_test(...), call map(), assert the Row fields (expiry_market_id THEN predict_manager_id -> canonical 0x, trading_fees_paid/gross_profit/eligible_rebate/rebate_amount NUMERIC, tx_index/event_index).
}
