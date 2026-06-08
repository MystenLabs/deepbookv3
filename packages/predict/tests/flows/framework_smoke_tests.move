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
use std::unit_test::{assert_eq, destroy};

const MINT_QUANTITY: u64 = 1_000_000_000;
/// 1x leverage in FLOAT_SCALING.
const LEVERAGE_ONE_X: u64 = 1_000_000_000;

#[test]
fun setup_everything_check_manager_return_market_smoke() {
    let (mut fx, expiry_id, oracle_id, mut manager) = helpers::setup_everything();

    // Fully-known pre-trade state sheet: only the deposit has moved.
    helpers::check_manager(
        &manager,
        expiry_id,
        helpers::expected_manager_state(test_constants::default_manager_deposit(), 0, 0, 0, 0),
    );

    // Mint one 1x in-range order through the fixture; the manager owner (alice) is
    // the current sender after `create_funded_manager`, but `setup_everything`
    // left the sender at admin — re-establish alice for the owner proof.
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, vault, mut market, oracle, config) = fx.take_market(expiry_id, oracle_id);
    let order_id = fx.mint(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
        MINT_QUANTITY,
        LEVERAGE_ONE_X,
    );

    assert!(manager.has_position(expiry_id, order_id));
    assert_eq!(manager.expiry_position_count(expiry_id), 1);
    // A mint charges a non-zero fee and a non-zero principal, so the free balance
    // strictly decreases.
    assert!(manager.trading_fees_paid(expiry_id) > 0);
    assert!(manager.balance() < test_constants::default_manager_deposit());

    helpers::return_market(pyth, vault, market, oracle, config);
    destroy(manager);
    fx.finish();
}

#[test]
fun oracle_fixture_brings_up_priceable_oracle_smoke() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let (mut pyth, mut oracle, config) = fx.take_oracle();

    fx.prepare_live_oracle(&config, &mut oracle, &mut pyth, test_constants::default_live_price());

    // The unfunded oracle bring-up produces a working quote surface: the
    // probability of the full upper range [min_strike, +inf) is a valid
    // probability strictly inside (0, 1). (Independent bound: any probability is
    // in [0, FLOAT_SCALING]; a non-degenerate range is strictly inside.)
    let up = pricing::live_range_probability(
        config.pricing_config(),
        &oracle,
        &pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
        fx.clock(),
    );
    assert!(up > 0);
    assert!(up < test_constants::float());

    oracle_fixture::return_oracle(pyth, oracle, config);
    fx.finish();
}
