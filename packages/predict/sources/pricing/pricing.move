// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pricing, fees, and valuation curves for Predict markets.
///
/// This module is the app-facing read layer for oracle data. It resolves
/// market oracle and Pyth source state on demand, computes SVI prices, applies
/// fees, and builds aggregate valuation curves. It does not mutate oracle, pool,
/// expiry, or position state.
module deepbook_predict::pricing;

use deepbook::math;
use deepbook_predict::{
    constants,
    i64,
    market_oracle::{MarketOracle, SVIParams},
    math as predict_math,
    pricing_config::PricingConfig,
    pyth_source::PythSource
};
use sui::clock::Clock;

const EAskPriceOutOfBounds: u64 = 0;
const EZeroForward: u64 = 1;
const ECannotBeNegative: u64 = 2;
const EZeroVariance: u64 = 3;
const EInvalidRange: u64 = 4;
const ERangePriceUnderflow: u64 = 5;
const EInvalidLiveFairPrice: u64 = 6;
const EInvalidCurveRange: u64 = 7;
const EBlockScholesPriceStale: u64 = 8;
const EBlockScholesSVIStale: u64 = 9;
const EInvalidStrikeRatio: u64 = 10;
const EPythSpotStale: u64 = 11;

/// Curve sample point with strike and one-sided UP price.
public struct CurvePoint has copy, drop, store {
    strike: u64,
    up_price: u64,
}

// === Public Functions ===

/// Return terminal settlement price, aborting if the market is unsettled.
public fun settlement_price(market: &MarketOracle): u64 {
    market.settlement_price()
}

// === Public-Package Functions ===

public(package) fun strike(point: &CurvePoint): u64 {
    point.strike
}

public(package) fun up_price(point: &CurvePoint): u64 {
    point.up_price
}

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

/// Return the per-unit fee for a raw contract probability, scaled by the
/// per-asset time-to-expiry ramp. Callers must have already established that
/// the market is active (`now < expiry`).
public(package) fun fee_rate(
    config: &PricingConfig,
    market: &MarketOracle,
    expiry_fee_window_ms: u64,
    expiry_fee_max_multiplier: u64,
    probability: u64,
    clock: &Clock,
): u64 {
    let raw_fee = raw_bernoulli_fee_rate(config, probability);
    let min_fee = config.min_fee();
    let base = if (raw_fee > min_fee) raw_fee else min_fee;
    let time_to_expiry_ms = market.expiry() - clock.timestamp_ms();
    let multiplier = expiry_fee_multiplier(
        expiry_fee_window_ms,
        expiry_fee_max_multiplier,
        time_to_expiry_ms,
    );
    math::mul(base, multiplier)
}

/// Return fee rate and abort unless the all-in mint price is allowed.
public(package) fun assert_mint_fee_rate(
    config: &PricingConfig,
    market: &MarketOracle,
    expiry_fee_window_ms: u64,
    expiry_fee_max_multiplier: u64,
    probability: u64,
    clock: &Clock,
): u64 {
    let fee_rate = fee_rate(
        config,
        market,
        expiry_fee_window_ms,
        expiry_fee_max_multiplier,
        probability,
        clock,
    );
    let ask_price = probability + fee_rate;
    assert!(
        ask_price >= config.min_ask_price() && ask_price <= config.max_ask_price(),
        EAskPriceOutOfBounds,
    );
    fee_rate
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

/// Build an adaptive piecewise-linear UP-price curve over a configured grid range.
public(package) fun build_curve(
    svi: &SVIParams,
    forward: u64,
    grid_min: u64,
    grid_tick: u64,
    grid_max: u64,
    min_strike: u64,
    max_strike: u64,
): vector<CurvePoint> {
    assert_curve_range(grid_min, grid_tick, grid_max, min_strike, max_strike);

    if (min_strike == max_strike) {
        let price = compute_up_price(svi, forward, min_strike);
        return vector[
            CurvePoint {
                strike: min_strike,
                up_price: price,
            },
        ]
    };

    let price_lo = compute_up_price(svi, forward, min_strike);
    let price_hi = compute_up_price(svi, forward, max_strike);
    let mut points = vector[
        CurvePoint {
            strike: min_strike,
            up_price: price_lo,
        },
        CurvePoint {
            strike: max_strike,
            up_price: price_hi,
        },
    ];

    let curve_samples = constants::curve_samples!();
    let mut cur_samples = 2;
    while (cur_samples < curve_samples) {
        let (found, idx) = find_gap(&points, grid_tick);
        if (!found) break;

        let strike_lo = points[idx].strike;
        let strike_hi = points[idx + 1].strike;
        let mid_strike = snap_to_tick((strike_lo + strike_hi) / 2, grid_min, grid_tick);
        let price = compute_up_price(svi, forward, mid_strike);
        insert_asc(
            &mut points,
            CurvePoint {
                strike: mid_strike,
                up_price: price,
            },
        );
        cur_samples = cur_samples + 1;
    };

    points
}

/// Compute the fair price for the range `(lower, higher]`.
public(package) fun compute_range_price(
    svi: &SVIParams,
    forward: u64,
    lower: u64,
    higher: u64,
): u64 {
    assert!(lower < higher, EInvalidRange);

    let lower_up_price = compute_up_price(svi, forward, lower);
    let higher_up_price = compute_up_price(svi, forward, higher);
    assert!(lower_up_price >= higher_up_price, ERangePriceUnderflow);

    lower_up_price - higher_up_price
}

// === Private Functions ===

fun assert_live_oracle_fresh(config: &PricingConfig, market: &MarketOracle, clock: &Clock) {
    assert!(block_scholes_price_is_fresh(config, market, clock), EBlockScholesPriceStale);
    assert!(block_scholes_svi_is_fresh(config, market, clock), EBlockScholesSVIStale);
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

/// Compute the fair UP tail price for `strike`.
fun compute_up_price(svi: &SVIParams, forward: u64, strike: u64): u64 {
    if (strike == constants::neg_inf!()) {
        return constants::float_scaling!()
    };
    if (strike == constants::pos_inf!()) {
        return 0
    };

    compute_nd2(svi, forward, strike)
}

fun raw_bernoulli_fee_rate(config: &PricingConfig, probability: u64): u64 {
    assert!(probability <= constants::float_scaling!(), EInvalidLiveFairPrice);
    if (probability == 0 || probability == constants::float_scaling!()) return 0;

    let complement = constants::float_scaling!() - probability;
    let variance = math::mul(probability, complement);
    let bernoulli_factor = predict_math::sqrt(variance, constants::float_scaling!());
    math::mul(config.base_fee(), bernoulli_factor)
}

/// Linear ramp that scales the trade fee up as expiry approaches: 1x outside
/// `window_ms`, rising linearly to the per-asset `max_multiplier` at expiry.
/// `time_to_expiry_ms` is the live remaining time (caller guarantees `now < expiry`);
/// `max_multiplier == 1x` disables the ramp.
public(package) fun expiry_fee_multiplier(
    window_ms: u64,
    max_multiplier: u64,
    time_to_expiry_ms: u64,
): u64 {
    // Outside the window the fee is unscaled.
    if (time_to_expiry_ms >= window_ms) return constants::float_scaling!();

    // mult = 1 + (max - 1) * (window - ttx) / window
    let ramp = predict_math::mul_div_round_down(
        max_multiplier - constants::float_scaling!(),
        window_ms - time_to_expiry_ms,
        window_ms,
    );
    constants::float_scaling!() + ramp
}

/// Binary pricing from SVI total variance:
/// - k = ln(strike / forward)
/// - w(k) = a + b * (rho * (k - m) + sqrt((k - m)^2 + sigma^2))
/// - d2 = -((k + w(k) / 2) / sqrt(w(k)))
fun compute_nd2(svi_params: &SVIParams, forward: u64, strike: u64): u64 {
    assert!(forward > 0, EZeroForward);

    let strike_ratio = math::div(strike, forward);
    assert!(strike_ratio > 0, EInvalidStrikeRatio);
    let k = predict_math::ln(strike_ratio);
    let m = svi_params.m();
    let k_minus_m = k.sub(&m);
    let k_minus_m_squared = k_minus_m.square_scaled();
    let sigma = svi_params.sigma();
    let sigma_squared = math::mul(sigma, sigma);
    let sqrt_input = k_minus_m_squared + sigma_squared;
    let sq = predict_math::sqrt(sqrt_input, constants::float_scaling!());
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

    let sqrt_var = predict_math::sqrt(total_var, constants::float_scaling!());
    let sqrt_var_i64 = i64::from_u64(sqrt_var);
    let half_var_i64 = i64::from_u64(total_var / 2);
    let d2_numerator = k.add(&half_var_i64);
    let d2 = d2_numerator.div_scaled(&sqrt_var_i64);
    let d2 = d2.neg();

    predict_math::normal_cdf(&d2)
}

fun assert_curve_range(
    grid_min: u64,
    grid_tick: u64,
    grid_max: u64,
    min_strike: u64,
    max_strike: u64,
) {
    assert!(grid_tick > 0, EInvalidCurveRange);
    assert!(min_strike <= max_strike, EInvalidCurveRange);
    assert!(min_strike >= grid_min && min_strike <= grid_max, EInvalidCurveRange);
    assert!(max_strike >= grid_min && max_strike <= grid_max, EInvalidCurveRange);
    assert!((min_strike - grid_min) % grid_tick == 0, EInvalidCurveRange);
    assert!((max_strike - grid_min) % grid_tick == 0, EInvalidCurveRange);
}

/// Insert a new curve point while preserving ascending strike order.
fun insert_asc(points: &mut vector<CurvePoint>, new_point: CurvePoint) {
    points.push_back(new_point);
    let mut i = points.length() - 1;
    while (i > 0) {
        if (points[i - 1].strike <= points[i].strike) break;
        points.swap(i - 1, i);
        i = i - 1;
    };
}

/// Pick the next adjacent gap to bisect based on endpoint UP-price difference.
fun find_gap(points: &vector<CurvePoint>, grid_tick: u64): (bool, u64) {
    let len = points.length();
    let mut best_idx = len;
    let mut best_price_diff = 0;

    let mut i = 0;
    while (i + 1 < len) {
        let lo = &points[i];
        let hi = &points[i + 1];

        if (hi.strike - lo.strike <= grid_tick) {
            i = i + 1;
            continue
        };

        // `points` is strike-sorted, and UP price is monotone non-increasing in strike.
        assert!(lo.up_price >= hi.up_price, ERangePriceUnderflow);
        let price_diff = lo.up_price - hi.up_price;
        if (price_diff > best_price_diff) {
            best_idx = i;
            best_price_diff = price_diff;
        };

        i = i + 1;
    };

    (best_idx != len, best_idx)
}

/// Round a strike down to the nearest tick boundary.
fun snap_to_tick(strike: u64, grid_min: u64, grid_tick: u64): u64 {
    grid_min + (strike - grid_min) / grid_tick * grid_tick
}

// === Test-Only Functions ===

/// Construct a `CurvePoint` directly for tests that need to drive `live_value`
/// without a full pricing/oracle fixture. Production builds points only inside
/// `build_curve`, but downstream NAV math is independent of that builder.
#[test_only]
public fun new_curve_point_for_testing(strike: u64, up_price: u64): CurvePoint {
    CurvePoint { strike, up_price }
}
