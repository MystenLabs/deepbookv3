// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Public-flow coverage for nonzero confidence loading on mint and live redeem.
#[test_only]
module deepbook_predict::confidence_fee_flow_tests;

use deepbook_predict::{
    config_constants,
    constants,
    expiry_market,
    flow_test_helpers as helpers,
    pricing,
    range_codec::strike_for_testing as strike,
    test_constants
};
use dusdc::dusdc::DUSDC;
use fixed_math::math;
use std::unit_test::assert_eq;

#[test]
fun confidence_loading_is_charged_and_settled_on_mint_and_redeem() {
    let expiry_ms = test_constants::now_ms() + constants::one_minute_ms!();
    let (mut fx, expiry_id, trader) = helpers::setup_confidence_fee_live_market(
        expiry_ms,
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let quote = fx.quote_mint_bundle(
        &market,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    let minimum_fee_amount = math::mul_down(
        config_constants::default_min_fee!(),
        test_constants::mint_quantity(),
    );
    assert!(quote.trading_fee() > minimum_fee_amount);
    let balance_before_mint = fx.account_balance_bundle<DUSDC>(&account);
    let cash_before_mint = helpers::market(&market).cash_balance();
    let order_id = fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
        quote.all_in_cost(),
        std::u64::max_value!(),
    );
    assert_eq!(
        fx.account_balance_bundle<DUSDC>(&account),
        balance_before_mint - quote.all_in_cost(),
    );
    assert_eq!(
        helpers::market(&market).cash_balance(),
        cash_before_mint + quote.net_premium() + quote.trading_fee(),
    );

    fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
    let pricer = fx.load_pricer_bundle(&market);
    let lower = strike(test_constants::default_live_price());
    let higher = strike(constants::pos_inf!());
    let probability = pricer.range_price(lower, higher);
    let loading = pricing::loading(
        &pricer,
        lower,
        higher,
        probability,
        config_constants::default_confidence_fee_reference_sensitivity!(),
    );
    let multiplier =
        math::float_scaling!() + math::mul_down(config_constants::default_fee_slope!(), loading);
    let fee_rate = math::mul_down(config_constants::default_min_fee!(), multiplier).min(
        config_constants::default_fee_cap!(),
    );
    let expected_fee = math::mul_down(fee_rate, test_constants::mint_quantity());
    let gross_redeem = math::mul_down(probability, test_constants::mint_quantity());
    assert!(expected_fee > minimum_fee_amount);

    let balance_before_redeem = fx.account_balance_bundle<DUSDC>(&account);
    let cash_before_redeem = helpers::market(&market).cash_balance();
    let (_closed, replacement) = fx.redeem_bundle(
        &mut market,
        &mut account,
        order_id,
        test_constants::mint_quantity(),
    );
    assert!(replacement.is_none());
    assert_eq!(
        fx.account_balance_bundle<DUSDC>(&account),
        balance_before_redeem + gross_redeem - expected_fee,
    );
    assert_eq!(
        helpers::market(&market).cash_balance(),
        cash_before_redeem - gross_redeem + expected_fee,
    );

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}
