// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pricer binding coverage for expiry-market public live flows.
#[test_only]
module deepbook_predict::expiry_market_pricer_tests;

use deepbook_predict::{expiry_market, oracle_fixture, pricing, test_constants};
use propbook::block_scholes_store as bs_store;
use std::unit_test::assert_eq;

const REBOUND_SOURCE_ID: u32 = 2;
/// One millisecond after the fixture's live seed timestamp, still before `now_ms`.
const REBOUND_SETTER_SOURCE_TIMESTAMP_MS: u64 = 119_001;

#[test, expected_failure(abort_code = expiry_market::EWrongPricer)]
fun current_nav_rejects_pricer_loaded_for_another_market() {
    let mut fx = oracle_fixture::setup_oracle_default();

    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_live_oracle_bundle(&mut oracle, test_constants::default_live_price());
    let wrong_pricer = pricing::load_live_pricer(
        oracle_fixture::config(&oracle).pricing_config(),
        oracle_fixture::oracle_registry(&oracle),
        oracle_fixture::pyth(&oracle),
        oracle_fixture::bs(&oracle).values(),
        oracle_fixture::bs(&oracle).svi(),
        oracle_fixture::pyth(&oracle).id(),
        test_constants::propbook_underlying_id(),
        fx.expiry(),
        fx.clock(),
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
    let wrong_pricer = pricing::load_live_pricer(
        oracle_fixture::config(&oracle).pricing_config(),
        oracle_fixture::oracle_registry(&oracle),
        oracle_fixture::pyth(&oracle),
        oracle_fixture::bs(&oracle).values(),
        oracle_fixture::bs(&oracle).svi(),
        oracle_fixture::pyth(&oracle).id(),
        test_constants::propbook_underlying_id(),
        fx.expiry(),
        fx.clock(),
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

/// A Pyth rebind leaves the Block Scholes stores alone — a pair is canonical for its underlying for
/// life — so the bundle's setters keep landing in the same stores and the values read straight back.
#[test]
fun rebound_bundle_bs_setters_still_land_in_the_underlyings_stores() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let rebound_ids = fx.create_and_rebind_oracle(REBOUND_SOURCE_ID);
    let mut oracle = fx.take_oracle_bundle_by_ids(rebound_ids);

    fx.prepare_live_oracle_bundle(&mut oracle, test_constants::default_live_price());
    fx.set_bs_spot_for_testing_bundle(
        &mut oracle,
        REBOUND_SETTER_SOURCE_TIMESTAMP_MS,
        test_constants::default_live_price(),
    );
    fx.set_bs_forward_for_testing_bundle(
        &mut oracle,
        REBOUND_SETTER_SOURCE_TIMESTAMP_MS,
        test_constants::default_live_price(),
    );

    let spot = bs_store::spot(oracle_fixture::bs(&oracle).values()).destroy_some();
    assert_eq!(spot.read_value(), test_constants::default_live_price() as u128);
    assert_eq!(spot.read_published_at_ms(), REBOUND_SETTER_SOURCE_TIMESTAMP_MS);

    let forward = bs_store::forward(
        oracle_fixture::bs(&oracle).values(),
        fx.expiry(),
    ).destroy_some();
    assert_eq!(forward.read_value(), test_constants::default_live_price() as u128);
    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}
