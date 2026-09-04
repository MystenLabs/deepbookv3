// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Flow coverage for the pre-expiry no-trade window: inside it, live quotes,
/// mints, and live redeems abort. Pins the boundary in both directions (the
/// window edge is blocked, one millisecond outside it is not), that a zero
/// window disables the block entirely, and that the block reaches all three
/// live flows rather than only the mint path they share.
#[test_only]
module deepbook_predict::no_trade_window_tests;

use deepbook_predict::{constants, flow_test_helpers as helpers, protocol_config, test_constants};
use std::unit_test::assert_eq;

/// Minute-aligned expiry close enough to the fixture clock (120_000) that the
/// window is reachable without a year of simulated time.
const NEAR_EXPIRY_MS: u64 = 180_000;
/// Lot-aligned position size, matching the other flow suites.
const QUANTITY: u64 = 840_000_000;
/// Compiled default window; the fixture does not override it.
const WINDOW_MS: u64 = 2_000;

/// Re-seeds the oracle at `source_ms` so the surface is fresh at `clock_ms`,
/// then leaves the fixture clock there. Without this the tightened Block Scholes
/// freshness bound would abort first and the window would never be reached.
fun advance_to(fx: &mut helpers::Fixture, market: &mut helpers::MarketBundle, clock_ms: u64) {
    fx.set_clock_for_testing(clock_ms);
    fx.prepare_live_oracle_bundle_at(market, test_constants::default_live_price(), clock_ms);
}

#[test, expected_failure(abort_code = protocol_config::ETradingHaltedNearExpiry)]
fun mint_inside_the_window_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        NEAR_EXPIRY_MS,
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // 1_000ms remaining against a 2_000ms window.
    advance_to(&mut fx, &mut market, NEAR_EXPIRY_MS - 1_000);
    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
    );

    abort 999
}

#[test, expected_failure(abort_code = protocol_config::ETradingHaltedNearExpiry)]
fun quote_inside_the_window_aborts() {
    let (mut fx, expiry_id, _trader) = helpers::setup_live_market(
        NEAR_EXPIRY_MS,
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);

    advance_to(&mut fx, &mut market, NEAR_EXPIRY_MS - 1_000);
    fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
    );

    abort 999
}

#[test, expected_failure(abort_code = protocol_config::ETradingHaltedNearExpiry)]
fun redeem_live_inside_the_window_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        NEAR_EXPIRY_MS,
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
    advance_to(&mut fx, &mut market, NEAR_EXPIRY_MS - 1_000);
    fx.redeem_live_bundle(&mut market, &mut account, order, QUANTITY);

    abort 999
}

#[test, expected_failure(abort_code = protocol_config::ETradingHaltedNearExpiry)]
fun mint_exactly_at_the_window_edge_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        NEAR_EXPIRY_MS,
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // Remaining == window: the far edge is inclusive, so this is blocked.
    advance_to(&mut fx, &mut market, NEAR_EXPIRY_MS - WINDOW_MS);
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
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        NEAR_EXPIRY_MS,
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // Remaining == window + 1: the first millisecond that still trades. Paired
    // with the edge test above, this pins the comparison rather than the region.
    advance_to(&mut fx, &mut market, NEAR_EXPIRY_MS - WINDOW_MS - 1);
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

#[test]
fun a_zero_window_disables_the_block() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        NEAR_EXPIRY_MS,
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    fx.set_no_trade_window_bundle(&mut market, 0);
    assert_eq!(market.config().no_trade_window_ms(), 0);

    // One millisecond to expiry still mints with the block disabled.
    advance_to(&mut fx, &mut market, NEAR_EXPIRY_MS - 1);
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
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        NEAR_EXPIRY_MS,
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    advance_to(&mut fx, &mut market, NEAR_EXPIRY_MS - 10_000);
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

#[test, expected_failure(abort_code = protocol_config::ETradingHaltedNearExpiry)]
fun a_widened_window_blocks_further_out() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        NEAR_EXPIRY_MS,
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // At the ceiling the block reaches 15s out, where the default 2s does not.
    fx.set_no_trade_window_bundle(&mut market, 15_000);
    advance_to(&mut fx, &mut market, NEAR_EXPIRY_MS - 10_000);
    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
    );

    abort 999
}
