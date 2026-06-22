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
    let (pyth, bs, oracle_registry, vault, mut market, config) = fx.take_market(expiry_id);
    let mut wrapper = fx.take_account(&trader);
    let root = fx.take_root();

    // Fully-known pre-trade state sheet: only the deposit has moved.
    fx.check_manager(
        &wrapper,
        &root,
        expiry_id,
        helpers::expected_manager_state(test_constants::default_manager_deposit(), 0, 0, 0, 0),
    );
    let order_id = fx.mint(
        &config,
        &oracle_registry,
        &mut wrapper,
        &root,
        &mut market,
        &pyth,
        &bs,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );

    assert!(helpers::has_position(&wrapper, expiry_id, order_id));
    assert_eq!(helpers::position_count(&wrapper, expiry_id), 1);
    // A mint charges a non-zero fee and a non-zero net_premium, so the free balance
    // strictly decreases.
    assert!(helpers::fees_paid(&wrapper, expiry_id) > 0);
    assert!(fx.account_balance<DUSDC>(&wrapper, &root) < test_constants::default_manager_deposit());

    helpers::return_account(wrapper, root);

    helpers::return_market(pyth, bs, oracle_registry, vault, market, config);
    fx.finish();
}

#[test]
fun oracle_fixture_brings_up_priceable_oracle_smoke() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let (mut pyth, mut bs, oracle_registry, config) = fx.take_oracle();

    fx.prepare_live_oracle(&mut bs, &mut pyth, test_constants::default_live_price());

    // The unfunded oracle bring-up produces a working quote surface: the
    // probability of the full upper range [min_finite_strike, +inf) is a valid
    // probability strictly inside (0, 1). (Independent bound: any probability is
    // in [0, FLOAT_SCALING]; a non-degenerate range is strictly inside.)
    let pricer = fx.load_pricer(&config, &oracle_registry, &pyth, &bs);
    let up = pricer.range_price(
        test_constants::min_finite_strike(),
        constants::pos_inf!(),
    );
    assert!(up > 0);
    assert!(up < test_constants::float());

    oracle_fixture::return_oracle(pyth, bs, oracle_registry, config);
    fx.finish();
}
