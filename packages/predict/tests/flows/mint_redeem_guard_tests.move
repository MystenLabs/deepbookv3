// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Flow coverage for the same-timestamp mint -> redeem guard: a live order cannot
/// be redeemed in the timestamp it was opened (the lever that would let one
/// transaction mint, push the oracle, and redeem the freshly minted order against
/// the price it just pushed), but is redeemable once the clock advances.
#[test_only]
module deepbook_predict::mint_redeem_guard_tests;

use deepbook_predict::{constants, expiry_market, flow_test_helpers as helpers, test_constants};
use std::unit_test::assert_eq;

/// Lot-aligned position size minted in both tests.
const QUANTITY: u64 = 840_000_000;
/// 1x leverage in 1e9 fixed point: no floor, so no liquidation interaction.
const LEVERAGE_ONE_X: u64 = 1_000_000_000;
/// One second past the fixture's `now_ms()` open time — distinct timestamp, still
/// inside the oracle freshness window.
const REDEEM_MS: u64 = 121_000;
const REDEEM_SOURCE_TS: u64 = 120_000;
const MAX_COST_BELOW_QUOTE: u64 = 1;
const MAX_PROBABILITY_ZERO: u64 = 0;
const ZERO_NET_PREMIUM_AMOUNT: u64 = 0;
const MIN_PROBABILITY_CERTAIN: u64 = 1_000_000_000;
const MIN_PROBABILITY_DISABLED: u64 = 0;
const MIN_PROCEEDS_DISABLED: u64 = 0;

#[test, expected_failure(abort_code = expiry_market::EMintRedeemSameTimestamp)]
fun redeem_in_mint_timestamp_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
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
        LEVERAGE_ONE_X,
    );

    // Same fixture clock as the mint: the guard must reject this redeem.
    fx.redeem_bundle(
        &mut market,
        &mut account,
        order,
        QUANTITY,
    );

    abort 999
}

#[test, expected_failure(abort_code = expiry_market::EMintCostAboveMax)]
fun mint_exact_quantity_above_max_cost_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
        LEVERAGE_ONE_X,
        MAX_COST_BELOW_QUOTE,
        std::u64::max_value!(),
    );

    abort 999
}

#[test, expected_failure(abort_code = expiry_market::EMintProbabilityAboveMax)]
fun mint_exact_quantity_above_max_probability_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
        LEVERAGE_ONE_X,
        std::u64::max_value!(),
        MAX_PROBABILITY_ZERO,
    );

    abort 999
}

#[test, expected_failure(abort_code = expiry_market::EMintQuantityBelowMin)]
fun mint_exact_amount_below_min_quantity_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
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
        constants::pos_inf_tick!(),
        ZERO_NET_PREMIUM_AMOUNT,
        constants::position_lot_size!(),
        LEVERAGE_ONE_X,
    );

    abort 999
}

#[test, expected_failure(abort_code = expiry_market::ERedeemProbabilityBelowMin)]
fun redeem_below_min_probability_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
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
        LEVERAGE_ONE_X,
    );

    fx.set_clock_for_testing(REDEEM_MS);
    fx.prepare_live_oracle_bundle_at(
        &mut market,
        test_constants::default_live_price(),
        REDEEM_SOURCE_TS,
    );

    fx.redeem_bundle_with_limits(
        &mut market,
        &mut account,
        order,
        QUANTITY,
        MIN_PROBABILITY_CERTAIN,
        MIN_PROCEEDS_DISABLED,
    );

    abort 999
}

#[test, expected_failure(abort_code = expiry_market::ERedeemProceedsBelowMin)]
fun redeem_below_min_proceeds_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
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
        LEVERAGE_ONE_X,
    );

    fx.set_clock_for_testing(REDEEM_MS);
    fx.prepare_live_oracle_bundle_at(
        &mut market,
        test_constants::default_live_price(),
        REDEEM_SOURCE_TS,
    );

    fx.redeem_bundle_with_limits(
        &mut market,
        &mut account,
        order,
        QUANTITY,
        MIN_PROBABILITY_DISABLED,
        std::u64::max_value!(),
    );

    abort 999
}

#[test]
fun redeem_after_clock_advances_succeeds() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
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
        LEVERAGE_ONE_X,
    );
    assert!(helpers::has_position_bundle(&account, expiry_id, order));

    // Advance to a later timestamp and re-seed a fresh live oracle, then a full
    // close goes through and clears the position.
    fx.set_clock_for_testing(REDEEM_MS);
    fx.prepare_live_oracle_bundle_at(
        &mut market,
        test_constants::default_live_price(),
        REDEEM_SOURCE_TS,
    );

    let (closed, replacement) = fx.redeem_bundle(
        &mut market,
        &mut account,
        order,
        QUANTITY,
    );

    assert_eq!(closed, order);
    assert!(replacement.is_none());
    assert!(!helpers::has_position_bundle(&account, expiry_id, order));

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}
