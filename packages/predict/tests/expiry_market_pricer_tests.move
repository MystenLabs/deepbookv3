// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pricer binding coverage for expiry-market public live flows.
#[test_only]
module deepbook_predict::expiry_market_pricer_tests;

use deepbook_predict::{expiry_market, oracle_fixture, pricing, test_constants};
use std::unit_test::assert_eq;

const REBOUND_SOURCE_ID: u32 = 2;

#[test, expected_failure(abort_code = expiry_market::EWrongPricer)]
fun current_nav_rejects_pricer_loaded_for_another_market() {
    let mut fx = oracle_fixture::setup_oracle_default();

    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_live_oracle_bundle(&mut oracle, test_constants::default_live_price());
    // Bind the pricer to the Pyth feed id (not this market) so current_nav rejects it.
    let wrong_pricer = fx.load_pricer_bound_to(
        oracle_fixture::config(&oracle),
        oracle_fixture::oracle_registry(&oracle),
        oracle_fixture::pyth(&oracle),
        oracle_fixture::bs(&oracle).values(),
        oracle_fixture::bs(&oracle).svi(),
        oracle_fixture::pyth(&oracle).id(),
    );

    let market = fx.take_expiry_market();
    market.current_nav(&wrong_pricer);
    abort 999
}

#[test, expected_failure(abort_code = expiry_market::EWrongPricer)]
fun liquidate_rejects_pricer_loaded_for_another_market() {
    let mut fx = oracle_fixture::setup_oracle_default();

    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_live_oracle_bundle(&mut oracle, test_constants::default_live_price());
    let wrong_pricer = fx.load_pricer_bound_to(
        oracle_fixture::config(&oracle),
        oracle_fixture::oracle_registry(&oracle),
        oracle_fixture::pyth(&oracle),
        oracle_fixture::bs(&oracle).values(),
        oracle_fixture::bs(&oracle).svi(),
        oracle_fixture::pyth(&oracle).id(),
    );

    let mut market = fx.take_expiry_market();
    market.liquidate(oracle_fixture::config(&oracle), &wrong_pricer, 1, fx.clock());
    abort 999
}

#[test, expected_failure(abort_code = pricing::EWrongPythFeed)]
fun load_live_pricer_rejects_old_feeds_after_propbook_rebind() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let _rebound_ids = fx.create_and_rebind_oracle(REBOUND_SOURCE_ID);
    let oracle = fx.take_oracle_bundle();

    fx.load_pricer_bundle(&oracle);
    abort 999
}

#[test]
fun load_live_pricer_uses_rebound_feeds_for_existing_market() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let rebound_ids = fx.create_and_rebind_oracle(REBOUND_SOURCE_ID);
    let mut oracle = fx.take_oracle_bundle_by_ids(rebound_ids);

    fx.prepare_live_oracle_bundle(&mut oracle, test_constants::default_live_price());
    let pricer = fx.load_pricer_bundle(&oracle);

    assert_eq!(pricer.expiry_market_id(), fx.expiry_id());
    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}
