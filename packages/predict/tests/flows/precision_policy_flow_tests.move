// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Production-flow coverage for numerical precision admission policy.
#[test_only]
module deepbook_predict::precision_policy_flow_tests;

use deepbook_predict::{
    config_constants,
    constants,
    flow_test_helpers as helpers,
    pricing,
    range_codec::{Self, Strike},
    test_constants
};
use fixed_math::math;
use std::unit_test::assert_eq;

const EUnexpectedSuccess: u64 = 999;

/// The extreme surface still sits inside the economic entry-probability band, so
/// the numerical gate is what rejects it, not mint admission policy. The rejection
/// itself is pinned by `uncertifiable_price_is_not_admitted`.
#[test]
fun extreme_surface_stays_inside_the_economic_admission_band() {
    let (mut fx, expiry_id, _trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    seed_uncertifiable_surface(&mut fx, &mut market);
    let (lower, higher) = atm_range();
    let price = fx.load_pricer_bundle(&market).range_price(lower, higher);
    assert!(price >= config_constants::default_min_entry_probability!());
    assert!(price <= config_constants::default_max_entry_probability!());

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test, expected_failure(abort_code = pricing::EPriceTooImprecise)]
fun uncertifiable_price_is_not_admitted() {
    let (mut fx, expiry_id, _trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    seed_uncertifiable_surface(&mut fx, &mut market);
    let (lower, higher) = atm_range();
    fx.load_pricer_bundle(&market).admitted_range_price(lower, higher);
    abort EUnexpectedSuccess
}

#[test]
fun production_mint_accepts_a_certified_default_price() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    // The default surface is certifiable: admission returns the canonical center
    // rather than aborting, which is the precondition the mint below relies on.
    let (lower, higher) = atm_range();
    let pricer = fx.load_pricer_bundle(&market);
    assert_eq!(pricer.admitted_range_price(lower, higher), pricer.range_price(lower, higher));

    let order_id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    assert!(helpers::has_position_bundle(&account, expiry_id, order_id));

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test, expected_failure(abort_code = pricing::EPriceTooImprecise)]
fun production_mint_rejects_an_uncertifiable_price() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    seed_uncertifiable_surface(&mut fx, &mut market);

    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    abort EUnexpectedSuccess
}

fun seed_uncertifiable_surface(fx: &mut helpers::Fixture, market: &mut helpers::MarketBundle) {
    fx.seed_bs_surface_with_svi_bundle(
        market,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        1,
        false,
        test_constants::pricing_max_svi_input(),
        test_constants::pricing_min_svi_sigma(),
        math::float_scaling!(),
        true,
        test_constants::pricing_max_svi_input(),
        true,
        test_constants::live_source_timestamp_ms() + 1,
    );
}

/// The at-the-money `(strike, +inf]` range every test in this module prices.
fun atm_range(): (Strike, Strike) {
    (
        range_codec::strike_from_tick(helpers::strike_tick(), test_constants::default_tick_size()),
        range_codec::strike_from_tick(
            constants::pos_inf_tick!(),
            test_constants::default_tick_size(),
        ),
    )
}
