// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The delayed-execution cutover and the placement gates that run before the
/// market's order book is touched.
///
/// Before the watermark bump the immediate mint and live-redeem paths keep
/// working and queued placement refuses (`ECutoverNotReached`); after it the four
/// retired paths abort `EDelayedExecutionRequired`. Placement then needs the
/// policy, refuses under the freeze and inside the flush's snapshot stage, and
/// refuses mints (only) under the trading and market mint pauses.
#[test_only]
module deepbook_predict::enqueue_cutover_tests;

use deepbook_predict::{
    constants,
    enqueue_test_helpers as enqueue,
    expiry_market,
    flow_test_helpers as helpers,
    protocol_config,
    queue_test_helpers as queue,
    test_constants
};
use std::unit_test::assert_eq;

/// Premium budget for the immediate premium-budget mint: 100 USDC.
const AMOUNT_PREMIUM: u64 = 100_000_000;
/// All-in cap for the immediate premium-budget mint: 200 USDC.
const AMOUNT_MAX_COST: u64 = 200_000_000;
/// All-in budget for the immediate all-in-cost mint: 100 USDC.
const COST_BUDGET: u64 = 100_000_000;
/// Slippage floor that accepts any fill.
const NO_MIN_QUANTITY: u64 = 0;
/// All-in cap for a queued exact-quantity mint of `mint_quantity` (1_000
/// contracts near 0.5): 600 USDC covers premium and fee.
const QUEUED_MAX_COST: u64 = 600_000_000;
/// A record ID no order has used. The gates under test fire before it is read.
const UNUSED_RECORD_ID: u64 = 1;
/// A close-side floor (`min_probability`, `min_proceeds`) that is disabled.
const NO_FLOOR: u64 = 0;
/// Locked LP capital so the pool can start a flush: 10 USDC.
const SUPPLY_AMOUNT: u64 = 10_000_000;

// === Before the cutover ===

/// While the watermark still names the previous version, all four immediate
/// paths run: three mint shapes, then a full live close.
#[test]
fun immediate_paths_still_work_before_the_cutover() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    // The fixture models the window between the upgrade and its bump.
    assert_eq!(market.config().version_watermark(), constants::current_version!() - 1);

    let quantity_order = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        test_constants::mint_quantity(),
    );
    let amount_order = fx.mint_exact_amount_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        AMOUNT_PREMIUM,
        NO_MIN_QUANTITY,
        AMOUNT_MAX_COST,
    );
    let cost_order = fx.mint_exact_cost_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        COST_BUDGET,
        NO_MIN_QUANTITY,
    );
    assert!(helpers::has_position_bundle(&account, expiry_id, quantity_order));
    assert!(helpers::has_position_bundle(&account, expiry_id, amount_order));
    assert!(helpers::has_position_bundle(&account, expiry_id, cost_order));

    // A live close in a later millisecond than its mint.
    fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
    let replacement = fx.redeem_live_bundle(
        &mut market,
        &mut account,
        quantity_order,
        test_constants::mint_quantity(),
    );
    assert!(replacement.is_none());
    assert!(!helpers::has_position_bundle(&account, expiry_id, quantity_order));
    // None of it went through the queue.
    let (_, next_id, _, _) = market.market().queue_heads();
    assert_eq!(next_id, 0);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// Queued placement waits for the watermark bump, even with the policy written.
#[test, expected_failure(abort_code = protocol_config::ECutoverNotReached)]
fun enqueue_before_the_cutover_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.init_delayed_execution();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    queue::enqueue_exact_quantity(
        &mut fx,
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        test_constants::mint_quantity(),
        QUEUED_MAX_COST,
        std::u64::max_value!(),
    );
    abort 999
}

// === After the cutover: the retired immediate paths ===

#[test, expected_failure(abort_code = expiry_market::EDelayedExecutionRequired)]
fun mint_exact_quantity_aborts_after_the_cutover() {
    let (mut fx, expiry_id, trader) = queue::setup_queue_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        test_constants::mint_quantity(),
    );
    abort 999
}

#[test, expected_failure(abort_code = expiry_market::EDelayedExecutionRequired)]
fun mint_exact_amount_aborts_after_the_cutover() {
    let (mut fx, expiry_id, trader) = queue::setup_queue_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.mint_exact_amount_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        AMOUNT_PREMIUM,
        NO_MIN_QUANTITY,
        AMOUNT_MAX_COST,
    );
    abort 999
}

#[test, expected_failure(abort_code = expiry_market::EDelayedExecutionRequired)]
fun mint_exact_cost_aborts_after_the_cutover() {
    let (mut fx, expiry_id, trader) = queue::setup_queue_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.mint_exact_cost_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        COST_BUDGET,
        NO_MIN_QUANTITY,
    );
    abort 999
}

/// A position minted before the cutover can no longer be closed immediately.
#[test, expected_failure(abort_code = expiry_market::EDelayedExecutionRequired)]
fun redeem_live_aborts_after_the_cutover() {
    let (mut fx, expiry_id, trader, order_id) = enqueue::setup_queue_market_with_position(
        test_constants::default_expiry_ms(),
        test_constants::mint_quantity(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.redeem_live_bundle(&mut market, &mut account, order_id, test_constants::mint_quantity());
    abort 999
}

// === After the cutover: gates before the book ===

#[test, expected_failure(abort_code = protocol_config::EPolicyNotInitialized)]
fun enqueue_without_the_policy_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.cutover();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    queue::enqueue_exact_quantity(
        &mut fx,
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        test_constants::mint_quantity(),
        QUEUED_MAX_COST,
        std::u64::max_value!(),
    );
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EProtocolFrozen)]
fun enqueue_mint_under_the_freeze_aborts() {
    let (mut fx, expiry_id, trader) = queue::setup_queue_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.set_frozen_bundle(&mut market, true);
    queue::enqueue_exact_quantity(
        &mut fx,
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        test_constants::mint_quantity(),
        QUEUED_MAX_COST,
        std::u64::max_value!(),
    );
    abort 999
}

/// Sells stay open under both pauses, but not under the freeze.
#[test, expected_failure(abort_code = protocol_config::EProtocolFrozen)]
fun enqueue_sell_under_the_freeze_aborts() {
    let (mut fx, expiry_id, trader) = queue::setup_queue_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.set_frozen_bundle(&mut market, true);
    queue::enqueue_redeem_open(
        &mut fx,
        &mut market,
        &mut account,
        UNUSED_RECORD_ID,
        test_constants::mint_quantity(),
        NO_FLOOR,
        NO_FLOOR,
    );
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::ETradingPaused)]
fun enqueue_mint_under_the_trading_pause_aborts() {
    let (mut fx, expiry_id, trader) = queue::setup_queue_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.set_trading_paused_bundle(&mut market, true);
    queue::enqueue_exact_cost(
        &mut fx,
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        COST_BUDGET,
        NO_MIN_QUANTITY,
    );
    abort 999
}

#[test, expected_failure(abort_code = expiry_market::EMintPaused)]
fun enqueue_mint_under_the_market_mint_pause_aborts() {
    let (mut fx, expiry_id, trader) = queue::setup_queue_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.set_expiry_mint_paused_bundle(&mut market, true);
    queue::enqueue_exact_amount(
        &mut fx,
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        AMOUNT_PREMIUM,
        NO_MIN_QUANTITY,
        AMOUNT_MAX_COST,
    );
    abort 999
}

/// A mint composed into the keeper's open snapshot stage is refused, as on the
/// immediate paths.
#[test, expected_failure(abort_code = protocol_config::ESnapshotInProgress)]
fun enqueue_mint_inside_the_snapshot_stage_aborts() {
    let (mut fx, expiry_id, trader) = queue::setup_queue_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.bootstrap_lock(SUPPLY_AMOUNT);
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let _stage = fx.start_flush_bundle_stage(&mut market);
    queue::enqueue_exact_quantity(
        &mut fx,
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        test_constants::mint_quantity(),
        QUEUED_MAX_COST,
        std::u64::max_value!(),
    );
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::ESnapshotInProgress)]
fun enqueue_sell_inside_the_snapshot_stage_aborts() {
    let (mut fx, expiry_id, trader) = queue::setup_queue_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.bootstrap_lock(SUPPLY_AMOUNT);
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let _stage = fx.start_flush_bundle_stage(&mut market);
    queue::enqueue_redeem_open(
        &mut fx,
        &mut market,
        &mut account,
        UNUSED_RECORD_ID,
        test_constants::mint_quantity(),
        NO_FLOOR,
        NO_FLOOR,
    );
    abort 999
}
