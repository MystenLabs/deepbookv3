// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pricing for Predict markets.
///
/// This module is the app-facing read layer for oracle data. It reads the
/// standalone propbook Pyth and Block Scholes feeds on demand and computes SVI
/// range prices. It does not mutate feed, pool, expiry, or position state, and it
/// owns the live pricing boundary: current Propbook feed binding, pre-expiry
/// market liveness, feed freshness, and Predict's pricing-safe surface envelope.
module deepbook_predict::pricing;

use deepbook_predict::{constants, pricing_config::PricingConfig};
use fixed_math::{i64, math};
use propbook::{
    block_scholes_feed::{Self as block_scholes_feed, BlockScholesFeed, SVIParams},
    pyth_feed::PythFeed,
    registry::OracleRegistry
};
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
const EBlockScholesSurfaceStale: u64 = 4;
const EBlockScholesSurfaceInvalid: u64 = 5;
const EPythSpotInvalid: u64 = 6;
const EWrongPythFeed: u64 = 7;
const EWrongBlockScholesFeed: u64 = 8;
const ELivePricingExpired: u64 = 9;

/// Predict's private pricing envelope for raw propbook surfaces. These are not
/// oracle-source validity rules; they only bound the SVI inputs tightly enough
/// that Predict's fixed-point pricing math remains live and meaningful.
macro fun max_pricing_basis(): u64 { 100 * math::float_scaling!() }
// max_pricing_spot * max_pricing_basis / float_scaling == u64::max by
// construction: the re-anchored forward (spot * basis) can't overflow u64.
macro fun max_pricing_spot(): u64 { std::u64::max_value!() / 100 }
macro fun min_svi_sigma(): u64 { 1_000_000 }
macro fun max_svi_input(): u64 { 100 * math::float_scaling!() }

// === Public-Package Functions ===

/// Validate the current live pricing boundary and snapshot oracle inputs for
/// `expiry`'s repeated quote calculations.
///
/// This is the only path from raw Propbook oracle objects into Predict business
/// logic. It first checks that `pyth` and `bs` are the current canonical Propbook
/// oracles for `propbook_underlying_id`, then rejects past-expiry markets, then
/// reads live oracle inputs under Predict's freshness and pricing-safe envelope.
public(package) fun load_live_pricer(
    config: &PricingConfig,
    propbook_registry: &OracleRegistry,
    propbook_underlying_id: u32,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
    expiry: u64,
    clock: &Clock,
): Pricer {
    assert_current_oracles(propbook_registry, propbook_underlying_id, pyth, bs);
    assert!(clock.timestamp_ms() < expiry, ELivePricingExpired);
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

// === Private Functions ===

fun assert_current_oracles(
    propbook_registry: &OracleRegistry,
    propbook_underlying_id: u32,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
) {
    assert!(
        propbook_registry
            .propbook_pyth_id_for_underlying(propbook_underlying_id)
            .contains(&pyth.id()),
        EWrongPythFeed,
    );
    assert!(
        propbook_registry
            .propbook_block_scholes_id_for_underlying(propbook_underlying_id)
            .contains(&bs.id()),
        EWrongBlockScholesFeed,
    );
}

/// Resolve the live forward/SVI tuple used by all live pricing paths.
///
/// Fresh Pyth spot is canonical for spot; forward is then derived from this
/// expiry's Block Scholes basis. If Pyth is stale or has no positive normalized
/// spot, pricing falls back to the Block Scholes forward. The Block Scholes
/// surface (basis + forward + SVI) must be fresh and inside Predict's
/// pricing-safe envelope either way.
fun live_inputs(
    config: &PricingConfig,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
    expiry: u64,
    clock: &Clock,
): (u64, SVIParams) {
    let surface_read = bs.normalized_surface(expiry);
    assert!(surface_read.is_some(), EBlockScholesSurfaceStale);
    let surface_read = surface_read.destroy_some();
    assert!(
        timestamp_is_fresh(
            surface_read.read_source_timestamp_ms(),
            config.block_scholes_surface_freshness_ms(),
            clock,
        ),
        EBlockScholesSurfaceStale,
    );
    let surface = surface_read.read_value();
    let bs_spot = block_scholes_feed::surface_spot(&surface);
    let bs_forward = block_scholes_feed::surface_forward(&surface);
    let svi = block_scholes_feed::surface_svi(&surface);
    assert_surface_pricing_safe(bs_spot, bs_forward, &svi);

    let pyth_spot = pyth.normalized_spot();
    let forward = if (
        pyth_spot.is_some()
            && timestamp_is_fresh(
                pyth_spot.borrow().read_source_timestamp_ms(),
                config.pyth_spot_freshness_ms(),
                clock,
            )
    ) {
        let spot = pyth_spot.destroy_some().read_value();
        assert!(spot <= max_pricing_spot!(), EPythSpotInvalid);
        // Re-anchored forward = spot * (bs_forward / bs_spot) is intentionally
        // NOT re-bounded to max_pricing_spot: with basis up to max_pricing_basis
        // (100x), a legitimate contango forward exceeds the spot ceiling. The two
        // envelope ceilings are co-designed so spot * basis <= u64::max (no
        // overflow), and compute_nd2's deep-tail saturations keep pricing live
        // (P->1) there. A forward ceiling here would abort valid mint/redeem/NAV
        // reads (R1 liveness).
        math::mul(spot, math::div(bs_forward, bs_spot))
    } else {
        bs_forward
    };

    (forward, svi)
}

fun timestamp_is_fresh(timestamp: u64, max_age_ms: u64, clock: &Clock): bool {
    let now = clock.timestamp_ms();
    timestamp > 0 && timestamp <= now && now - timestamp <= max_age_ms
}

fun assert_surface_pricing_safe(spot: u64, forward: u64, svi: &SVIParams) {
    assert!(spot > 0 && forward > 0, EBlockScholesSurfaceInvalid);
    assert!(forward <= max_pricing_spot!(), EBlockScholesSurfaceInvalid);
    assert!(
        ((forward as u128) * (math::float_scaling!() as u128)) / (spot as u128)
            <= (max_pricing_basis!() as u128),
        EBlockScholesSurfaceInvalid,
    );
    assert!(svi.a() <= max_svi_input!(), EBlockScholesSurfaceInvalid);
    assert!(svi.b() <= max_svi_input!(), EBlockScholesSurfaceInvalid);
    assert!(svi.rho().magnitude() <= math::float_scaling!(), EBlockScholesSurfaceInvalid);
    assert!(svi.m().magnitude() <= max_svi_input!(), EBlockScholesSurfaceInvalid);
    assert!(
        svi.sigma() >= min_svi_sigma!() && svi.sigma() <= max_svi_input!(),
        EBlockScholesSurfaceInvalid,
    );
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

    // strike / forward in 1e9 fixed point, computed in u128 so both deep tails
    // saturate instead of underflowing to 0 (which would abort) or wrapping the u64
    // cast. Reaching either tail needs the forward to leave the entire encodable
    // strike ladder by orders of magnitude; saturating keeps NAV / redeem /
    // liquidation reads live there rather than aborting the whole market.
    let strike_ratio_scaled =
        ((strike as u128) * (math::float_scaling!() as u128)) / (forward as u128);
    // Deep-ITM up tail (strike << forward): P(settle > strike) ≈ 1, the neg_inf limit.
    if (strike_ratio_scaled == 0) return math::float_scaling!();
    // Deep-OTM up tail (strike >> forward): P ≈ 0, the pos_inf limit.
    if (strike_ratio_scaled > (std::u64::max_value!() as u128)) return 0;
    let strike_ratio = strike_ratio_scaled as u64;
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
