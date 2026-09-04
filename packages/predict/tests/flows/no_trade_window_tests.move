// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Flow coverage for the pre-expiry no-trade window. Inside it every live flow
/// aborts — both quote entrypoints, both mint entrypoints, and `redeem_live` —
/// while settlement and settled redemption stay open, so a blocked close is
/// delayed rather than stranded. Pins the boundary in both directions, that a
/// zero window disables the block, and that the guard reads the configured
/// window rather than the compiled default.
#[test_only]
module deepbook_predict::no_trade_window_tests;

use deepbook_predict::{constants, flow_test_helpers as helpers, protocol_config, test_constants};
use std::unit_test::assert_eq;

/// Lot-aligned position size, matching the other flow suites.
const QUANTITY: u64 = 840_000_000;
/// Compiled default window, asserted as a literal so a retune has to edit this
/// file consciously — the convention `defaults_are_the_deployed_values` uses.
const WINDOW_MS: u64 = 2_000;

// === Every live flow is blocked inside the window ===

#[test, expected_failure(abort_code = protocol_config::ETradeWindowClosed)]
fun mint_exact_quantity_inside_the_window_aborts() {
    let expiry = test_constants::short_expiry_ms();
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        expiry,
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // 1_000ms remaining against a 2_000ms window.
    fx.advance_live_oracle_bundle_to(
        &mut market,
        test_constants::default_live_price(),
        expiry - 1_000,
    );
    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
    );

    abort 999
}

#[test, expected_failure(abort_code = protocol_config::ETradeWindowClosed)]
fun mint_exact_amount_inside_the_window_aborts() {
    let expiry = test_constants::short_expiry_ms();
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        expiry,
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    fx.advance_live_oracle_bundle_to(
        &mut market,
        test_constants::default_live_price(),
        expiry - 1_000,
    );
    fx.mint_exact_amount_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
        0,
        std::u64::max_value!(),
    );

    abort 999
}

#[test, expected_failure(abort_code = protocol_config::ETradeWindowClosed)]
fun quote_mint_inside_the_window_aborts() {
    let expiry = test_constants::short_expiry_ms();
    let (mut fx, expiry_id, _trader) = helpers::setup_live_market(
        expiry,
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);

    fx.advance_live_oracle_bundle_to(
        &mut market,
        test_constants::default_live_price(),
        expiry - 1_000,
    );
    fx.quote_mint_bundle(&market, helpers::strike_tick(), constants::pos_inf_tick!(), QUANTITY);

    abort 999
}

#[test, expected_failure(abort_code = protocol_config::ETradeWindowClosed)]
fun quote_mint_for_account_inside_the_window_aborts() {
    let expiry = test_constants::short_expiry_ms();
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        expiry,
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let account = fx.take_account_bundle(&trader);

    fx.advance_live_oracle_bundle_to(
        &mut market,
        test_constants::default_live_price(),
        expiry - 1_000,
    );
    fx.quote_mint_for_account_bundle(
        &market,
        &account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
    );

    abort 999
}

#[test, expected_failure(abort_code = protocol_config::ETradeWindowClosed)]
fun redeem_live_inside_the_window_aborts() {
    let expiry = test_constants::short_expiry_ms();
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        expiry,
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // Open well outside the window, then try to close inside it.
    let order = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
    );
    fx.advance_live_oracle_bundle_to(
        &mut market,
        test_constants::default_live_price(),
        expiry - 1_000,
    );
    fx.redeem_live_bundle(&mut market, &mut account, order, QUANTITY);

    abort 999
}

// === The window delays a close; it does not strand one ===

#[test]
fun a_position_blocked_from_closing_is_redeemable_after_settlement() {
    let expiry = test_constants::short_expiry_ms();
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        expiry,
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let order = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
    );

    // `redeem_live_inside_the_window_aborts` pins that this holder cannot close
    // inside the window. Settlement and settled redemption take paths the guard
    // does not sit on, so the position resolves on its own terms instead.
    fx.set_clock_for_testing(expiry);
    fx.insert_exact_settlement_spot_bundle(&mut market, test_constants::default_live_price());
    assert_eq!(fx.try_settle_bundle(&mut market), true);
    fx.redeem_settled_bundle(&mut market, &mut account, order);
    assert!(!helpers::has_position_bundle(&account, expiry_id, order));

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

// === Boundary, in both directions ===

#[test, expected_failure(abort_code = protocol_config::ETradeWindowClosed)]
fun mint_exactly_at_the_window_edge_aborts() {
    let expiry = test_constants::short_expiry_ms();
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        expiry,
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // Remaining == window: the far edge is inclusive, so this is blocked.
    fx.advance_live_oracle_bundle_to(
        &mut market,
        test_constants::default_live_price(),
        expiry - WINDOW_MS,
    );
    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
    );

    abort 999
}

#[test]
fun mint_one_ms_outside_the_window_succeeds() {
    let expiry = test_constants::short_expiry_ms();
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        expiry,
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // Remaining == window + 1: the first millisecond that still trades. Paired
    // with the edge test above, this pins the comparison rather than the region.
    fx.advance_live_oracle_bundle_to(
        &mut market,
        test_constants::default_live_price(),
        expiry - WINDOW_MS - 1,
    );
    let order = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
    );
    assert!(helpers::has_position_bundle(&account, expiry_id, order));

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

// === The guard reads the configured window, not the default ===

#[test]
fun a_zero_window_disables_the_block() {
    let expiry = test_constants::short_expiry_ms();
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        expiry,
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    fx.set_no_trade_window_bundle(&mut market, 0);
    assert_eq!(market.config().no_trade_window_ms(), 0);

    // One millisecond to expiry still mints with the block disabled.
    fx.advance_live_oracle_bundle_to(&mut market, test_constants::default_live_price(), expiry - 1);
    let order = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
    );
    assert!(helpers::has_position_bundle(&account, expiry_id, order));

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// Paired with `a_widened_window_blocks_further_out`: same market, same clock,
/// opposite outcome. Together they prove the guard reads the configured window
/// rather than the compiled default, which every other test here would pass on.
#[test]
fun the_default_window_allows_a_mint_ten_seconds_out() {
    let expiry = test_constants::short_expiry_ms();
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        expiry,
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    fx.advance_live_oracle_bundle_to(
        &mut market,
        test_constants::default_live_price(),
        expiry - 10_000,
    );
    let order = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
    );
    assert!(helpers::has_position_bundle(&account, expiry_id, order));

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test, expected_failure(abort_code = protocol_config::ETradeWindowClosed)]
fun a_widened_window_blocks_further_out() {
    let expiry = test_constants::short_expiry_ms();
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        expiry,
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // At the ceiling the block reaches 15s out, where the default 2s does not.
    fx.set_no_trade_window_bundle(&mut market, 15_000);
    fx.advance_live_oracle_bundle_to(
        &mut market,
        test_constants::default_live_price(),
        expiry - 10_000,
    );
    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
    );

    abort 999
}
