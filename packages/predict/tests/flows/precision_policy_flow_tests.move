// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Production-flow coverage for numerical precision admission policy.
#[test_only]
module deepbook_predict::precision_policy_flow_tests;

use deepbook_predict::{
    config_constants,
    constants,
    flow_test_helpers as helpers,
    pricing::Pricer,
    range_codec,
    strike_exposure,
    test_constants
};
use fixed_math::{approx::Approx, math};

const EUnexpectedSuccess: u64 = 999;
// The ratified contract-price deviation bound at 1e9 scale (0.1%), mirroring
// `strike_exposure::max_contract_price_deviation`.
const CONTRACT_MAX_DEVIATION: u64 = 1_000_000;

#[test]
fun extreme_surface_is_admissible_but_not_numerically_certifiable() {
    let (mut fx, expiry_id, _trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    seed_uncertifiable_surface(&mut fx, &mut market);
    let price = atm_up_price(&fx.load_pricer_bundle(&market));
    assert!(price.magnitude() >= config_constants::default_min_entry_probability!());
    assert!(price.magnitude() <= config_constants::default_max_entry_probability!());
    assert!(!price.deviation_within(CONTRACT_MAX_DEVIATION));

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun production_mint_accepts_a_certified_default_price() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let price = atm_up_price(&fx.load_pricer_bundle(&market));
    assert!(price.deviation_within(CONTRACT_MAX_DEVIATION));

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

#[test, expected_failure(abort_code = strike_exposure::EPriceTooImprecise)]
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

fun atm_up_price(pricer: &Pricer): Approx {
    pricer.range_price_approx(
        range_codec::strike_from_tick(
            helpers::strike_tick(),
            test_constants::default_tick_size(),
        ),
        range_codec::strike_from_tick(
            constants::pos_inf_tick!(),
            test_constants::default_tick_size(),
        ),
    )
}
