// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pricer binding coverage for expiry-market public live flows.
#[test_only]
module deepbook_predict::expiry_market_pricer_tests;

use deepbook_predict::{expiry_market, oracle_fixture, pricing, test_constants};

#[test, expected_failure(abort_code = expiry_market::EWrongPricer)]
fun current_nav_rejects_pricer_loaded_for_another_market() {
    let mut fx = oracle_fixture::setup_oracle_default();

    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_live_oracle_bundle(&mut oracle, test_constants::default_live_price());
    let wrong_pricer = pricing::load_live_pricer(
        oracle_fixture::config(&oracle).pricing_config(),
        oracle_fixture::oracle_registry(&oracle),
        oracle_fixture::pyth(&oracle).id(),
        test_constants::propbook_underlying_id(),
        oracle_fixture::pyth(&oracle),
        oracle_fixture::bs(&oracle).spot(),
        oracle_fixture::bs(&oracle).forward(),
        oracle_fixture::bs(&oracle).svi(),
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
        oracle_fixture::pyth(&oracle).id(),
        test_constants::propbook_underlying_id(),
        oracle_fixture::pyth(&oracle),
        oracle_fixture::bs(&oracle).spot(),
        oracle_fixture::bs(&oracle).forward(),
        oracle_fixture::bs(&oracle).svi(),
        fx.expiry(),
        fx.clock(),
    );

    let mut market = fx.take_expiry_market();
    market.liquidate(oracle_fixture::config(&oracle), &wrong_pricer, 1);
    abort 999
}
