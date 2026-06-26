// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Active flow coverage for sponsor-funded Predict fee incentives.
#[test_only]
module deepbook_predict::fee_incentive_flow_tests;

use deepbook_predict::{constants, flow_test_helpers as helpers, plp, test_constants};
use dusdc::dusdc::DUSDC;
use std::unit_test::assert_eq;
use sui::coin;

/// Sponsor amount deliberately above the minimum sponsorship and below the
/// per-market live target, so one rebalance allocates it all.
const SPONSOR_AMOUNT: u64 = 20_000_000;

#[test]
fun sponsor_fee_incentives_increases_reserve_without_idle_nav() {
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    fx.scenario_mut().next_tx(test_constants::admin());
    let (pyth, bs, oracle_registry, mut vault, market, config) = fx.take_market(expiry_id);
    let payment = coin::mint_for_testing<DUSDC>(SPONSOR_AMOUNT, fx.scenario_mut().ctx());

    vault.sponsor_fee_incentives(&config, payment, fx.scenario_mut().ctx());

    assert_eq!(vault.fee_incentive_reserve(), SPONSOR_AMOUNT);
    assert_eq!(vault.idle_balance(), 0);
    assert_eq!(vault.plp_total_supply(), 0);
    helpers::return_market(pyth, bs, oracle_registry, vault, market, config);
    fx.finish();
}

#[test, expected_failure(abort_code = plp::EBelowMinFeeIncentiveSponsorship)]
fun sponsor_fee_incentives_below_minimum_aborts() {
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    fx.scenario_mut().next_tx(test_constants::admin());
    let (_pyth, _bs, _oracle_registry, mut vault, _market, config) = fx.take_market(expiry_id);
    let payment = coin::mint_for_testing<DUSDC>(
        constants::min_fee_incentive_sponsorship!() - 1,
        fx.scenario_mut().ctx(),
    );

    vault.sponsor_fee_incentives(&config, payment, fx.scenario_mut().ctx());

    abort 999
}

#[test]
fun live_rebalance_allocates_fee_incentives_without_cash_top_up() {
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    fx.scenario_mut().next_tx(test_constants::admin());
    let (pyth, bs, oracle_registry, mut vault, mut market, config) = fx.take_market(expiry_id);
    let payment = coin::mint_for_testing<DUSDC>(SPONSOR_AMOUNT, fx.scenario_mut().ctx());
    vault.sponsor_fee_incentives(&config, payment, fx.scenario_mut().ctx());

    fx.rebalance_expiry_cash(&mut vault, &mut market, &config, &oracle_registry, &pyth);

    assert_eq!(vault.fee_incentive_reserve(), 0);
    assert_eq!(vault.idle_balance(), 0);
    assert_eq!(market.fee_incentive_balance(), SPONSOR_AMOUNT);
    assert_eq!(market.cash_balance(), 0);
    helpers::return_market(pyth, bs, oracle_registry, vault, market, config);
    fx.finish();
}
