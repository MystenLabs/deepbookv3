// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pricer binding coverage for expiry-market public live flows.
#[test_only]
module deepbook_predict::expiry_market_pricer_tests;

use deepbook_predict::{
    expiry_market::{Self, ExpiryMarket},
    oracle_fixture,
    pricing,
    test_constants
};

#[test, expected_failure(abort_code = expiry_market::EWrongPricer)]
fun current_nav_rejects_pricer_loaded_for_another_market() {
    let mut fx = oracle_fixture::setup_oracle_default();

    let (mut pyth, mut bs, oracle_registry, config) = fx.take_oracle();
    fx.prepare_live_oracle(
        &mut bs,
        &mut pyth,
        test_constants::default_live_price(),
    );
    let wrong_pricer = pricing::load_live_pricer(
        config.pricing_config(),
        &oracle_registry,
        pyth.id(),
        test_constants::propbook_underlying_id(),
        &pyth,
        bs.spot(),
        bs.forward(),
        bs.svi(),
        fx.expiry(),
        fx.clock(),
    );

    let expiry_id = fx.expiry_id();
    let market = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(expiry_id);
    market.current_nav(&wrong_pricer);
    abort 999
}

#[test, expected_failure(abort_code = expiry_market::EWrongPricer)]
fun liquidate_rejects_pricer_loaded_for_another_market() {
    let mut fx = oracle_fixture::setup_oracle_default();

    let (mut pyth, mut bs, oracle_registry, config) = fx.take_oracle();
    fx.prepare_live_oracle(
        &mut bs,
        &mut pyth,
        test_constants::default_live_price(),
    );
    let wrong_pricer = pricing::load_live_pricer(
        config.pricing_config(),
        &oracle_registry,
        pyth.id(),
        test_constants::propbook_underlying_id(),
        &pyth,
        bs.spot(),
        bs.forward(),
        bs.svi(),
        fx.expiry(),
        fx.clock(),
    );

    let expiry_id = fx.expiry_id();
    let mut market = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(expiry_id);
    market.liquidate(&config, &wrong_pricer, 1);
    abort 999
}
