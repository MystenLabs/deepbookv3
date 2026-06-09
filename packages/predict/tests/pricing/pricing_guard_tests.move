// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// One `expected_failure` test per `pricing.move` error constant.
///
/// The `build_curve` guards (`EZeroForward`, `ECannotBeNegative`,
/// `EZeroVariance`, `EInvalidCurveRange`, `EInvalidStrikeRatio`) are exercised
/// as direct `public(package)` unit calls with named adversarial inputs:
/// `build_curve` is the intended unit surface and performs no SVI validation of
/// its own (its production caller in `strike_exposure` feeds oracle-validated
/// SVI). The live freshness/range guards (`EInvalidRange`,
/// `EBlockScholesPriceStale`, `EBlockScholesSVIStale`, `EPythSpotStale`) are
/// driven through the production-valid `oracle_fixture` live-oracle bring-up.
#[test_only]
module deepbook_predict::pricing_guard_tests;

use deepbook_predict::{
    constants,
    market_oracle::{Self, MarketOracle, SVIParams},
    oracle_fixture::{Self, OracleFixture},
    pricing,
    protocol_config::ProtocolConfig,
    pyth_source::PythSource,
    test_constants
};
use predict_math::{i64, math::float_scaling as float};

const EUnexpectedSuccess: u64 = 999;

// === build_curve unit guards ===

#[test, expected_failure(abort_code = pricing::EZeroForward)]
fun build_curve_with_zero_forward_aborts() {
    let svi = default_svi();
    let strike = 2 * float!();
    // forward = 0 trips compute_nd2's first guard, before the strike/forward
    // division could divide by zero.
    pricing::build_curve(&svi, 0, test_constants::default_tick_size(), strike, strike);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::ECannotBeNegative)]
fun build_curve_with_degenerate_sigma_negative_inner_term_aborts() {
    // Within production SVI bounds (sigma >= svi_sigma_min, |rho| <= 1.0) the
    // inner term rho*(k - m) + sqrt((k - m)^2 + sigma^2) is non-negative even
    // under floor rounding: sigma^2 contributes >= 1_000 scaled units to the
    // sqrt argument, always outweighing the < 1e9 flooring loss of
    // square_scaled, so sqrt >= |k - m| >= |rho*(k - m)|. The guard is therefore
    // only reachable with a degenerate sigma; sigma = 0 (below svi_sigma_min) is
    // the named adversarial input. With sigma = 0 the sqrt term collapses to
    // floor(sqrt(K^2 - (K^2 mod 1e9))) <= K - 1 whenever K^2 mod 1e9 != 0, while
    // rho = -1.0 (the validation boundary) gives rho*(k - m) = -K exactly, so
    // inner <= -1 < 0. Here strike/forward = 2.0 and m = 0, so
    // K = ln(2) * 1e9 ~= 693_147_18x — not a multiple of 100_000 (the divisor
    // condition for K^2 ≡ 0 mod 1e9), hence K^2 mod 1e9 != 0.
    let svi = market_oracle::new_svi_params(
        test_constants::default_svi_a(),
        test_constants::default_svi_b(),
        i64::from_parts(float!(), true), // rho = -1.0
        i64::zero(), // m = 0, so k - m = ln(2)
        0, // sigma = 0: degenerate, below svi_sigma_min
    );
    let forward = float!();
    let strike = 2 * float!();
    pricing::build_curve(&svi, forward, test_constants::default_tick_size(), strike, strike);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EZeroVariance)]
fun build_curve_with_zero_total_variance_aborts() {
    // a = 0 and b = 0 zero out the total variance w(k) = a + b * inner.
    // rho/m/sigma stay production-valid so the negative-inner guard passes
    // first. Note `market_oracle::assert_valid_svi` does not bound a or b, so a
    // zero-variance SVI is also acceptable on the production update path.
    let svi = market_oracle::new_svi_params(
        0, // a = 0
        0, // b = 0
        i64::zero(),
        i64::zero(),
        constants::svi_sigma_min!(),
    );
    let forward = float!();
    let strike = 2 * float!();
    pricing::build_curve(&svi, forward, test_constants::default_tick_size(), strike, strike);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EInvalidCurveRange)]
fun build_curve_with_zero_tick_size_aborts() {
    let svi = default_svi();
    let strike = 2 * float!();
    // tick_size = 0 trips assert_curve_inputs before any pricing runs.
    pricing::build_curve(&svi, float!(), 0, strike, strike);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EInvalidStrikeRatio)]
fun build_curve_with_sub_resolution_strike_ratio_aborts() {
    let svi = default_svi();
    // strike = 0 never reaches this guard (it is the neg_inf sentinel,
    // special-cased to price 1.0). Strike 1 is finite (neither neg_inf = 0 nor
    // pos_inf = u64::MAX) but floors to a zero ratio:
    // div(1, default_live_price) = 1 * 1e9 / 100e9 = 0.
    let sub_resolution_strike = 1;
    pricing::build_curve(
        &svi,
        test_constants::default_live_price(),
        test_constants::default_tick_size(),
        sub_resolution_strike,
        sub_resolution_strike,
    );
    abort EUnexpectedSuccess
}

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
        &config,
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

/// Production-valid SVI mirroring `oracle_fixture::prepare_live_oracle`, for
/// curve guards that abort before the SVI is used.
fun default_svi(): SVIParams {
    market_oracle::new_svi_params(
        test_constants::default_svi_a(),
        test_constants::default_svi_b(),
        i64::from_u64(test_constants::default_svi_rho_magnitude()),
        i64::from_u64(test_constants::default_svi_m()),
        constants::svi_sigma_min!(),
    )
}

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
    pricing::live_range_probability(
        config.pricing_config(),
        oracle,
        pyth,
        lower,
        higher,
        fx.clock(),
    )
}
