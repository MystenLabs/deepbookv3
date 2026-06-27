// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Active flow coverage for sponsor-funded Predict fee incentives.
#[test_only]
module deepbook_predict::fee_incentive_flow_tests;

use deepbook_predict::{constants, flow_test_helpers as helpers, plp, test_constants};
use std::unit_test::assert_eq;

/// Sponsor amount deliberately above the minimum sponsorship and below the
/// per-market live target, so one rebalance allocates it all.
const SPONSOR_AMOUNT: u64 = 20_000_000;

#[test]
fun sponsor_fee_incentives_increases_reserve_without_idle_nav() {
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);

    fx.sponsor_fee_incentives_bundle(&mut market, SPONSOR_AMOUNT);

    assert_eq!(helpers::vault(&market).fee_incentive_reserve(), SPONSOR_AMOUNT);
    assert_eq!(helpers::vault(&market).idle_balance(), 0);
    assert_eq!(helpers::vault(&market).plp_total_supply(), 0);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test, expected_failure(abort_code = plp::EBelowMinFeeIncentiveSponsorship)]
fun sponsor_fee_incentives_below_minimum_aborts() {
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);

    fx.sponsor_fee_incentives_bundle(&mut market, constants::min_fee_incentive_sponsorship!() - 1);

    abort 999
}

#[test]
fun live_rebalance_allocates_fee_incentives_without_cash_top_up() {
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.sponsor_fee_incentives_bundle(&mut market, SPONSOR_AMOUNT);

    fx.rebalance_expiry_cash_bundle(&mut market);

    assert_eq!(helpers::vault(&market).fee_incentive_reserve(), 0);
    assert_eq!(helpers::vault(&market).idle_balance(), 0);
    assert_eq!(helpers::market(&market).fee_incentive_balance(), SPONSOR_AMOUNT);
    assert_eq!(helpers::market(&market).cash_balance(), 0);
    helpers::return_market_bundle(market);
    fx.finish();
}
