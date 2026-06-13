// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// One `expected_failure` test per `pricing.move` error constant.
///
/// The live freshness/range guards (`EInvalidRange`,
/// `EBlockScholesPriceStale`, `EBlockScholesSVIStale`, `EPythSpotStale`) are
/// driven through the production-valid `oracle_fixture` live-oracle bring-up.
#[test_only]
module deepbook_predict::pricing_guard_tests;

use deepbook_predict::{
    constants,
    market_oracle::MarketOracle,
    oracle_fixture::{Self, OracleFixture},
    pricing,
    protocol_config::ProtocolConfig,
    pyth_source::PythSource,
    test_constants
};

const EUnexpectedSuccess: u64 = 999;

// === Live oracle guards (production-valid fixture bring-up) ===

#[test, expected_failure(abort_code = pricing::EInvalidRange)]
fun live_quote_with_equal_range_bounds_aborts() {
    let (fx, pyth, oracle, config) = setup_live();
    // lower must be strictly below higher; the empty (degenerate) range aborts
    // after the freshness gates pass.
    live_quote(
        &fx,
        &pyth,
        &oracle,
        &config,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesPriceStale)]
fun live_quote_with_stale_block_scholes_prices_aborts() {
    let (mut fx, pyth, oracle, config) = setup_live();
    // The conservative price freshness timestamp is min(source, update) =
    // live_source_timestamp_ms; one ms past the configured window the quote is
    // stale. The SVI window is much longer, so the price guard fires first.
    let stale_now =
        test_constants::live_source_timestamp_ms()
        + config.pricing_config().block_scholes_prices_freshness_ms()
        + 1;
    fx.set_clock_for_testing(stale_now);
    live_quote(
        &fx,
        &pyth,
        &oracle,
        &config,
        test_constants::default_live_price(),
        constants::pos_inf!(),
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesSVIStale)]
fun live_quote_with_fresh_prices_but_stale_svi_aborts() {
    let (mut fx, pyth, mut oracle, config) = setup_live();
    // Price staleness is checked before SVI staleness, so advance past the
    // (longer) SVI window and re-push only prices at the new clock:
    // update_block_scholes_prices leaves the SVI timestamps untouched, isolating
    // the SVI guard.
    let svi_stale_now =
        test_constants::live_source_timestamp_ms()
        + config.pricing_config().block_scholes_svi_freshness_ms()
        + 1;
    fx.set_clock_for_testing(svi_stale_now);
    oracle.update_block_scholes_prices(
        fx.cap(),
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        svi_stale_now,
        fx.clock(),
    );
    live_quote(
        &fx,
        &pyth,
        &oracle,
        &config,
        test_constants::default_live_price(),
        constants::pos_inf!(),
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EPythSpotStale)]
fun assert_pyth_spot_fresh_with_stale_source_aborts() {
    // Live quotes never abort on a stale Pyth source (they fall back to the
    // Block Scholes forward); the abort surface for EPythSpotStale is
    // `assert_pyth_spot_fresh`, which registry/incentive flows call directly.
    let (fx, mut pyth, _oracle, config) = setup_live();
    // Freshness uses min(source, update); push a source timestamp one ms past
    // the Pyth window while the on-chain update stamp stays current.
    let stale_source_ts =
        test_constants::now_ms() - config.pricing_config().pyth_spot_freshness_ms() - 1;
    fx.set_pyth(&mut pyth, test_constants::default_live_price(), stale_source_ts);
    pricing::assert_pyth_spot_fresh(config.pricing_config(), &pyth, fx.clock());
    abort EUnexpectedSuccess
}

// === Helpers ===

/// Bring up the default live oracle: fresh Pyth spot + Block Scholes prices +
/// SVI, all quotable at the fixture clock.
fun setup_live(): (OracleFixture, PythSource, MarketOracle, ProtocolConfig) {
    let mut fx = oracle_fixture::setup_oracle_default();
    let (mut pyth, mut oracle, config) = fx.take_oracle();
    fx.prepare_live_oracle(&config, &mut oracle, &mut pyth, test_constants::default_live_price());
    (fx, pyth, oracle, config)
}

/// Worker: one live quote over `(lower, higher]` against the fixture market.
fun live_quote(
    fx: &OracleFixture,
    pyth: &PythSource,
    oracle: &MarketOracle,
    config: &ProtocolConfig,
    lower: u64,
    higher: u64,
): u64 {
    let pricer = pricing::pricer(config.pricing_config(), oracle, pyth, fx.clock());
    pricer.range_price(lower, higher)
}
