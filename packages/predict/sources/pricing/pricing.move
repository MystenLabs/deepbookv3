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

// Drift-envelope constants. A price never moves more than the normal curve's
// max slope times its d2 move; 0.4 rounds 1/sqrt(2*pi) up so the fixed-point
// round-down stays a bound.
macro fun drift_phi_max(): u64 { 400_000_000 }
// The normal density's own slope never exceeds phi(1) ~ 0.242; 0.25 rounds up.
macro fun drift_phi_prime_max(): u64 { 250_000_000 }
// Tail allowance outside the banded strike region: 2*N(-4) ~ 6.3e-5 of face
// from the pinned digitals, plus the skew-correction tail held under
// 2 * drift_ctail_target by the dynamic band threshold, plus fixed-point dust.
macro fun drift_tail_pad(): u64 { 150_000 }
// Per-snapshot skew-correction tail target: the band widens until
// phi(D) * (max wing slope / (2 * variance floor)) <= this.
macro fun drift_ctail_target(): u64 { 25_000 }
macro fun drift_band_d(): u64 { 4 * math::float_scaling!() }
// No real strike ladder sits e^100 away from the forward; a wider computed
// band means degenerate params, so the envelope fails closed instead.
macro fun drift_band_cap(): u64 { 100 * math::float_scaling!() }
// Variance floors below 1e-4 mean sub-seconds-to-expiry or a degenerate
// surface: marks there are unusable at any tolerance, so fail closed early
// (this also keeps every division below inside u64/u128 headroom).
macro fun drift_min_floor(): u64 { 100_000 }

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

/// Return the forward this pricer snapshotted (stored as a drift anchor).
public(package) fun forward(pricer: &Pricer): u64 {
    pricer.forward
}

/// Return a copy of the SVI params this pricer snapshotted (stored as a drift anchor).
public(package) fun svi_params(pricer: &Pricer): SVIParams {
    pricer.svi
}

/// Rebuild a `Pricer` from a valuation mark's stored anchors. Deliberately
/// bypasses `load_live_pricer`'s feed-freshness and binding guards: the
/// anchors were validated by the refresh that stored them, and this pricer
/// exists to value orders AT that stored snapshot, never at live state.
public(package) fun from_anchors(expiry_market_id: ID, forward: u64, svi: SVIParams): Pricer {
    Pricer { expiry_market_id, forward, svi }
}

/// Worst-case repricing between two oracle snapshots: an upper bound on how far
/// ANY contract's fair price can have moved between the anchor oracle state and
/// the live one, as a fraction of full payout in FLOAT_SCALING (capped at 1.0).
///
/// This is a bound by construction, not a sample: an SVI surface IS five
/// numbers plus the forward, and every term below charges one of them, so a
/// surface change large enough to move some price somewhere must show up in at
/// least one charged term — there is no strike "between probes" to hide in.
/// The chain: a contract's price can never move more than ~0.4 x its move in
/// d2 (the normal curve's maximum slope — a property of the pricing function,
/// not of the oracle); the worst d2 move over all strikes is then bounded
/// term-by-term — the forward shift scaled by the surface's variance floor,
/// and the surface reshape (each SVI parameter's delta, Lipschitz-bounded over
/// the strike band where prices are not pinned to 0/1). Every term is zero
/// when nothing moved, and degenerate inputs (zero variance floor, wing slope
/// at/above 1, an absurd strike band) return full face — fail-closed, the mark
/// just needs a re-refresh.
///
/// Deliberately conservative: the terms stack worst cases that cannot all
/// happen at the same strike, so benign moves are overstated (costing
/// re-refreshes, never understating drift). The implemented price also
/// subtracts a skew correction `phi(d2) * w'(k) / (2 sqrt(w))`; its own drift
/// is charged by the three skew legs below (the price clamp is 1-Lipschitz, so
/// `|dP| <= |dN(d2)| + |d correction|`), and the band threshold widens
/// dynamically until the correction's tails die under the tail allowance —
/// without that, deep-wing corrections can pull prices off their 0/1 pins (the
/// P-11 mechanism) outside a fixed band. Residual: fixed-point round-down in
/// the term arithmetic (absorbed by the tail pad; the envelope-validation
/// measurements adversarially attack the whole bound).
public(package) fun drift_envelope(
    pricer: &Pricer,
    anchor_forward: u64,
    anchor_svi: &SVIParams,
): u64 {
    // Identical snapshots price identically — exactly zero drift, no tail pad
    // (the pad covers tails between DIFFERENT snapshots). This also lets an
    // atomic refresh-and-flush PTB reproduce the exact single-mark behavior.
    if (anchor_forward == pricer.forward && *anchor_svi == pricer.svi) return 0;

    let full = math::float_scaling!();
    let scale = full as u128;
    let s0 = sqrt_min_total_variance(anchor_svi);
    let s1 = sqrt_min_total_variance(&pricer.svi);
    let s_lo = s0.min(s1);
    if (s_lo < drift_min_floor!() || anchor_forward == 0) return full;
    let s_product = math::mul(s0, s1);
    if (s_product == 0) return full;
    let sigma_lo = anchor_svi.sigma().min(pricer.svi.sigma());
    if (sigma_lo == 0) return full;

    // Forward leg: a forward move shifts every strike's log-moneyness by
    // |ln(F1/F0)|, and d2 divides that by at least the variance floor. Guard
    // the ratio in plain integer division first: a ratio this size is
    // full-face drift regardless, and `math::div` would overflow-abort near
    // u64::MAX rather than fail closed.
    if (pricer.forward / anchor_forward >= 100) return full;
    let forward_ratio = math::div(pricer.forward, anchor_forward);
    if (forward_ratio == 0) return full;
    let delta_forward = math::ln(forward_ratio).magnitude();

    // Band threshold: |d2| = 4 pins the digitals, but the skew correction's
    // tail dies only once phi(D) has decayed past the correction's maximum
    // height r_max = max wing slope / (2 * variance floor) — widen D until
    // phi(D) * r_max fits the per-snapshot tail target.
    let slope0_max = math::mul(anchor_svi.b(), full + anchor_svi.rho().magnitude());
    let slope1_max = math::mul(pricer.svi.b(), full + pricer.svi.rho().magnitude());
    let r0 = math::div(slope0_max, 2 * s0);
    let r1 = math::div(slope1_max, 2 * s1);
    let r_max = r0.max(r1);
    let mut d_threshold = drift_band_d!();
    if (r_max > drift_ctail_target!()) {
        let decay_needed = math::div(math::div(drift_ctail_target!(), r_max), drift_phi_max!());
        if (decay_needed == 0) return full;
        let d_ctail = math::sqrt(2 * math::ln(decay_needed).magnitude(), full);
        d_threshold = d_threshold.max(d_ctail);
    };

    // Strike band where neither snapshot prices any strike away from its 0/1
    // pin by more than the tail allowance. Degenerate/absurd bands fail closed.
    let band0 = unpinned_band(anchor_svi, d_threshold);
    let band1 = unpinned_band(&pricer.svi, d_threshold);
    if (band0.is_none() || band1.is_none()) return full;
    let k_band = band0.destroy_some().max(band1.destroy_some());
    if (k_band > drift_band_cap!()) return full;

    // Surface leg: the worst total-variance gap between the snapshots over the
    // band, one Lipschitz charge per SVI parameter delta (plus the band shift
    // the forward move causes), converted to a sqrt-variance gap and then to a
    // d2 move.
    let m1_abs = pricer.svi.m().magnitude();
    let g1_max = 2 * (k_band + m1_abs) + pricer.svi.sigma();
    let delta_rho = pricer.svi.rho().sub(&anchor_svi.rho()).magnitude();
    let delta_m = pricer.svi.m().sub(&anchor_svi.m()).magnitude();
    let delta_sigma = pricer.svi.sigma().diff(anchor_svi.sigma());
    let delta_a = pricer.svi.a().diff(anchor_svi.a());
    let delta_b = pricer.svi.b().diff(anchor_svi.b());
    let sup_wing_gap =
        math::mul(delta_rho, k_band + m1_abs) + math::mul(anchor_svi.rho().magnitude(), delta_m)
            + delta_m + delta_sigma;
    let sup_delta_w =
        delta_a + math::mul(delta_b, g1_max) + math::mul(anchor_svi.b(), sup_wing_gap)
            + math::mul(slope1_max, delta_forward);
    let sup_delta_sqrt_w =
        ((sup_delta_w as u128) * scale / ((s0 + s1) as u128)).min(100 * scale) as u64;

    // Everything below assembles in u128 with a single cap at full face:
    // fail-closed saturation, never an arithmetic abort in the flush path.
    let half = (full / 2) as u128;
    let moneyness_ratio = (k_band as u128) * scale / (s_product as u128);
    let d2_bound =
        (delta_forward as u128) * scale / (s1 as u128)
        + (sup_delta_sqrt_w as u128) * (moneyness_ratio + half) / scale;
    let n_leg = (drift_phi_max!() as u128) * d2_bound / scale;
    if (n_leg >= scale) return full;

    // Skew legs. The correction is phi(d2) * R(k) with R = w' / (2 sqrt(w)):
    // charge phi_max times R's change (split into the w' change and the
    // sqrt(w) change), plus R's height times the density's own move (the
    // density's slope never exceeds ~0.25, and d2's move is already bounded).
    let delta_u = math::div(delta_m + delta_sigma, sigma_lo);
    let sup_delta_w_prime =
        2 * delta_b + math::mul(anchor_svi.b(), delta_rho + delta_u)
            + math::mul(pricer.svi.b(), math::div(delta_forward, pricer.svi.sigma()));
    let skew_w_prime_leg =
        (drift_phi_max!() as u128) * (sup_delta_w_prime as u128) / ((2 * s_lo) as u128);
    let skew_sqrt_w_leg =
        (drift_phi_max!() as u128) * ((r_max as u128) * (sup_delta_sqrt_w as u128) / (s_lo as u128))
            / scale;
    let skew_density_leg =
        (drift_phi_prime_max!() as u128) * ((r0 as u128) * d2_bound / scale) / scale;

    let total =
        n_leg + skew_w_prime_leg + skew_sqrt_w_leg + skew_density_leg
        + (drift_tail_pad!() as u128);
    total.min(scale) as u64
}

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

/// The size of one standard deviation of the price move this surface still
/// expects before expiry, at the strike where that expectation is smallest —
/// `sqrt(a + b * sigma * sqrt(1 - rho^2))`, the global minimum of SVI total
/// variance over strikes. The drift envelope's forward leg divides by it.
fun sqrt_min_total_variance(svi: &SVIParams): u64 {
    let rho_squared = svi.rho().mul_scaled(&svi.rho()).magnitude();
    // |rho| <= 1 inside the pricing-safe envelope; saturate the complement against
    // fixed-point rounding dust at the |rho| = 1 corner.
    let one_minus_rho_squared = math::float_scaling!().saturating_sub(rho_squared);
    let root = math::sqrt(one_minus_rho_squared, math::float_scaling!());
    let min_total_var = svi.a() + math::mul(svi.b(), math::mul(svi.sigma(), root));
    math::sqrt(min_total_var, math::float_scaling!())
}

/// Log-moneyness band `K` outside which this surface pins every price within
/// the tail pad of 0 or 1 (|d2| > D on both tails). Solves
/// `K = D * sqrt(W) + W / 2` against the surface's own linear overshoot
/// `W = A + B * K` (with `A = a + b * (2|m| + sigma)`, `B = 2b`, from
/// `w(k) <= A + B|k|`), so the band covers every strike the surface can price
/// away from the pins. `None` when the surface is too degenerate to band
/// (wing slope at/above ~1, or a band past the cap) — the caller fails closed.
fun unpinned_band(svi: &SVIParams, d: u64): Option<u64> {
    let one = math::float_scaling!();
    let cap = drift_band_cap!();
    let a_overshoot = svi.a() + math::mul(svi.b(), 2 * svi.m().magnitude() + svi.sigma());
    let b_slope = svi.b();
    // Near/above slope 1 the quadratic degenerates (denominator -> 0); no real
    // surface is close (observed b <= ~0.03), so fail closed rather than solve.
    if (b_slope > 999_000_000) return option::none();

    if (b_slope < 1_000) {
        // Slope negligible: W ~ A. The 10% headroom covers the ignored slope.
        let k = math::mul(d, math::sqrt(a_overshoot, one)) + a_overshoot / 2;
        let k = k + k / 10;
        if (k > cap) return option::none();
        return option::some(k)
    };

    let b_coeff = 2 * b_slope;
    let bd = math::mul(b_coeff, d);
    let discriminant = math::mul(bd, bd) + 4 * math::mul(a_overshoot, one - b_slope);
    let sqrt_w = math::div(bd + math::sqrt(discriminant, one), 2 * (one - b_slope));
    let w = math::mul(sqrt_w, sqrt_w);
    let w_minus_a = w.saturating_sub(a_overshoot);
    // With a real slope the true W strictly exceeds A; a computed zero means
    // the round-down chain swallowed the band (ill-conditioned at low
    // variance — reviewed counterexample understated drift ~13.6x). No tight
    // bound exists here, so fail closed: the caller charges full face and the
    // market prices at its worst case until a refresh re-anchors it.
    if (w_minus_a == 0) return option::none();
    // K = (W - A) / B; refuse before dividing when K would exceed the cap.
    if (w_minus_a > math::mul(b_coeff, cap)) return option::none();
    let k = math::div(w_minus_a, b_coeff);
    if (k > cap) return option::none();
    option::some(k)
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
