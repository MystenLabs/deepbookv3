//! Decode + `map()` unit tests for the Predict raw-event handlers.
//!
//! Two kinds of test live here:
//!  * Real `map()` assertions for the async-LP and settlement handlers added in
//!    the oracle-extraction rework: build a decode struct +
//!    `PredictEventMeta::for_test(...)`, call the handler's free `map()`, and
//!    assert the resulting Row fields (ids -> canonical 0x, u64 -> decimal
//!    string for NUMERIC / i64 for BIGINT, the event header triple).
//!  * `#[ignore]`'d fixture-free stubs for the remaining handlers, filled in
//!    once a testnet `.chk` fixture exists (TODO(testnet-deploy)).
//!
//! Oracle events (Pyth spot / Block Scholes surface / source registration /
//! settlement) moved to the standalone oracle-indexer crate and are NOT decoded
//! here, so they have no tests.

use bigdecimal::BigDecimal;
use predict_indexer::handlers::{
    flush_executed_handler, market_settled_handler, request_cancelled_handler,
    supply_filled_handler, supply_requested_handler, withdraw_filled_handler,
    withdraw_requested_handler,
};
use predict_indexer::meta::PredictEventMeta;
use predict_indexer::models::{
    FlushExecuted, MarketSettled, RequestCancelled, SupplyFilled, SupplyRequested, WithdrawFilled,
    WithdrawRequested,
};
use sui_types::base_types::ObjectID;

// Full-length ids so ObjectID/Address round-trip to the exact same literal.
const MARKET_ID: &str = "0x1111111111111111111111111111111111111111111111111111111111111111";
const VAULT_ID: &str = "0x2222222222222222222222222222222222222222222222222222222222222222";
const MANAGER_ID: &str = "0x3333333333333333333333333333333333333333333333333333333333333333";
const RECIPIENT: &str = "0x4444444444444444444444444444444444444444444444444444444444444444";

/// A `PredictEventMeta` with a distinct-but-deterministic timestamp
/// (`1_000_000 + checkpoint`) so header assertions are exact.
fn meta(checkpoint: i64, tx_index: i64, event_index: usize) -> PredictEventMeta {
    PredictEventMeta::for_test(
        "digest",
        "sender",
        checkpoint,
        tx_index,
        1_000_000 + checkpoint,
        event_index,
        "0xpkg",
    )
}

// === Real map() tests for the new raw-event handlers ===

#[test]
fn market_settled_map() {
    let ev = MarketSettled {
        expiry_market_id: ObjectID::from_hex_literal(MARKET_ID).unwrap(),
        propbook_underlying_id: 42,
        expiry: 1_700_000_000_000,
        settlement_price: 99_000_000_000_000,
        settled_at_ms: 1_700_000_123_000,
    };
    let row = market_settled_handler::map(&ev, &meta(10, 2, 3));

    assert_eq!(row.event_digest, "digest3");
    assert_eq!(row.expiry_market_id, MARKET_ID);
    assert_eq!(row.propbook_underlying_id, 42); // u32 -> BIGINT
    assert_eq!(row.expiry, 1_700_000_000_000);
    // settlement_price is NUMERIC (can carry the pos_inf sentinel) -> BigDecimal.
    assert_eq!(
        row.settlement_price,
        BigDecimal::from(99_000_000_000_000u64)
    );
    assert_eq!(row.settled_at_ms, 1_700_000_123_000);
    assert_eq!(row.checkpoint_timestamp_ms, 1_000_010);
    assert_eq!((row.checkpoint, row.tx_index, row.event_index), (10, 2, 3));
}

#[test]
fn supply_requested_map() {
    let ev = SupplyRequested {
        pool_vault_id: ObjectID::from_hex_literal(VAULT_ID).unwrap(),
        predict_manager_id: ObjectID::from_hex_literal(MANAGER_ID).unwrap(),
        recipient: RECIPIENT.parse().unwrap(),
        index: 7,
        amount: 100_000_000,
    };
    let row = supply_requested_handler::map(&ev, &meta(11, 0, 1));

    assert_eq!(row.pool_vault_id, VAULT_ID);
    assert_eq!(row.predict_manager_id, MANAGER_ID);
    assert_eq!(row.recipient, RECIPIENT);
    assert_eq!(row.request_index, 7); // event `index` -> request_index BIGINT
    assert_eq!(row.amount, BigDecimal::from(100_000_000u64));
    assert_eq!((row.checkpoint, row.tx_index, row.event_index), (11, 0, 1));
}

#[test]
fn withdraw_requested_map() {
    let ev = WithdrawRequested {
        pool_vault_id: ObjectID::from_hex_literal(VAULT_ID).unwrap(),
        predict_manager_id: ObjectID::from_hex_literal(MANAGER_ID).unwrap(),
        recipient: RECIPIENT.parse().unwrap(),
        index: 8,
        amount: 50_000_000,
    };
    let row = withdraw_requested_handler::map(&ev, &meta(12, 1, 0));

    assert_eq!(row.pool_vault_id, VAULT_ID);
    assert_eq!(row.predict_manager_id, MANAGER_ID);
    assert_eq!(row.recipient, RECIPIENT);
    assert_eq!(row.request_index, 8);
    assert_eq!(row.amount, BigDecimal::from(50_000_000u64));
    assert_eq!((row.checkpoint, row.tx_index, row.event_index), (12, 1, 0));
}

#[test]
fn request_cancelled_map() {
    let ev = RequestCancelled {
        pool_vault_id: ObjectID::from_hex_literal(VAULT_ID).unwrap(),
        predict_manager_id: ObjectID::from_hex_literal(MANAGER_ID).unwrap(),
        recipient: RECIPIENT.parse().unwrap(),
        index: 9,
        amount: 25_000_000,
        is_supply: false,
    };
    let row = request_cancelled_handler::map(&ev, &meta(13, 0, 2));

    assert_eq!(row.pool_vault_id, VAULT_ID);
    assert_eq!(row.predict_manager_id, MANAGER_ID);
    assert_eq!(row.recipient, RECIPIENT);
    assert_eq!(row.request_index, 9);
    assert_eq!(row.amount, BigDecimal::from(25_000_000u64));
    assert!(!row.is_supply);
    assert_eq!((row.checkpoint, row.tx_index, row.event_index), (13, 0, 2));
}

#[test]
fn supply_filled_map() {
    let ev = SupplyFilled {
        pool_vault_id: ObjectID::from_hex_literal(VAULT_ID).unwrap(),
        predict_manager_id: ObjectID::from_hex_literal(MANAGER_ID).unwrap(),
        recipient: RECIPIENT.parse().unwrap(),
        index: 7,
        dusdc_amount: 100_000_000,
        shares_minted: 99_000_000,
    };
    let row = supply_filled_handler::map(&ev, &meta(14, 2, 0));

    assert_eq!(row.pool_vault_id, VAULT_ID);
    assert_eq!(row.predict_manager_id, MANAGER_ID);
    assert_eq!(row.recipient, RECIPIENT);
    assert_eq!(row.request_index, 7);
    assert_eq!(row.dusdc_amount, BigDecimal::from(100_000_000u64));
    assert_eq!(row.shares_minted, BigDecimal::from(99_000_000u64));
    assert_eq!((row.checkpoint, row.tx_index, row.event_index), (14, 2, 0));
}

#[test]
fn withdraw_filled_map() {
    let ev = WithdrawFilled {
        pool_vault_id: ObjectID::from_hex_literal(VAULT_ID).unwrap(),
        predict_manager_id: ObjectID::from_hex_literal(MANAGER_ID).unwrap(),
        recipient: RECIPIENT.parse().unwrap(),
        index: 8,
        shares_burned: 99_000_000,
        dusdc_amount: 101_000_000,
    };
    let row = withdraw_filled_handler::map(&ev, &meta(15, 0, 0));

    assert_eq!(row.pool_vault_id, VAULT_ID);
    assert_eq!(row.predict_manager_id, MANAGER_ID);
    assert_eq!(row.recipient, RECIPIENT);
    assert_eq!(row.request_index, 8);
    assert_eq!(row.shares_burned, BigDecimal::from(99_000_000u64));
    assert_eq!(row.dusdc_amount, BigDecimal::from(101_000_000u64));
    assert_eq!((row.checkpoint, row.tx_index, row.event_index), (15, 0, 0));
}

#[test]
fn flush_executed_map() {
    let ev = FlushExecuted {
        pool_vault_id: ObjectID::from_hex_literal(VAULT_ID).unwrap(),
        epoch: 123,
        pool_value: 1_000_000_000,
        total_supply: 900_000_000,
        active_market_nav: 800_000_000,
        market_count: 3,
        idle_balance_before: 200_000_000,
        supplies_filled: 5,
        withdrawals_filled: 2,
        requests_processed: 7,
        idle_balance_after: 150_000_000,
    };
    let row = flush_executed_handler::map(&ev, &meta(16, 1, 4));

    assert_eq!(row.pool_vault_id, VAULT_ID);
    assert_eq!(row.epoch, 123); // bounded -> BIGINT
    assert_eq!(row.pool_value, BigDecimal::from(1_000_000_000u64));
    assert_eq!(row.total_supply, BigDecimal::from(900_000_000u64));
    assert_eq!(row.active_market_nav, BigDecimal::from(800_000_000u64));
    assert_eq!(row.market_count, 3);
    assert_eq!(row.idle_balance_before, BigDecimal::from(200_000_000u64));
    assert_eq!(row.supplies_filled, 5);
    assert_eq!(row.withdrawals_filled, 2);
    assert_eq!(row.requests_processed, 7);
    assert_eq!(row.idle_balance_after, BigDecimal::from(150_000_000u64));
    assert_eq!((row.checkpoint, row.tx_index, row.event_index), (16, 1, 4));
}

// === Fixture-free stubs (TODO(testnet-deploy)) ===
//
// Each will build a decode struct + `PredictEventMeta::for_test(...)`, call the
// handler's `map()`, and assert the resulting Row fields. Stubbed until a
// testnet `.chk` fixture exists.

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn order_minted_map() {
    // TODO(testnet-deploy): assert the Row fields (ids -> canonical 0x, lower_tick/higher_tick BIGINT, amounts NUMERIC, tx_index/event_index, Option handling).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn live_order_redeemed_map() {
    // TODO(testnet-deploy): assert the Row fields (u256 ids -> decimal string, replacement_order_id Option, amounts NUMERIC, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn settled_order_redeemed_map() {
    // TODO(testnet-deploy): assert the Row fields (u256 ids -> decimal string, settlement_price/payout_amount NUMERIC, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn liquidated_order_redeemed_map() {
    // TODO(testnet-deploy): assert the Row fields (u256 ids -> decimal string, quantity_closed NUMERIC, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn order_liquidated_map() {
    // TODO(testnet-deploy): assert the Row fields (expiry_market_id -> canonical 0x, gross_value/floor_amount NUMERIC, liquidation_ltv BIGINT, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn predict_manager_created_map() {
    // TODO(testnet-deploy): assert the Row fields (ids -> canonical 0x, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn builder_code_created_map() {
    // TODO(testnet-deploy): assert the Row fields (ids -> canonical 0x, builder_code_index NUMERIC, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn builder_code_set_map() {
    // TODO(testnet-deploy): assert the Row fields (ids -> canonical 0x, builder_code_id Option handling, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn predict_trade_cap_minted_map() {
    // TODO(testnet-deploy): assert the Row fields (ids -> canonical 0x, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn predict_deposit_cap_minted_map() {
    // TODO(testnet-deploy): assert the Row fields (ids -> canonical 0x, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn predict_withdraw_cap_minted_map() {
    // TODO(testnet-deploy): assert the Row fields (ids -> canonical 0x, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn pricing_config_updated_map() {
    // TODO(testnet-deploy): assert the Row fields (config id -> canonical 0x, pyth_spot_freshness_ms/block_scholes_surface_freshness_ms BIGINT, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn risk_config_updated_map() {
    // TODO(testnet-deploy): assert the Row fields (config id -> canonical 0x, trade_liquidation_budget/protocol_reserve_profit_share BIGINT, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn expiry_cash_template_config_updated_map() {
    // TODO(testnet-deploy): assert the Row fields (config id -> canonical 0x, trading_loss_rebate_rate BIGINT, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn strike_exposure_template_config_updated_map() {
    // TODO(testnet-deploy): assert the Row fields (config id -> canonical 0x, fee/ask-price NUMERIC, index/ltv/backing lambda/window/multiplier BIGINT, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn ewma_config_updated_map() {
    // TODO(testnet-deploy): assert the Row fields (config id -> canonical 0x, alpha/z_score BIGINT, penalty_rate NUMERIC, enabled BOOLEAN, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn stake_config_updated_map() {
    // TODO(testnet-deploy): assert the Row fields (config id -> canonical 0x, benefit powers NUMERIC, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn trading_paused_updated_map() {
    // TODO(testnet-deploy): assert the Row fields (config id -> canonical 0x, paused BOOLEAN, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn market_created_map() {
    // TODO(testnet-deploy): assert the Row fields (expiry_market/pool_vault ids -> canonical 0x, propbook_underlying_id/expiry BIGINT, tick_size NUMERIC, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn market_config_snapshot_map() {
    // TODO(testnet-deploy): assert the Row fields (expiry_market_id -> canonical 0x, fee/ask-price NUMERIC, index/ltv/backing lambda/window/multiplier/rebate BIGINT, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn expiry_market_mint_paused_updated_map() {
    // TODO(testnet-deploy): assert the Row fields (expiry_market_id -> canonical 0x, paused BOOLEAN, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn expiry_cash_rebalanced_map() {
    // TODO(testnet-deploy): assert the Row fields (pool_vault_id THEN expiry_market_id -> canonical 0x, amount/target_cash/expiry_cash_after/idle_balance_after/sent_to_expiry_after/received_from_expiry_after/protocol_reserve_balance_after/pending_protocol_profit_after NUMERIC, to_expiry BOOLEAN between amount and target_cash, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn expiry_cash_received_map() {
    // TODO(testnet-deploy): assert the Row fields (pool_vault_id THEN expiry_market_id -> canonical 0x, settlement_price/amount/idle_balance_after/sent_to_expiry_after/received_from_expiry_after NUMERIC, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn expiry_profit_materialized_map() {
    // TODO(testnet-deploy): assert the Row fields (pool_vault_id THEN expiry_market_id -> canonical 0x, lp_profit/protocol_profit/idle_balance_after/protocol_reserve_balance_after/profit_basis_after/pending_protocol_profit_after NUMERIC, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn deep_staked_map() {
    // TODO(testnet-deploy): assert the Row fields (pool_vault_id THEN predict_manager_id -> canonical 0x, amount/active_stake_after/inactive_stake_after NUMERIC, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn deep_unstaked_map() {
    // TODO(testnet-deploy): assert the Row fields (pool_vault_id THEN predict_manager_id -> canonical 0x, amount NUMERIC, tx_index/event_index).
}

#[test]
#[ignore = "TODO(testnet-deploy): assert map() output (fixture-free; fill in when revisiting tests)"]
fn builder_fees_claimed_map() {
    // TODO(testnet-deploy): assert the Row fields (builder_code_id -> canonical 0x, owner -> canonical 0x address, amount NUMERIC, tx_index/event_index).
}
