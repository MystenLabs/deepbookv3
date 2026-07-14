// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pricing for Predict markets.
///
/// This module is the app-facing read layer for oracle data. It reads the
/// standalone propbook Pyth and Block Scholes feeds on demand and computes SVI
/// range prices. It does not mutate feed, pool, expiry, or position state, and it
/// owns the live pricing boundary: current Propbook feed binding, pre-expiry
/// market liveness, feed freshness, and Predict's pricing-safe BS input envelope.
module deepbook_predict::pricing;

use deepbook_predict::{constants, pricing_config::PricingConfig};
use fixed_math::{i64, math};
use propbook::{
    block_scholes_forward_feed::BlockScholesForwardFeed,
    block_scholes_spot_feed::BlockScholesSpotFeed,
    block_scholes_svi_feed::{BlockScholesSVIFeed, SVIParams},
    pyth_feed::PythFeed,
    registry::OracleRegistry
};
use sui::{clock::Clock, object::ID};

/// Value snapshot of live oracle inputs for one market's price calculations.
public struct Pricer has copy, drop {
    /// Expiry market this snapshot was loaded for.
    expiry_market_id: ID,
    forward: u64,
    svi: SVIParams,
}

/// Per-flush cache of `up_price` results keyed by finite boundary tick, ascending.
///
/// The NAV linear walk (`strike_payout_tree::walk_linear`) fills it once per node
/// as it prices the payout tree in-order; the correction walk
/// (`liquidation_book::correction_value`) then reads each leveraged order's boundary
/// prices back by binary search instead of re-pricing every order. Every active
/// leveraged order's finite boundary ticks are payout-tree nodes, so every finite
/// lookup MUST hit: a miss is a broken exposure index, not a cache fallback, and
/// `cached_range_price` aborts `ETickNotInPriceMemo` rather than silently repricing.
public struct PriceMemo has drop {
    /// Finite boundary ticks in ascending order (the in-order walk appends them).
    ticks: vector<u64>,
    /// `up_price(ticks[i] * tick_size)`, parallel to `ticks`.
    prices: vector<u64>,
}

const EZeroForward: u64 = 0;
const ECannotBeNegative: u64 = 1;
const EZeroVariance: u64 = 2;
const EInvalidRange: u64 = 3;
const EBlockScholesPriceStale: u64 = 4;
const EBlockScholesInputsInvalid: u64 = 5;
const EPythSpotInvalid: u64 = 6;
const EWrongPythFeed: u64 = 7;
const EWrongBlockScholesSpotFeed: u64 = 8;
const ELivePricingExpired: u64 = 9;
const EBlockScholesSVIStale: u64 = 10;
const EWrongBlockScholesForwardFeed: u64 = 11;
const EWrongBlockScholesSVIFeed: u64 = 12;
const ETickNotInPriceMemo: u64 = 13;
const EBlockScholesPriceUnavailable: u64 = 14;
const EBlockScholesSVIUnavailable: u64 = 15;
const EMarkPriceDrifted: u64 = 16;

/// Predict's private pricing envelope for raw propbook BS inputs. These are not
/// oracle-source validity rules; they only bound the forward/basis and SVI inputs
/// tightly enough that Predict's fixed-point pricing math remains live and
/// meaningful.
macro fun max_pricing_basis(): u64 { 100 * math::float_scaling!() }
// max_pricing_spot * max_pricing_basis / float_scaling <= u64::max by
// construction: the re-anchored forward (spot * basis) can't overflow u64.
macro fun max_pricing_spot(): u64 { std::u64::max_value!() / 100 }
macro fun min_svi_sigma(): u64 { 1_000_000 }
macro fun max_svi_input(): u64 { 100 * math::float_scaling!() }

// === Public Functions ===

/// Return the current UP tail price for one strike. Public read for
/// SDK/devInspect board pricing off a legitimately loaded `Pricer`.
public fun up_price(pricer: &Pricer, strike: u64): u64 {
    compute_up_price(&pricer.svi, pricer.forward, strike)
}

/// Return the current raw probability for a live range. Public read for
/// SDK/devInspect board pricing off a legitimately loaded `Pricer`.
public fun range_price(pricer: &Pricer, lower: u64, higher: u64): u64 {
    compute_range_price(&pricer.svi, pricer.forward, lower, higher)
}

/// Return the expiry market this pricer was loaded for.
public(package) fun expiry_market_id(pricer: &Pricer): ID {
    pricer.expiry_market_id
}

/// Sample seven probe contracts for the drift guard: strikes fanned around the
/// forward at {-4, -2, -1, 0, +1, +2, +4} expected-moves-to-expiry, each with
/// its current fair UP price. Stored in a market's valuation mark at refresh;
/// the flush reprices the same strikes on the live surface and rejects the mark
/// when any probe price moved more than the configured fraction of full payout
/// — one check that catches forward moves, expiry decay, and wing reshapes
/// alike, because any oracle change that matters to contract prices moves a
/// probe. Residual accepted: reshapes confined strictly between probes; deep
/// wings beyond the outermost probes self-limit because prices there sit
/// pinned near 0 or 1. Returns `(strikes, prices)`, parallel.
public(package) fun price_probes(pricer: &Pricer): (vector<u64>, vector<u64>) {
    let scale = sqrt_min_total_variance(pricer);
    let multipliers = vector[
        i64::from_parts(4, true),
        i64::from_parts(2, true),
        i64::from_parts(1, true),
        i64::from_u64(0),
        i64::from_u64(1),
        i64::from_u64(2),
        i64::from_u64(4),
    ];
    let mut strikes = vector[];
    let mut prices = vector[];
    multipliers.do!(|multiplier| {
        // Cap the exponent so a max-envelope surface (sqrt variance up to ~10)
        // cannot abort the refresh through EExpOverflow: strikes past
        // e^±2 x forward are deep wings whose probe prices pin near 0/1 anyway.
        let exponent_magnitude = (multiplier.magnitude() * scale).min(
            2 * math::float_scaling!(),
        );
        let exponent = i64::from_parts(exponent_magnitude, multiplier.is_negative());
        let strike = math::mul(pricer.forward, math::exp(&exponent));
        strikes.push_back(strike);
        prices.push_back(up_price(pricer, strike));
    });
    (strikes, prices)
}

/// Abort unless every stored probe contract still prices within `epsilon` of
/// its anchored fair price on the live surface. `epsilon` is a fraction of
/// full payout in FLOAT_SCALING, so this check IS the guard's face-error bound
/// at the probes: a mark the flush accepts cannot have drifted by more than
/// `epsilon` of face there, whatever mix of forward move, variance decay, or
/// surface reshape produced the drift. Near expiry a given oracle move
/// produces larger price moves, so the guard tightens automatically in the
/// only units that matter.
public(package) fun assert_probe_prices_within(
    pricer: &Pricer,
    probe_strikes: &vector<u64>,
    probe_prices: &vector<u64>,
    epsilon: u64,
) {
    let probe_count = probe_strikes.length();
    let mut i = 0;
    while (i < probe_count) {
        let live_price = up_price(pricer, probe_strikes[i]);
        assert!(live_price.diff(probe_prices[i]) <= epsilon, EMarkPriceDrifted);
        i = i + 1;
    };
}

// === Public-Package Functions ===

/// Validate the current live pricing boundary and snapshot oracle inputs for
/// one market's repeated quote calculations.
///
/// This is the only path from raw Propbook oracle objects into Predict business
/// logic. It first checks that `pyth`, `bs_spot`, `bs_forward`, and `bs_svi` are
/// the current canonical Propbook oracles for `propbook_underlying_id`, then
/// rejects past-expiry markets, then reads live oracle inputs under Predict's
/// freshness and pricing-safe envelope.
public(package) fun load_live_pricer(
    config: &PricingConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs_spot: &BlockScholesSpotFeed,
    bs_forward: &BlockScholesForwardFeed,
    bs_svi: &BlockScholesSVIFeed,
    expiry_market_id: ID,
    propbook_underlying_id: u32,
    expiry: u64,
    clock: &Clock,
): Pricer {
    assert_current_oracles(
        propbook_registry,
        propbook_underlying_id,
        pyth,
        bs_spot,
        bs_forward,
        bs_svi,
    );
    assert!(clock.timestamp_ms() < expiry, ELivePricingExpired);
    let (forward, svi) = live_inputs(config, pyth, bs_spot, bs_forward, bs_svi, expiry, clock);
    Pricer { expiry_market_id, forward, svi }
}

/// Create an empty per-flush price cache (see `PriceMemo`).
public(package) fun new_price_memo(): PriceMemo {
    PriceMemo { ticks: vector[], prices: vector[] }
}

/// Read the cached range price `up_price(lower) - up_price(higher)` for one order's
/// tick range, mirroring `range_price`'s infinity sentinels and saturating floor.
/// Both finite boundaries must have been cached by the linear walk; a finite miss
/// aborts (the order's tick is not a payout-tree node — a broken index, not dust).
public(package) fun cached_range_price(memo: &PriceMemo, lower_tick: u64, higher_tick: u64): u64 {
    memo.cached_up_price(lower_tick).saturating_sub(memo.cached_up_price(higher_tick))
}

/// Price `tick` through `pricer` and append it to the cache. Called once per node by
/// the in-order linear walk, so `ticks` stays ascending for `cached_up_price`'s
/// binary search. Only finite ticks are stored (the tree never holds inf boundaries).
public(package) fun price_and_cache(
    memo: &mut PriceMemo,
    pricer: &Pricer,
    tick: u64,
    tick_size: u64,
): u64 {
    let price = pricer.up_price(tick * tick_size);
    memo.ticks.push_back(tick);
    memo.prices.push_back(price);
    price
}

// === Private Functions ===

/// Look up a boundary tick's cached UP price. Infinity boundaries are never tree
/// nodes, so they short-circuit to `compute_up_price`'s sentinels (`P(-inf) = 1`,
/// `P(+inf) = 0`); every finite tick must be present or the exposure index is broken.
fun cached_up_price(memo: &PriceMemo, tick: u64): u64 {
    if (tick == 0) return math::float_scaling!(); // tick 0 is the neg-inf sentinel
    if (tick == constants::pos_inf_tick!()) return 0;

    let ticks = &memo.ticks;
    let mut lo = 0;
    let mut hi = ticks.length();
    while (lo < hi) {
        let mid = lo + (hi - lo) / 2;
        let mid_tick = ticks[mid];
        if (mid_tick == tick) return memo.prices[mid];
        if (mid_tick < tick) lo = mid + 1 else hi = mid;
    };
    abort ETickNotInPriceMemo
}

fun assert_current_oracles(
    propbook_registry: &OracleRegistry,
    propbook_underlying_id: u32,
    pyth: &PythFeed,
    bs_spot: &BlockScholesSpotFeed,
    bs_forward: &BlockScholesForwardFeed,
    bs_svi: &BlockScholesSVIFeed,
) {
    assert!(
        propbook_registry
            .propbook_pyth_id_for_underlying(propbook_underlying_id)
            .contains(&pyth.id()),
        EWrongPythFeed,
    );
    assert!(
        propbook_registry
            .propbook_block_scholes_spot_id_for_underlying(propbook_underlying_id)
            .contains(&bs_spot.id()),
        EWrongBlockScholesSpotFeed,
    );
    assert!(
        propbook_registry
            .propbook_block_scholes_forward_id_for_underlying(propbook_underlying_id)
            .contains(&bs_forward.id()),
        EWrongBlockScholesForwardFeed,
    );
    assert!(
        propbook_registry
            .propbook_block_scholes_svi_id_for_underlying(propbook_underlying_id)
            .contains(&bs_svi.id()),
        EWrongBlockScholesSVIFeed,
    );
}

/// Resolve the live forward/SVI tuple used by all live pricing paths.
///
/// Fresh Pyth spot is canonical for spot; forward is then derived from this
/// expiry's Block Scholes basis. If Pyth is stale or has no positive normalized
/// spot, pricing falls back to the Block Scholes forward. The Block Scholes
/// spot/forward pair must be fresh enough for basis math; SVI has its own looser
/// freshness threshold. All inputs must be inside Predict's pricing-safe envelope.
fun live_inputs(
    config: &PricingConfig,
    pyth: &PythFeed,
    bs_spot: &BlockScholesSpotFeed,
    bs_forward: &BlockScholesForwardFeed,
    bs_svi: &BlockScholesSVIFeed,
    expiry: u64,
    clock: &Clock,
): (u64, SVIParams) {
    let bs_spot_read = bs_spot.normalized_spot();
    assert!(bs_spot_read.is_some(), EBlockScholesPriceUnavailable);
    let bs_spot_read = bs_spot_read.destroy_some();
    assert!(
        timestamp_is_fresh(
            bs_spot_read.read_source_timestamp_ms(),
            config.block_scholes_price_freshness_ms(),
            clock,
        ),
        EBlockScholesPriceStale,
    );
    let bs_spot = bs_spot_read.read_value();

    let bs_forward_read = bs_forward.normalized_forward(expiry);
    assert!(bs_forward_read.is_some(), EBlockScholesPriceUnavailable);
    let bs_forward_read = bs_forward_read.destroy_some();
    assert!(
        timestamp_is_fresh(
            bs_forward_read.read_source_timestamp_ms(),
            config.block_scholes_price_freshness_ms(),
            clock,
        ),
        EBlockScholesPriceStale,
    );
    let bs_forward = bs_forward_read.read_value();

    let svi_read = bs_svi.normalized_svi(expiry);
    assert!(svi_read.is_some(), EBlockScholesSVIUnavailable);
    let svi_read = svi_read.destroy_some();
    assert!(
        timestamp_is_fresh(
            svi_read.read_source_timestamp_ms(),
            config.block_scholes_svi_freshness_ms(),
            clock,
        ),
        EBlockScholesSVIStale,
    );
    let svi = svi_read.read_value();
    assert_inputs_pricing_safe(bs_spot, bs_forward, &svi);

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

fun timestamp_is_fresh(source_timestamp_ms: u64, max_age_ms: u64, clock: &Clock): bool {
    let now = clock.timestamp_ms();
    source_timestamp_ms > 0 && source_timestamp_ms <= now && now - source_timestamp_ms <= max_age_ms
}

fun assert_inputs_pricing_safe(spot: u64, forward: u64, svi: &SVIParams) {
    assert!(spot > 0 && forward > 0, EBlockScholesInputsInvalid);
    assert!(forward <= max_pricing_spot!(), EBlockScholesInputsInvalid);
    assert!(
        ((forward as u128) * (math::float_scaling!() as u128)) / (spot as u128)
            <= (max_pricing_basis!() as u128),
        EBlockScholesInputsInvalid,
    );
    assert!(svi.a() <= max_svi_input!(), EBlockScholesInputsInvalid);
    assert!(svi.b() <= max_svi_input!(), EBlockScholesInputsInvalid);
    assert!(svi.rho().magnitude() <= math::float_scaling!(), EBlockScholesInputsInvalid);
    assert!(svi.m().magnitude() <= max_svi_input!(), EBlockScholesInputsInvalid);
    assert!(
        svi.sigma() >= min_svi_sigma!() && svi.sigma() <= max_svi_input!(),
        EBlockScholesInputsInvalid,
    );
}

/// Compute the fair price for the range `(lower, higher]`.
fun compute_range_price(svi: &SVIParams, forward: u64, lower: u64, higher: u64): u64 {
    assert!(lower < higher, EInvalidRange);

    let lower_up_price = compute_up_price(svi, forward, lower);
    let higher_up_price = compute_up_price(svi, forward, higher);
    // A range price cannot be negative. Floor at zero when fixed-point dust or an
    // admitted butterfly-arbitrageable SVI surface inverts the boundary prices;
    // predeploy P-11 tracks the material accounting case.
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
/// - price = N(d2) - phi(d2) * w'(k) / (2 * sqrt(w(k)))
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
    // Analytically non-negative inside the pricing-safe envelope: |rho| <= 1 and
    // sqrt((k-m)^2 + sigma^2) >= |k-m| >= |rho·(k-m)|. Kept as defense-in-depth
    // against fixed-point rounding at the |rho| = 1 corner; no production input
    // is known to reach it, so it carries no expected_failure test.
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

    let slope_ratio = k_minus_m.div_scaled(&sq_i64);
    let slope = rho.add(&slope_ratio);
    let w_prime = i64::from_u64(b).mul_scaled(&slope);
    let nd2 = math::normal_cdf(&d2);
    if (w_prime.is_zero()) return nd2;

    let correction_magnitude = math::mul_div_down(
        math::normal_pdf(&d2),
        w_prime.magnitude(),
        2 * sqrt_var,
    );
    let correction = i64::from_parts(correction_magnitude, w_prime.is_negative());
    let adjusted = i64::from_u64(nd2).sub(&correction);
    if (adjusted.is_negative()) return 0;
    if (adjusted.magnitude() > math::float_scaling!()) return math::float_scaling!();
    adjusted.magnitude()
}

/// The size of one standard deviation of the price move this surface still
/// expects before expiry, at the strike where that expectation is smallest —
/// `sqrt(a + b * sigma * sqrt(1 - rho^2))`, the global minimum of SVI total
/// variance over strikes. Sets the probe-grid spacing so the drift guard's
/// probe contracts span the price-relevant strike range at every expiry.
fun sqrt_min_total_variance(pricer: &Pricer): u64 {
    let rho = pricer.svi.rho();
    let rho_squared = rho.mul_scaled(&rho).magnitude();
    // |rho| <= 1 inside the pricing-safe envelope; saturate the complement against
    // fixed-point rounding dust at the |rho| = 1 corner.
    let one_minus_rho_squared = math::float_scaling!().saturating_sub(rho_squared);
    let root = math::sqrt(one_minus_rho_squared, math::float_scaling!());
    let min_total_var =
        pricer.svi.a() + math::mul(pricer.svi.b(), math::mul(pricer.svi.sigma(), root));
    math::sqrt(min_total_var, math::float_scaling!())
}
