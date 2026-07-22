// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pricing for Predict markets.
///
/// This module reads canonical Propbook Pyth and Block Scholes feeds and computes
/// SVI-adjusted digital probabilities. Live reads require fresh, pricing-safe Block
/// Scholes spot, forward, and SVI observations. A fresh positive Pyth spot reanchors
/// the Block Scholes forward basis; otherwise pricing uses that forward directly.
/// Exact-history reads do not apply live freshness policy.
module deepbook_predict::pricing;

use deepbook_predict::{constants, pricing_config::PricingConfig, range_codec::{Self, Strike}};
use fixed_math::{approx::{Self, Approx}, i64::{Self, I64}, math};
use propbook::{
    block_scholes_forward_feed::BlockScholesForwardFeed,
    block_scholes_spot_feed::BlockScholesSpotFeed,
    block_scholes_svi_feed::{BlockScholesSVIFeed, SVIParams},
    pyth_feed::PythFeed,
    registry::OracleRegistry
};
use sui::clock::Clock;

/// Validated live oracle inputs bound to one expiry market. `Pricer` has no
/// `store` ability and must be created again in each transaction that prices.
public struct Pricer has copy, drop {
    /// Expiry market this snapshot was loaded for.
    expiry_market_id: ID,
    forward: u64,
    svi: SVIParams,
    /// Source timestamps of the oracle observations present when this snapshot
    /// was loaded. Pyth is `0` only when no usable normalized observation exists.
    pyth_spot_source_timestamp_ms: u64,
    block_scholes_spot_source_timestamp_ms: u64,
    block_scholes_forward_source_timestamp_ms: u64,
    block_scholes_svi_source_timestamp_ms: u64,
}

/// Canonical normalized Pyth spot read at one exact source timestamp.
/// Constructed only by `load_exact_spot_read`; consumers decide whether an
/// absent exact-history row is a no-op or an abort.
public struct ExactSpotRead has drop {
    spot: Option<u64>,
}

/// Per-flush cache of `up_price` results keyed by finite boundary tick, ascending
/// and non-increasing in price.
///
/// The NAV linear walk (`strike_payout_tree::walk_linear`) fills it once per node
/// as it prices the payout tree in-order; the correction walk
/// (`liquidation_book::correction_value`) then reads each leveraged order's boundary
/// prices back by binary search instead of re-pricing every order. Every active
/// leveraged order's finite boundary ticks are payout-tree nodes, so every finite
/// lookup MUST hit: a miss is a broken exposure index, not a cache fallback, and
/// `cached_range_price` aborts `ETickNotInPriceMemo` rather than silently repricing.
/// The same cache rejects non-monotone UP prices during NAV valuation, because
/// `walk_linear` tree-wide netting is exact only on a monotone active surface.
public struct PriceMemo has drop {
    /// Finite boundary ticks in ascending order (the in-order walk appends them).
    ticks: vector<u64>,
    /// `up_price(ticks[i] * tick_size)`, with its certified error, parallel to `ticks`.
    prices: vector<Approx>,
}

const EZeroForward: u64 = 0;
const ECannotBeNegative: u64 = 1;
const ENonPositiveVariance: u64 = 2;
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
const EBlockScholesMinVarianceInvalid: u64 = 16;
const ENonMonotonePriceMemo: u64 = 17;

/// Predict's private pricing envelope for raw propbook BS inputs. These are not
/// oracle-source validity rules; they only bound the forward/basis and SVI inputs
/// tightly enough that Predict's fixed-point pricing math remains live and
/// meaningful.
macro fun max_pricing_basis_factor(): u64 { 100 }

// Co-designed with the basis factor: forward <= factor * spot (envelope) and
// spot <= u64::max / factor, so the re-anchored forward spot * bs_forward /
// bs_spot <= factor * spot can't overflow u64.
macro fun max_pricing_spot(): u64 { std::u64::max_value!() / max_pricing_basis_factor!() }

macro fun min_svi_sigma(): u64 { 1_000_000 }

macro fun max_svi_input(): u64 { 100 * math::float_scaling!() }

// The SVI variance is a product of two 1e9-scaled terms. Retain that product at
// 1e18 in the ND2 certificate so a sub-raw variance increment is not discarded
// before the square root. This is private pricing precision, not a protocol scale.
macro fun variance_scaling(): u128 { 1_000_000_000u128 }

macro fun max_pdf_slope(): u64 { 242_000_000 }

// === Public Functions ===

/// Return the current UP digital probability for a typed strike. Public PTB and
/// devInspect reads can compose it with a transaction-local `Pricer`.
public fun up_price(pricer: &Pricer, strike: Strike): u64 {
    compute_up_price(&pricer.svi, pricer.forward, strike).magnitude()
}

/// Return the current probability for `(lower, higher]`, floored at zero if the
/// two approximated boundary probabilities invert.
public fun range_price(pricer: &Pricer, lower: Strike, higher: Strike): u64 {
    compute_range_price(&pricer.svi, pricer.forward, lower, higher).magnitude()
}

// === Public-Package Functions ===

/// Return the probability for `(lower, higher]` with its certified error retained
/// for package-internal protocol decisions. The public `range_price` is the
/// value-only view for external reads.
public(package) fun range_price_approx(pricer: &Pricer, lower: Strike, higher: Strike): Approx {
    compute_range_price(&pricer.svi, pricer.forward, lower, higher)
}

/// Return the expiry market this pricer was loaded for.
public(package) fun expiry_market_id(pricer: &Pricer): ID {
    pricer.expiry_market_id
}

public(package) fun pyth_spot_source_timestamp_ms(pricer: &Pricer): u64 {
    pricer.pyth_spot_source_timestamp_ms
}

public(package) fun block_scholes_spot_source_timestamp_ms(pricer: &Pricer): u64 {
    pricer.block_scholes_spot_source_timestamp_ms
}

public(package) fun block_scholes_forward_source_timestamp_ms(pricer: &Pricer): u64 {
    pricer.block_scholes_forward_source_timestamp_ms
}

public(package) fun block_scholes_svi_source_timestamp_ms(pricer: &Pricer): u64 {
    pricer.block_scholes_svi_source_timestamp_ms
}

public(package) fun into_spot(read: ExactSpotRead): Option<u64> {
    let ExactSpotRead { spot } = read;
    spot
}

/// Validate the current live pricing boundary and snapshot oracle inputs for
/// one market's repeated quote calculations.
///
/// The supplied feeds must be the current Propbook bindings for the underlying,
/// and the market must be pre-expiry. Block Scholes spot, forward, and SVI inputs
/// must normalize, pass their fixed wall-clock freshness thresholds, and fit the
/// pricing-safe envelope. A fresh positive normalized Pyth spot reanchors the Block
/// Scholes forward basis; a missing, non-normalizable, or stale Pyth spot is ignored.
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
    resolve_live_pricer(
        config,
        pyth,
        bs_spot,
        bs_forward,
        bs_svi,
        expiry_market_id,
        expiry,
        clock,
    )
}

/// Validate the canonical Pyth binding and read its normalized spot at exactly
/// `source_timestamp_ms`. The product preserves absence so the reference-tick
/// and settlement flows can retain their distinct missing-data policies.
public(package) fun load_exact_spot_read(
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    propbook_underlying_id: u32,
    source_timestamp_ms: u64,
): ExactSpotRead {
    assert_current_pyth(propbook_registry, propbook_underlying_id, pyth);
    let read = pyth.normalized_spot_at(source_timestamp_ms);
    let spot = if (read.is_some()) {
        option::some(read.destroy_some().read_value())
    } else {
        option::none()
    };
    ExactSpotRead { spot }
}

/// Create an empty per-flush price cache (see `PriceMemo`).
public(package) fun new_price_memo(): PriceMemo {
    PriceMemo {
        ticks: vector[],
        prices: vector[],
    }
}

/// Read the cached range price `up_price(lower) - up_price(higher)` for one order's
/// tick range, mirroring `range_price`'s infinity sentinels and saturating floor.
/// Both finite boundaries must have been cached by the linear walk; a finite miss
/// aborts (the order's tick is not a payout-tree node — a broken index, not dust).
public(package) fun cached_range_price(memo: &PriceMemo, lower_tick: u64, higher_tick: u64): u64 {
    memo.cached_range_price_approx(lower_tick, higher_tick).magnitude()
}

/// Read the cached range price with its certified error. The scalar wrapper above
/// remains for callers that intentionally end the approximate flow here.
public(package) fun cached_range_price_approx(
    memo: &PriceMemo,
    lower_tick: u64,
    higher_tick: u64,
): Approx {
    let lower = memo.cached_up_price(lower_tick);
    let higher = memo.cached_up_price(higher_tick);
    lower.sub(&higher).clamp_nonnegative()
}

/// Price `tick` through `pricer` and append its approximate value to the cache.
/// Called once per node by the in-order linear walk, so `ticks` stays ascending for
/// `cached_up_price`'s binary search. Only finite ticks are stored (the tree never
/// holds inf boundaries).
public(package) fun price_and_cache(
    memo: &mut PriceMemo,
    pricer: &Pricer,
    tick: u64,
    tick_size: u64,
): Approx {
    let price = compute_up_price(
        &pricer.svi,
        pricer.forward,
        range_codec::strike_from_tick(tick, tick_size),
    );
    if (!memo.prices.is_empty()) {
        let previous = memo.prices[memo.prices.length() - 1];
        // Higher strikes should not have higher UP prices. NAV's linear tree walk
        // relies on that order; an inverted surface can overstate pool value.
        assert!(price.magnitude() <= previous.magnitude(), ENonMonotonePriceMemo);
    };
    memo.ticks.push_back(tick);
    memo.prices.push_back(price);
    price
}

// === Private Functions ===

/// Look up a boundary tick's cached UP price. Infinity boundaries are never tree
/// nodes, so they short-circuit to `compute_up_price`'s sentinels (`P(-inf) = 1`,
/// `P(+inf) = 0`); every finite tick must be present or the exposure index is broken.
fun cached_up_price(memo: &PriceMemo, tick: u64): Approx {
    if (tick == 0) return approx::exact_u64(math::float_scaling!()); // neg-inf sentinel
    if (tick == constants::pos_inf_tick!()) return approx::exact_u64(0);

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
    assert_current_pyth(propbook_registry, propbook_underlying_id, pyth);
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

fun assert_current_pyth(
    propbook_registry: &OracleRegistry,
    propbook_underlying_id: u32,
    pyth: &PythFeed,
) {
    assert!(
        propbook_registry
            .propbook_pyth_id_for_underlying(propbook_underlying_id)
            .contains(&pyth.id()),
        EWrongPythFeed,
    );
}

/// Resolve live forward and SVI inputs and retain every feed's source timestamp.
/// A fresh positive normalized Pyth spot re-anchors the Block Scholes forward
/// basis; otherwise the Block Scholes forward is used directly.
fun resolve_live_pricer(
    config: &PricingConfig,
    pyth: &PythFeed,
    bs_spot: &BlockScholesSpotFeed,
    bs_forward: &BlockScholesForwardFeed,
    bs_svi: &BlockScholesSVIFeed,
    expiry_market_id: ID,
    expiry: u64,
    clock: &Clock,
): Pricer {
    let bs_spot_read = bs_spot.normalized_spot();
    assert!(bs_spot_read.is_some(), EBlockScholesPriceUnavailable);
    let bs_spot_read = bs_spot_read.destroy_some();
    let block_scholes_spot_source_timestamp_ms = bs_spot_read.read_source_timestamp_ms();
    assert!(
        timestamp_is_fresh(
            block_scholes_spot_source_timestamp_ms,
            config.block_scholes_price_freshness_ms(),
            clock,
        ),
        EBlockScholesPriceStale,
    );
    let bs_spot = bs_spot_read.read_value();

    let bs_forward_read = bs_forward.normalized_forward(expiry);
    assert!(bs_forward_read.is_some(), EBlockScholesPriceUnavailable);
    let bs_forward_read = bs_forward_read.destroy_some();
    let block_scholes_forward_source_timestamp_ms = bs_forward_read.read_source_timestamp_ms();
    assert!(
        timestamp_is_fresh(
            block_scholes_forward_source_timestamp_ms,
            config.block_scholes_price_freshness_ms(),
            clock,
        ),
        EBlockScholesPriceStale,
    );
    let bs_forward = bs_forward_read.read_value();

    let svi_read = bs_svi.normalized_svi(expiry);
    assert!(svi_read.is_some(), EBlockScholesSVIUnavailable);
    let svi_read = svi_read.destroy_some();
    let block_scholes_svi_source_timestamp_ms = svi_read.read_source_timestamp_ms();
    assert!(
        timestamp_is_fresh(
            block_scholes_svi_source_timestamp_ms,
            config.block_scholes_svi_freshness_ms(),
            clock,
        ),
        EBlockScholesSVIStale,
    );
    let svi = svi_read.read_value();
    assert_inputs_pricing_safe(bs_spot, bs_forward, &svi);

    let pyth_spot = pyth.normalized_spot();
    let pyth_spot_source_timestamp_ms = if (pyth_spot.is_some()) {
        pyth_spot.borrow().read_source_timestamp_ms()
    } else {
        0
    };
    let mut forward = bs_forward;
    if (
        pyth_spot.is_some()
            && timestamp_is_fresh(
                pyth_spot_source_timestamp_ms,
                config.pyth_spot_freshness_ms(),
                clock,
            )
    ) {
        let pyth_spot = pyth_spot.destroy_some();
        let spot = pyth_spot.read_value();
        assert!(spot <= max_pricing_spot!(), EPythSpotInvalid);
        // The re-anchored forward may exceed the input spot ceiling. The basis and
        // spot bounds still guarantee this multiplication and result fit in u64.
        forward = math::mul_div_down(spot, bs_forward, bs_spot);
    };

    Pricer {
        expiry_market_id,
        forward,
        svi,
        pyth_spot_source_timestamp_ms,
        block_scholes_spot_source_timestamp_ms,
        block_scholes_forward_source_timestamp_ms,
        block_scholes_svi_source_timestamp_ms,
    }
}

fun timestamp_is_fresh(source_timestamp_ms: u64, max_age_ms: u64, clock: &Clock): bool {
    let now = clock.timestamp_ms();
    source_timestamp_ms > 0 && source_timestamp_ms <= now && now - source_timestamp_ms <= max_age_ms
}

fun assert_inputs_pricing_safe(spot: u64, forward: u64, svi: &SVIParams) {
    assert!(spot > 0 && forward > 0, EBlockScholesInputsInvalid);
    assert!(forward <= max_pricing_spot!(), EBlockScholesInputsInvalid);
    // `ceil(forward / factor) <= spot` enforces `forward <= factor * spot`
    // without an overflowing multiplication.
    assert!(forward.div_ceil(max_pricing_basis_factor!()) <= spot, EBlockScholesInputsInvalid);
    assert!(svi.a().magnitude() <= max_svi_input!(), EBlockScholesInputsInvalid);
    assert!(svi.b() <= max_svi_input!(), EBlockScholesInputsInvalid);
    assert!(svi.rho().magnitude() <= math::float_scaling!(), EBlockScholesInputsInvalid);
    assert!(svi.m().magnitude() <= max_svi_input!(), EBlockScholesInputsInvalid);
    assert!(
        svi.sigma() >= min_svi_sigma!() && svi.sigma() <= max_svi_input!(),
        EBlockScholesInputsInvalid,
    );
    assert_min_total_variance_positive(svi);
}

fun assert_min_total_variance_positive(svi: &SVIParams) {
    let min_variance_increment = min_svi_variance_increment(svi);
    let a = svi.a();
    let min_total_var = i64::from_u64(min_variance_increment).add(&a);
    assert!(is_positive(&min_total_var), EBlockScholesMinVarianceInvalid);
}

// SVI total variance is `a + b * (rho*x + sqrt(x^2 + sigma^2))`, where
// `x = k - m`. This returns the smallest possible non-`a` part over all strikes:
// `b * sigma * sqrt(1 - rho^2)`, or 0 at the `|rho| == 1` boundary.
fun min_svi_variance_increment(svi: &SVIParams): u64 {
    let rho_mag = svi.rho().magnitude();
    if (rho_mag == math::float_scaling!()) return 0;

    let one_minus_rho_squared = math::float_scaling!() - math::mul(rho_mag, rho_mag);
    let sqrt_one_minus_rho_squared = math::sqrt(one_minus_rho_squared, math::float_scaling!());
    math::mul(svi.b(), math::mul(svi.sigma(), sqrt_one_minus_rho_squared))
}

/// Compute the approximated probability for `(lower, higher]`.
fun compute_range_price(svi: &SVIParams, forward: u64, lower: Strike, higher: Strike): Approx {
    assert!(lower.value() < higher.value(), EInvalidRange);

    let lower_up_price = compute_up_price(svi, forward, lower);
    let higher_up_price = compute_up_price(svi, forward, higher);
    // Fixed-point approximation or a non-monotone SVI surface can invert the
    // boundary prices; the range probability is floored at zero.
    lower_up_price.sub(&higher_up_price).clamp_nonnegative()
}

/// Compute the adjusted UP digital probability for `strike`.
fun compute_up_price(svi: &SVIParams, forward: u64, strike: Strike): Approx {
    if (strike.is_neg_inf()) {
        return approx::exact_u64(math::float_scaling!())
    };
    if (strike.is_pos_inf()) {
        return approx::exact_u64(0)
    };

    compute_nd2(svi, forward, strike.value())
}

/// Binary pricing from SVI total variance:
/// - k = ln(strike / forward)
/// - w(k) = a + b * (rho * (k - m) + sqrt((k - m)^2 + sigma^2))
/// - d2 = -((k + w(k) / 2) / sqrt(w(k)))
/// - price = N(d2) - phi(d2) * w'(k) / (2 * sqrt(w(k)))
fun compute_nd2(svi_params: &SVIParams, forward: u64, strike: u64): Approx {
    assert!(forward > 0, EZeroForward);

    // Saturate ratios outside the fixed-point domain to their digital-probability
    // limits instead of aborting live valuation and position flows. Tail limits are
    // exact (zero error).
    let strike_ratio_opt = math::try_mul_div_down(strike, math::float_scaling!(), forward);
    // Deep-OTM up tail (strike >> forward): P ≈ 0, the pos_inf limit.
    if (strike_ratio_opt.is_none()) return approx::exact_u64(0);
    let strike_ratio = strike_ratio_opt.destroy_some();
    // Deep-ITM up tail (strike << forward): P(settle > strike) ≈ 1, the neg_inf limit.
    if (strike_ratio == 0) return approx::exact_u64(math::float_scaling!());
    // `try_mul_div_down` floors the ratio by at most one raw unit.
    let k = approx::ln(strike_ratio, 1);
    let (k_minus_m, root) = moneyness_terms(svi_params, &k);
    let total_var = total_variance(svi_params, &k_minus_m, &root);
    let sqrt_var = approx::sqrt(&total_var);
    let d2 = standardized_d2(&k, &total_var, &sqrt_var);
    let w_prime = variance_slope(svi_params, &k_minus_m, &root);
    let scalar = digital_price(&d2, &w_prime, &sqrt_var);
    let error = certify_nd2_error(
        svi_params,
        &k,
        &k_minus_m,
        &root,
        &w_prime,
        scalar.magnitude(),
    );
    approx::from_parts(scalar.value(), error)
}

fun moneyness_terms(svi_params: &SVIParams, k: &Approx): (Approx, Approx) {
    let m = approx::exact(svi_params.m());
    let k_minus_m = k.sub(&m);
    let k_minus_m_squared = k_minus_m.square_scaled();
    let sigma = svi_params.sigma();
    let sigma_squared = approx::exact_u64(math::mul(sigma, sigma));
    let sqrt_input = k_minus_m_squared.add(&sigma_squared);
    let root = approx::sqrt(&sqrt_input);
    (k_minus_m, root)
}

fun total_variance(svi_params: &SVIParams, k_minus_m: &Approx, root: &Approx): Approx {
    let rho = approx::exact(svi_params.rho());
    let rho_km = rho.mul_scaled(k_minus_m);
    let inner = rho_km.add(root);
    // This term is non-negative for |rho| <= 1; abort if fixed-point evaluation
    // violates that invariant at the envelope boundary.
    assert!(!inner.is_negative(), ECannotBeNegative);

    let b = approx::exact_u64(svi_params.b());
    let variance_increment = b.mul_scaled(&inner);
    let a = approx::exact(svi_params.a());
    let total_var = variance_increment.add(&a);
    // Total variance must be positive because pricing takes sqrt(w) below.
    let total_var_center = total_var.value();
    assert!(is_positive(&total_var_center), ENonPositiveVariance);
    total_var
}

fun standardized_d2(k: &Approx, total_var: &Approx, sqrt_var: &Approx): Approx {
    let half_var = total_var.half();
    let d2_numerator = k.add(&half_var);
    d2_numerator.div_scaled(sqrt_var).neg()
}

fun variance_slope(svi_params: &SVIParams, k_minus_m: &Approx, root: &Approx): Approx {
    let rho = approx::exact(svi_params.rho());
    let slope_ratio = k_minus_m.div_scaled(root);
    let slope = rho.add(&slope_ratio);
    let b = approx::exact_u64(svi_params.b());
    b.mul_scaled(&slope)
}

fun digital_price(d2: &Approx, w_prime: &Approx, sqrt_var: &Approx): Approx {
    let nd2 = approx::normal_cdf(d2);
    // A zero slope is the flat-variance digital: no smile correction, N(d2) exactly.
    if (w_prime.magnitude() == 0) return nd2.clamp_unit_interval();

    // Smile correction phi(d2) * w'(k) / (2 sqrt(w)), carried signed so `sub` clamps
    // in the correct direction; N(d2) - correction is then floored/capped to [0, 1].
    let pdf = approx::normal_pdf(d2);
    let two_sqrt_var = sqrt_var.double();
    let correction = pdf.mul_div_down(w_prime, &two_sqrt_var);
    let adjusted = nd2.sub(&correction);
    adjusted.clamp_unit_interval()
}

/// Certify the scalar ND2 price through a precision island that retains SVI
/// variance at 1e18 until after its square root. The scalar computation above is
/// deliberately unchanged; this helper only bounds its distance from the formula.
fun certify_nd2_error(
    svi_params: &SVIParams,
    k: &Approx,
    k_minus_m: &Approx,
    root: &Approx,
    w_prime: &Approx,
    scalar_price: u64,
): u64 {
    let rho = approx::exact(svi_params.rho());
    let inner = rho.mul_scaled(k_minus_m).add(root);
    if (inner.is_negative()) return std::u64::max_value!();

    let scale = variance_scaling!();
    let increment = (svi_params.b() as u128) * (inner.magnitude() as u128);
    let increment_error = (svi_params.b() as u128) * (inner.error() as u128);
    let a = svi_params.a();
    let a_magnitude = (a.magnitude() as u128) * scale;
    let (variance, negative) = if (a.is_negative()) {
        if (increment >= a_magnitude) {
            (increment - a_magnitude, false)
        } else {
            (a_magnitude - increment, true)
        }
    } else {
        (increment + a_magnitude, false)
    };
    if (negative || variance <= increment_error) return std::u64::max_value!();

    let sqrt_variance = math::sqrt_u128(variance);
    let sqrt_lower = math::sqrt_u128(variance - increment_error);
    if (sqrt_lower == 0 || sqrt_variance > (std::u64::max_value!() as u128)) {
        return std::u64::max_value!()
    };
    let sqrt_upper = math::sqrt_u128(saturating_add_u128(variance, increment_error));
    let sqrt_error = if (sqrt_variance - sqrt_lower >= sqrt_upper - sqrt_variance) {
        sqrt_variance - sqrt_lower
    } else {
        sqrt_upper - sqrt_variance
    };

    let k_value = k.value();
    let k_magnitude = (k_value.magnitude() as u128) * scale;
    let half_variance = variance / 2;
    let (numerator, numerator_negative) = if (k_value.is_negative()) {
        if (half_variance >= k_magnitude) {
            (half_variance - k_magnitude, false)
        } else {
            (k_magnitude - half_variance, true)
        }
    } else {
        (half_variance + k_magnitude, false)
    };
    let k_error = (k.error() as u128) * scale;
    let numerator_error = saturating_add_u128(k_error, increment_error.div_ceil(2));
    let d2_magnitude = numerator / sqrt_variance;
    if (d2_magnitude > (std::u64::max_value!() as u128)) return std::u64::max_value!();
    let d2 = i64::from_parts(d2_magnitude as u64, !numerator_negative);
    let numerator_error_term = ceil_div_u128(numerator_error, sqrt_lower);
    let denominator_error_term = ceil_div_u128(
        ceil_mul_div_u128(saturating_add_u128(numerator, numerator_error), sqrt_error, sqrt_lower),
        sqrt_lower,
    );
    let d2_error = saturating_add_u128(
        saturating_add_u128(numerator_error_term, denominator_error_term),
        1,
    );
    if (d2_error > (std::u64::max_value!() as u128)) return std::u64::max_value!();
    let d2_error = d2_error as u64;

    let reference_cdf = math::normal_cdf(&d2);
    let pdf = math::normal_pdf(&d2);
    let nearest = d2_magnitude.saturating_sub(d2_error as u128);
    let (cdf_error, pdf_error) = if (nearest > 8 * (math::float_scaling!() as u128)) {
        // At |d2| > 8 the true CDF tail is below one raw price unit. The fixed
        // primitives' documented leaf bounds cover the residual tail rounding.
        (20, 50)
    } else {
        let pdf_upper = saturating_add(math::normal_pdf(&i64::from_u64(nearest as u64)), 50);
        (
            saturating_add(
                math::mul_div_up(pdf_upper, d2_error, math::float_scaling!()),
                20,
            ),
            saturating_add(
                math::mul_div_up(max_pdf_slope!(), d2_error, math::float_scaling!()),
                50,
            ),
        )
    };
    let (correction, correction_error) = smile_correction_certificate(
        w_prime,
        pdf,
        pdf_error,
        sqrt_lower,
        sqrt_variance,
        sqrt_upper,
    );
    let adjusted = i64::from_u64(reference_cdf).sub(&correction);
    let reference_price = if (adjusted.is_negative()) {
        0
    } else if (adjusted.magnitude() > math::float_scaling!()) {
        math::float_scaling!()
    } else {
        adjusted.magnitude()
    };
    let reference_error = saturating_add(cdf_error, correction_error);
    scalar_price.diff(reference_price).saturating_add(reference_error)
}

/// Build a center and radius for the SVI smile correction. The correction is
/// monotone in the absolute PDF and slope, and inverse-monotone in sqrt(w), so
/// evaluating those corners retains the tight central correction without losing
/// its sign to an absolute upper bound.
fun smile_correction_certificate(
    w_prime: &Approx,
    pdf: u64,
    pdf_error: u64,
    sqrt_lower: u128,
    sqrt_variance: u128,
    sqrt_upper: u128,
): (I64, u64) {
    if (
        sqrt_lower == 0
            || sqrt_upper > ((std::u64::max_value!() / 2) as u128)
            || sqrt_variance > ((std::u64::max_value!() / 2) as u128)
    ) return (i64::zero(), std::u64::max_value!());

    let slope = w_prime.magnitude();
    let correction = math::mul_div_down(pdf, slope, (sqrt_variance as u64) * 2);
    let correction = i64::from_parts(correction, w_prime.is_negative());
    let pdf_low = pdf.saturating_sub(pdf_error);
    let pdf_high = saturating_add(pdf, pdf_error);
    let slope_low = slope.saturating_sub(w_prime.error());
    let slope_high = saturating_add(slope, w_prime.error());
    let correction_low = math::mul_div_down(pdf_low, slope_low, (sqrt_upper as u64) * 2);
    let correction_high = math::mul_div_up(pdf_high, slope_high, (sqrt_lower as u64) * 2);
    let correction_error = if (w_prime.error() >= slope) {
        saturating_add(correction.magnitude(), correction_high)
    } else {
        correction
            .magnitude()
            .diff(correction_low)
            .max(correction_high.diff(correction.magnitude()))
    };
    (correction, correction_error)
}

fun ceil_div_u128(value: u128, divisor: u128): u128 {
    if (divisor == 0) return std::u128::max_value!();
    let quotient = value / divisor;
    if (value % divisor == 0) quotient else saturating_add_u128(quotient, 1)
}

fun ceil_mul_div_u128(a: u128, b: u128, divisor: u128): u128 {
    if (divisor == 0 || (b > 0 && a > std::u128::max_value!() / b)) {
        return std::u128::max_value!()
    };
    ceil_div_u128(a * b, divisor)
}

fun saturating_add_u128(a: u128, b: u128): u128 {
    let max = std::u128::max_value!();
    if (a > max - b) max else a + b
}

fun saturating_add(a: u64, b: u64): u64 {
    let max = std::u64::max_value!();
    if (a > max - b) max else a + b
}

fun is_positive(value: &I64): bool {
    !value.is_negative() && !value.is_zero()
}
