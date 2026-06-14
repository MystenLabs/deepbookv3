// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pricing for Predict markets.
///
/// This module is the app-facing read layer for oracle data. It reads the
/// standalone propbook Pyth and Block Scholes feeds on demand and computes SVI
/// range prices. It does not mutate feed, pool, expiry, or position state, and it
/// does not own feed binding or market liveness — `expiry_market` validates the
/// passed feeds belong to the market and that the market is active before pricing.
module deepbook_predict::pricing;

use deepbook_predict::{constants, pricing_config::PricingConfig};
use fixed_math::{i64, math};
use propbook::{block_scholes_feed::{BlockScholesFeed, SVIParams}, pyth_feed::PythFeed};
use sui::clock::Clock;

/// Value snapshot of live oracle inputs for one or more price calculations.
public struct Pricer has copy, drop {
    forward: u64,
    svi: SVIParams,
}

const EZeroForward: u64 = 0;
const ECannotBeNegative: u64 = 1;
const EZeroVariance: u64 = 2;
const EInvalidRange: u64 = 3;
const EBlockScholesSurfaceStale: u64 = 5;
const EInvalidStrikeRatio: u64 = 7;
const EPythSpotStale: u64 = 8;

// === Public-Package Functions ===

/// Snapshot the current live oracle inputs for `expiry`'s repeated quote
/// calculations. Reads the Pyth spot feed and the Block Scholes surface for this
/// expiry; the caller owns feed binding and market liveness.
public(package) fun pricer(
    config: &PricingConfig,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
    expiry: u64,
    clock: &Clock,
): Pricer {
    let (forward, svi) = live_inputs(config, pyth, bs, expiry, clock);
    Pricer { forward, svi }
}

/// Return the current UP tail price for one strike.
public(package) fun up_price(pricer: &Pricer, strike: u64): u64 {
    compute_up_price(&pricer.svi, pricer.forward, strike)
}

/// Return the current raw probability for a live range.
public(package) fun range_price(pricer: &Pricer, lower: u64, higher: u64): u64 {
    compute_range_price(&pricer.svi, pricer.forward, lower, higher)
}

/// Abort unless the Pyth spot source is fresh.
public(package) fun assert_pyth_spot_fresh(config: &PricingConfig, pyth: &PythFeed, clock: &Clock) {
    assert!(pyth_spot_is_fresh(config, pyth, clock), EPythSpotStale);
}

// === Private Functions ===

/// Resolve the live forward/SVI tuple used by all live pricing paths.
///
/// Fresh Pyth spot is canonical for spot; forward is then derived from this
/// expiry's Block Scholes basis. If Pyth is stale, pricing falls back to the
/// Block Scholes forward. The Block Scholes surface (basis + forward + SVI) must
/// be fresh either way.
fun live_inputs(
    config: &PricingConfig,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
    expiry: u64,
    clock: &Clock,
): (u64, SVIParams) {
    assert!(block_scholes_surface_is_fresh(config, bs, expiry, clock), EBlockScholesSurfaceStale);

    let forward = if (pyth_spot_is_fresh(config, pyth, clock)) {
        math::mul(pyth.spot(), bs.basis(expiry))
    } else {
        bs.forward(expiry)
    };

    (forward, bs.svi(expiry))
}

/// A surface is usable only if a row exists for `expiry` and it is fresh; the
/// presence check short-circuits so the freshness read never aborts on a missing
/// row (a missing surface is treated as stale, not a hard error).
fun block_scholes_surface_is_fresh(
    config: &PricingConfig,
    bs: &BlockScholesFeed,
    expiry: u64,
    clock: &Clock,
): bool {
    bs.has_expiry(expiry) &&
        timestamp_is_fresh(
            bs.surface_freshness_timestamp_ms(expiry),
            config.block_scholes_surface_freshness_ms(),
            clock,
        )
}

fun pyth_spot_is_fresh(config: &PricingConfig, pyth: &PythFeed, clock: &Clock): bool {
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
    // A thin / far-OTM range has ~0 true probability; a fixed-point 1-ulp
    // inversion should price 0, not abort a legitimate mint/redeem.
    lower_up_price.saturating_sub(higher_up_price)
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
