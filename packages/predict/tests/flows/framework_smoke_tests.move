// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Smoke tests for the reusable test-framework scaffolding: `setup_everything`,
/// `check_manager` (ExpectedManagerState), `return_market`, and the minimal
/// `oracle_fixture`. These validate the plumbing, not protocol economics.
#[test_only]
module deepbook_predict::framework_smoke_tests;

use deepbook_predict::{
    constants,
    flow_test_helpers as helpers,
    oracle_fixture,
    pricing,
    test_constants
};
use dusdc::dusdc::DUSDC;
use std::unit_test::assert_eq;

#[test]
fun setup_everything_check_manager_return_market_smoke() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();

    // Mint one 1x in-range order through the fixture; the account owner (alice) is
    // the current sender after `create_funded_manager`, but `setup_everything`
    // left the sender at admin — re-establish alice for the owner auth.
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // Fully-known pre-trade state sheet: only the deposit has moved.
    fx.check_manager_bundle(
        &account,
        expiry_id,
        helpers::expected_manager_state(test_constants::default_manager_deposit(), 0, 0, 0, 0),
    );
    let order_id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );

    assert!(helpers::has_position_bundle(&account, expiry_id, order_id));
    assert_eq!(helpers::position_count_bundle(&account, expiry_id), 1);
    // A mint charges a non-zero fee and a non-zero net_premium, so the free balance
    // strictly decreases.
    assert!(helpers::fees_paid_bundle(&account, expiry_id) > 0);
    assert!(fx.account_balance_bundle<DUSDC>(&account) < test_constants::default_manager_deposit());

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun oracle_fixture_brings_up_priceable_oracle_smoke() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();

    fx.prepare_live_oracle_bundle(&mut oracle, test_constants::default_live_price());

    // The unfunded oracle bring-up produces a working quote surface: the
    // probability of the upper tick range `(default_strike_tick, +inf]` is a
    // valid probability strictly inside (0, 1). (Independent bound: any
    // probability is in [0, FLOAT_SCALING]; a non-degenerate range is strictly
    // inside.)
    let pricer = fx.load_pricer_bundle(&oracle);
    let up = pricer.range_price(
        test_constants::default_strike_tick() * test_constants::default_tick_size(),
        constants::pos_inf!(),
    );
    assert!(up > 0);
    assert!(up < test_constants::float());

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}
