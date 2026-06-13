// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pricing for Predict markets.
///
/// This module is the app-facing read layer for oracle data. It resolves
/// market oracle and Pyth source state on demand and computes SVI range
/// prices. It does not mutate oracle, pool, expiry, or position state.
module deepbook_predict::pricing;

use deepbook_predict::{
    constants,
    market_oracle::{MarketOracle, SVIParams},
    pricing_config::PricingConfig,
    pyth_source::PythSource
};
use predict_math::{i64, math};
use sui::clock::Clock;

const EZeroForward: u64 = 0;
const ECannotBeNegative: u64 = 1;
const EZeroVariance: u64 = 2;
const EInvalidRange: u64 = 3;
const EBlockScholesPriceStale: u64 = 5;
const EBlockScholesSVIStale: u64 = 6;
const EInvalidStrikeRatio: u64 = 7;
const EPythSpotStale: u64 = 8;

// === Public-Package Functions ===

/// Return the current raw probability for a live range.
public(package) fun live_range_probability(
    config: &PricingConfig,
    market: &MarketOracle,
    pyth: &PythSource,
    lower: u64,
    higher: u64,
    clock: &Clock,
): u64 {
    let (forward, svi) = live_inputs(config, market, pyth, clock);
    compute_range_price(&svi, forward, lower, higher)
}

/// Abort unless the live oracle inputs needed for a quote are currently usable.
public(package) fun assert_live_quote_available(
    config: &PricingConfig,
    market: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
) {
    market.assert_pyth_source(pyth);
    market.assert_active(clock);
    assert_live_oracle_fresh(config, market, clock);
}

public(package) fun assert_pyth_spot_fresh(
    config: &PricingConfig,
    pyth: &PythSource,
    clock: &Clock,
) {
    assert!(pyth_spot_is_fresh(config, pyth, clock), EPythSpotStale);
}

/// Resolve the live forward/SVI tuple used by all live pricing paths.
///
/// Fresh Pyth spot is canonical for spot; forward is then derived from the
/// latest Block Scholes basis. If Pyth is stale, pricing falls back to the
/// fresh Block Scholes forward. SVI must be fresh either way.
public(package) fun live_inputs(
    config: &PricingConfig,
    market: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
): (u64, SVIParams) {
    assert_live_quote_available(config, market, pyth, clock);

    let forward = if (pyth_spot_is_fresh(config, pyth, clock)) {
        math::mul(pyth.spot(), market.block_scholes_basis())
    } else {
        market.block_scholes_forward()
    };

    (forward, market.block_scholes_svi())
}

// === Private Functions ===

fun assert_live_oracle_fresh(config: &PricingConfig, market: &MarketOracle, clock: &Clock) {
    assert!(block_scholes_price_is_fresh(config, market, clock), EBlockScholesPriceStale);
    assert!(block_scholes_svi_is_fresh(config, market, clock), EBlockScholesSVIStale);
}

/// Return the raw range probability from two UP tail prices.
fun range_price(lower_up_price: u64, higher_up_price: u64): u64 {
    // A thin / far-OTM range has ~0 true probability; a fixed-point 1-ulp
    // inversion should price 0, not abort a legitimate mint/redeem/valuation.
    lower_up_price.saturating_sub(higher_up_price)
}

fun block_scholes_price_is_fresh(
    config: &PricingConfig,
    market: &MarketOracle,
    clock: &Clock,
): bool {
    timestamp_is_fresh(
        market.block_scholes_price_freshness_timestamp_ms(),
        config.block_scholes_prices_freshness_ms(),
        clock,
    )
}

fun block_scholes_svi_is_fresh(config: &PricingConfig, market: &MarketOracle, clock: &Clock): bool {
    timestamp_is_fresh(
        market.block_scholes_svi_freshness_timestamp_ms(),
        config.block_scholes_svi_freshness_ms(),
        clock,
    )
}

fun pyth_spot_is_fresh(config: &PricingConfig, pyth: &PythSource, clock: &Clock): bool {
    timestamp_is_fresh(pyth.freshness_timestamp_ms(), config.pyth_spot_freshness_ms(), clock)
}

fun timestamp_is_fresh(timestamp: u64, max_age_ms: u64, clock: &Clock): bool {
    let now = clock.timestamp_ms();
    timestamp > 0 && timestamp <= now && now - timestamp <= max_age_ms
}

/// Compute the fair price for the range `(lower, higher]`.
fun compute_range_price(svi: &SVIParams, forward: u64, lower: u64, higher: u64): u64 {
    assert!(lower < higher, EInvalidRange);

    let lower_up_price = compute_up_price(svi, forward, lower);
    let higher_up_price = compute_up_price(svi, forward, higher);
    range_price(lower_up_price, higher_up_price)
}

/// Compute the fair UP tail price for `strike`.
fun compute_up_price(svi: &SVIParams, forward: u64, strike: u64): u64 {
    if (strike == constants::neg_inf!()) {
        return math::float_scaling!()
    };
    if (strike == constants::pos_inf!()) {
        return 0
    };

    compute_nd2(svi, forward, strike)
}

/// Binary pricing from SVI total variance:
/// - k = ln(strike / forward)
/// - w(k) = a + b * (rho * (k - m) + sqrt((k - m)^2 + sigma^2))
/// - d2 = -((k + w(k) / 2) / sqrt(w(k)))
fun compute_nd2(svi_params: &SVIParams, forward: u64, strike: u64): u64 {
    assert!(forward > 0, EZeroForward);

    let strike_ratio = math::div(strike, forward);
    assert!(strike_ratio > 0, EInvalidStrikeRatio);
    let k = math::ln(strike_ratio);
    let m = svi_params.m();
    let k_minus_m = k.sub(&m);
    let k_minus_m_squared = k_minus_m.square_scaled();
    let sigma = svi_params.sigma();
    let sigma_squared = math::mul(sigma, sigma);
    let sqrt_input = k_minus_m_squared + sigma_squared;
    let sq = math::sqrt(sqrt_input, math::float_scaling!());
    let sq_i64 = i64::from_u64(sq);

    let rho = svi_params.rho();
    let rho_km = rho.mul_scaled(&k_minus_m);
    let inner = rho_km.add(&sq_i64);
    assert!(!inner.is_negative(), ECannotBeNegative);

    let a = svi_params.a();
    let b = svi_params.b();
    let wing_var = math::mul(b, inner.magnitude());
    let total_var = a + wing_var;
    assert!(total_var > 0, EZeroVariance);

    let sqrt_var = math::sqrt(total_var, math::float_scaling!());
    let sqrt_var_i64 = i64::from_u64(sqrt_var);
    let half_var_i64 = i64::from_u64(total_var / 2);
    let d2_numerator = k.add(&half_var_i64);
    let d2 = d2_numerator.div_scaled(&sqrt_var_i64);
    let d2 = d2.neg();

    math::normal_cdf(&d2)
}
