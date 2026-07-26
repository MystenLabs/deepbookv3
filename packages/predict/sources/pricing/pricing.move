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

use deepbook_predict::{
    certified::{Self, Certified},
    constants,
    pricing_config::PricingConfig,
    range_codec::{Self, Strike}
};
use fixed_math::{i64::{Self, I64}, math};
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
    prices: vector<Certified>,
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
const EPriceTooImprecise: u64 = 18;

/// Ceiling on how far an admitted contract price may sit from its true value,
/// relative, 1e9-scaled. An uncertain entry price transfers real value between the
/// trader and the pool, so mint refuses the quote rather than admit one.
macro fun max_contract_price_deviation(): u64 { 1_000_000 }

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

// Leaf approximation error of each `math` primitive consumed by the certified
// kernel, in raw 1e9 units, taken from the primitive's documented accuracy.
macro fun cdf_leaf(): u64 { 20 }

macro fun pdf_leaf(): u64 { 50 }

macro fun sqrt_leaf(): u64 { 1 }

// `mul_down`/`div_down`, the scaled `i64` ops, and a floored quotient each carry at
// most one raw unit of rounding.
macro fun round_leaf(): u64 { 1 }

// Global bound on `|phi'(x)| = |x| * phi(x)`, maximized at `|x| = 1`
// (`phi(1) = 0.241971`), rounded up. Bounds `normal_pdf`'s sensitivity to its input.
macro fun max_pdf_slope(): u64 { 242_000_000 }

// === Public Functions ===

/// Return the current UP digital probability for a typed strike. Public PTB and
/// devInspect reads can compose it with a transaction-local `Pricer`.
public fun up_price(pricer: &Pricer, strike: Strike): u64 {
    compute_up_price_center(&pricer.svi, pricer.forward, strike)
}

/// Return the current probability for `(lower, higher]`, floored at zero if the
/// two approximated boundary probabilities invert.
public fun range_price(pricer: &Pricer, lower: Strike, higher: Strike): u64 {
    compute_range_price_center(&pricer.svi, pricer.forward, lower, higher)
}

// === Public-Package Functions ===

/// Return the probability for `(lower, higher]`, admitted only if this module can
/// certify it to within `max_contract_price_deviation`. Producing the price and
/// bounding its numerical error are one computation, so the bound is enforced here
/// rather than handed to a caller as a certificate to re-check. Callers receive a
/// price they may act on or no price at all.
public(package) fun admitted_range_price(pricer: &Pricer, lower: Strike, higher: Strike): u64 {
    assert!(lower.value() < higher.value(), EInvalidRange);

    let lower_up_price = up_price_certified(&pricer.svi, pricer.forward, lower);
    let higher_up_price = up_price_certified(&pricer.svi, pricer.forward, higher);
    // The two boundaries come from independent kernel runs, so approximation or a
    // non-monotone surface can invert them; the range probability floors at zero.
    let price = certified::new(
        lower_up_price.value().saturating_sub(higher_up_price.value()),
        lower_up_price.error().saturating_add(higher_up_price.error()),
    );
    assert!(price.relative_deviation_within(max_contract_price_deviation!()), EPriceTooImprecise);
    price.value()
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

/// Read the cached range price `up_price(lower) - up_price(higher)` for one valid
/// order tick range, mirroring `range_price`'s infinity sentinels. The memo's
/// monotone centers make the subtraction exact. Both finite boundaries must have
/// been cached by the linear walk; a finite miss aborts (the order's tick is not a
/// payout-tree node — a broken index, not dust).
public(package) fun cached_range_price(
    memo: &PriceMemo,
    lower_tick: u64,
    higher_tick: u64,
): Certified {
    assert!(lower_tick < higher_tick, EInvalidRange);
    let lower = memo.cached_up_price(lower_tick);
    let higher = memo.cached_up_price(higher_tick);
    // The memo is non-increasing in tick and its sentinels bracket every price, so
    // this subtraction cannot underflow; the VM abort is a free invariant check.
    certified::new(lower.value() - higher.value(), lower.error().saturating_add(higher.error()))
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
): Certified {
    let price = up_price_certified(
        &pricer.svi,
        pricer.forward,
        range_codec::strike_from_tick(tick, tick_size),
    );
    if (!memo.prices.is_empty()) {
        let previous = memo.prices[memo.prices.length() - 1];
        // Higher strikes should not have higher UP prices. NAV's linear tree walk
        // relies on that order; an inverted surface can overstate pool value.
        assert!(price.value() <= previous.value(), ENonMonotonePriceMemo);
    };
    memo.ticks.push_back(tick);
    memo.prices.push_back(price);
    price
}

// === Private Functions ===

/// Look up a boundary tick's cached UP price. Infinity boundaries are never tree
/// nodes, so they short-circuit to `compute_up_price_approx`'s sentinels (`P(-inf) = 1`,
/// `P(+inf) = 0`); every finite tick must be present or the exposure index is broken.
fun cached_up_price(memo: &PriceMemo, tick: u64): Certified {
    if (tick == 0) return certified::exact(math::float_scaling!()); // neg-inf sentinel
    if (tick == constants::pos_inf_tick!()) return certified::exact(0);

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
    // `b` is SVI's wing slope and is strictly positive on any published surface: a
    // zero slope is a flat total variance with no smile at all. Requiring it here
    // rather than tolerating it downstream keeps the certified kernel's slope
    // radius strictly positive, which is what makes its zero-slope shortcut
    // unrepresentable instead of merely untaken.
    assert!(svi.b() > 0 && svi.b() <= max_svi_input!(), EBlockScholesInputsInvalid);
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
    assert!(
        !min_total_var.is_negative() && !min_total_var.is_zero(),
        EBlockScholesMinVarianceInvalid,
    );
}

// SVI total variance is `a + b * (rho*x + sqrt(x^2 + sigma^2))`, where
// `x = k - m`. This returns the smallest possible non-`a` part over all strikes:
// `b * sigma * sqrt(1 - rho^2)`, or 0 at the `|rho| == 1` boundary.
fun min_svi_variance_increment(svi: &SVIParams): u64 {
    let rho_mag = svi.rho().magnitude();
    if (rho_mag == math::float_scaling!()) return 0;

    let one_minus_rho_squared = math::float_scaling!() - math::mul_down(rho_mag, rho_mag);
    let sqrt_one_minus_rho_squared = math::sqrt_down(one_minus_rho_squared);
    math::mul_down(svi.b(), math::mul_down(svi.sigma(), sqrt_one_minus_rho_squared))
}

/// Compute only the canonical scalar center for `(lower, higher]`. Live close
/// and liquidation deliberately consume this center without a numerical-error
/// policy branch, so constructing and discarding the certificate would add
/// candidate-linear gas to every ambient sweep.
fun compute_range_price_center(svi: &SVIParams, forward: u64, lower: Strike, higher: Strike): u64 {
    assert!(lower.value() < higher.value(), EInvalidRange);

    let lower_up_price = compute_up_price_center(svi, forward, lower);
    let higher_up_price = compute_up_price_center(svi, forward, higher);
    // Fixed-point approximation or a non-monotone SVI surface can invert the
    // boundary prices; the range probability is floored at zero.
    lower_up_price.saturating_sub(higher_up_price)
}

/// Compute the canonical scalar center of the adjusted UP digital probability.
/// Theorem 2.7 in `docs/design/math-proofs.md` proves this is bit-identical to
/// `compute_up_price_approx(...).magnitude()`.
fun compute_up_price_center(svi_params: &SVIParams, forward: u64, strike: Strike): u64 {
    if (strike.is_neg_inf()) {
        return math::float_scaling!()
    };
    if (strike.is_pos_inf()) {
        return 0
    };

    assert!(forward > 0, EZeroForward);

    let k = ln_ratio_center(strike.value(), forward);
    let m = svi_params.m();
    let k_minus_m = k.sub(&m);
    let k_minus_m_squared = k_minus_m.square_scaled();
    let sigma_squared = math::mul_down(svi_params.sigma(), svi_params.sigma());
    let root = math::sqrt_down(k_minus_m_squared + sigma_squared);
    let root_i64 = i64::from_u64(root);

    let rho = svi_params.rho();
    let inner = rho.mul_scaled(&k_minus_m).add(&root_i64);
    assert!(!inner.is_negative(), ECannotBeNegative);

    let scale = math::float_scaling!() as u128;
    let wide_increment = (svi_params.b() as u128) * (inner.magnitude() as u128);
    let a = svi_params.a();
    let wide_a = (a.magnitude() as u128) * scale;
    let wide_total_var = if (a.is_negative()) {
        assert!(wide_increment >= wide_a, ENonPositiveVariance);
        wide_increment - wide_a
    } else {
        wide_increment + wide_a
    };
    assert!(wide_total_var >= scale, ENonPositiveVariance);

    let half_var = i64::from_u64((wide_total_var / (scale + scale)) as u64);
    let sqrt_var = math::sqrt_u128_down(wide_total_var) as u64;
    let sqrt_var_i64 = i64::from_u64(sqrt_var);
    let d2 = k.add(&half_var).div_scaled(&sqrt_var_i64).neg();

    let slope_ratio = k_minus_m.div_scaled(&root_i64);
    let slope = rho.add(&slope_ratio);
    let w_prime = i64::from_u64(svi_params.b()).mul_scaled(&slope);
    let nd2 = math::normal_cdf(&d2);
    if (w_prime.is_zero()) return nd2;

    let correction_magnitude = math::mul_div_down(
        math::normal_pdf(&d2),
        w_prime.magnitude(),
        sqrt_var + sqrt_var,
    );
    let correction = i64::from_parts(correction_magnitude, w_prime.is_negative());
    let adjusted = i64::from_u64(nd2).sub(&correction);
    if (adjusted.is_negative()) return 0;
    adjusted.magnitude().min(math::float_scaling!())
}

/// Center of `certified_ln_ratio` without constructing its discarded radius.
fun ln_ratio_center(numerator: u64, denominator: u64): I64 {
    let ratio_opt = math::try_div_down(numerator, denominator);
    if (ratio_opt.is_some()) {
        let ratio = ratio_opt.destroy_some();
        if (ratio > 1) return math::ln(ratio)
    };

    math::ln(numerator).sub(&math::ln(denominator))
}

/// Compute the adjusted UP digital probability together with the certified error
/// radius of that same evaluation. Value and radius are produced side by side:
/// each fixed-point step is immediately followed by the propagation bounding its
/// distance from the true real-valued quantity, so the certificate reads against
/// the arithmetic it certifies.
///
/// Leaf error comes from each `math` primitive's documented accuracy; continuous
/// propagation uses derivative bounds or endpoint evaluation. Every error term
/// rounds UP and saturates at `u64::MAX` rather than overflowing, so an input
/// domain this arithmetic cannot certify surfaces as an unusable radius that every
/// downstream precision gate rejects, never as a wrong one.
///
/// Binary pricing from SVI total variance:
/// - k = ln(strike / forward)
/// - w(k) = a + b * (rho * (k - m) + sqrt((k - m)^2 + sigma^2))
/// - d2 = -((k + w(k) / 2) / sqrt(w(k)))
/// - price = N(d2) - phi(d2) * w'(k) / (2 * sqrt(w(k)))
fun up_price_certified(svi_params: &SVIParams, forward: u64, strike: Strike): Certified {
    if (strike.is_neg_inf()) {
        return certified::exact(math::float_scaling!())
    };
    if (strike.is_pos_inf()) {
        return certified::exact(0)
    };

    assert!(forward > 0, EZeroForward);

    // k = ln(strike / forward).
    let (k, k_error) = certified_ln_ratio(strike.value(), forward);

    // x = k - m. The stored SVI parameter is exact, so the radius carries over.
    let m = svi_params.m();
    let x = k.sub(&m);
    let x_error = k_error;

    // root = sqrt(x^2 + sigma^2). The square propagates via `d(x^2) = 2|x| dx + dx^2`;
    // exact sigma contributes only its own rounding unit.
    let cross = ceil_mul(x.magnitude(), x_error);
    let sqrt_input = x.square_scaled() + math::mul_down(svi_params.sigma(), svi_params.sigma());
    let sqrt_input_error = cross
        .saturating_add(cross)
        .saturating_add(ceil_mul(x_error, x_error))
        .saturating_add(round_leaf!())
        .saturating_add(round_leaf!());
    // `sqrt` is monotone, so the true root is enclosed by the roots of the input
    // endpoints; the radius is the larger endpoint deviation plus `sqrt_down`'s own
    // rounding. The upper endpoint is evaluated in u128 because `x + dx` may exceed
    // u64 even though its scaled root always fits.
    let root_center = math::sqrt_down(sqrt_input);
    let root_low = if (sqrt_input > sqrt_input_error) {
        math::sqrt_down(sqrt_input - sqrt_input_error)
    } else {
        0
    };
    let root_high =
        math::sqrt_u128_down(
            ((sqrt_input as u128) + (sqrt_input_error as u128)) * (math::float_scaling!() as u128),
        ) as u64;
    let root = i64::from_u64(root_center);
    let root_error = (root_center - root_low).max(root_high - root_center) + sqrt_leaf!();

    // inner = rho * x + root. Exact rho keeps only the `|rho| dx` product term;
    // either zero is absorbing.
    let rho = svi_params.rho();
    let (scaled_x, scaled_x_error) = if (rho.is_zero() || (x.is_zero() && x_error == 0)) {
        (i64::zero(), 0)
    } else {
        (x.mul_scaled(&rho), ceil_mul(rho.magnitude(), x_error).saturating_add(round_leaf!()))
    };
    let inner = scaled_x.add(&root);
    let inner_error = scaled_x_error.saturating_add(root_error);
    // This term is non-negative for |rho| <= 1; abort if fixed-point evaluation
    // violates that invariant at the envelope boundary.
    assert!(!inner.is_negative(), ECannotBeNegative);

    // Keep `b * inner + a` at 1e18 until both downstream projections. For the
    // d2 numerator, floor(floor(wide / 1e9) / 2) = floor(wide / 2e9), so construct
    // w / 2 directly without narrowing to a discarded total-variance value.
    let scale = math::float_scaling!() as u128;
    let wide_increment = (svi_params.b() as u128) * (inner.magnitude() as u128);
    let a = svi_params.a();
    let wide_a = (a.magnitude() as u128) * scale;
    let wide_total_var = if (a.is_negative()) {
        assert!(wide_increment >= wide_a, ENonPositiveVariance);
        wide_increment - wide_a
    } else {
        wide_increment + wide_a
    };
    assert!(wide_total_var >= scale, ENonPositiveVariance);

    let wide_error = (svi_params.b() as u128) * (inner_error as u128);
    let half_scale = scale + scale;
    let half_var = i64::from_u64((wide_total_var / half_scale) as u64);
    let scaled_error = wide_error.div_ceil(half_scale);
    let max_error = std::u64::max_value!() as u128;
    let half_var_error = if (scaled_error >= max_error) {
        std::u64::max_value!()
    } else {
        (scaled_error as u64) + 1
    };

    let sqrt_center = math::sqrt_u128_down(wide_total_var);
    let sqrt_low = if (wide_total_var > wide_error) {
        math::sqrt_u128_down(wide_total_var - wide_error)
    } else {
        0
    };
    let sqrt_high = math::sqrt_u128_up(wide_total_var + wide_error);
    let sqrt_var = i64::from_u64(sqrt_center as u64);
    let sqrt_var_error = ((sqrt_center - sqrt_low).max(sqrt_high - sqrt_center)) as u64;

    // d2 = -((k + w / 2) / sqrt(w)).
    let d2_numerator = k.add(&half_var);
    let (d2_magnitude, d2_error) = certified_div(
        &d2_numerator,
        k_error.saturating_add(half_var_error),
        &sqrt_var,
        sqrt_var_error,
    );
    let d2 = d2_magnitude.neg();

    // w'(k) = b * (rho + x / root), with exact rho and b.
    let (slope_ratio, slope_ratio_error) = certified_div(&x, x_error, &root, root_error);
    let slope = rho.add(&slope_ratio);
    // Neither zero is reachable here, so the product needs no absorbing branch:
    // `b > 0` is an admission requirement, and `certified_div` always returns a
    // radius of at least one raw unit, so the slope is never a certified exact zero.
    let b = i64::from_u64(svi_params.b());
    let w_prime = slope.mul_scaled(&b);
    let w_prime_error = ceil_mul(b.magnitude(), slope_ratio_error).saturating_add(round_leaf!());

    // N(d2). `Phi' = phi`, maximized over the ball at the point nearest zero; the
    // PDF primitive's own error is added before using it as an upper derivative
    // bound, then `phi_upper * dx` is rounded up and the CDF leaf error added.
    let nd2 = math::normal_cdf(&d2);
    let d2_magnitude = d2.magnitude();
    let nearest = if (d2_magnitude > d2_error) {
        i64::from_u64(d2_magnitude - d2_error)
    } else {
        i64::zero()
    };
    let sup_phi = math::normal_pdf(&nearest).saturating_add(pdf_leaf!());
    let nd2_error = ceil_mul(sup_phi, d2_error).saturating_add(cdf_leaf!());

    // Every admitted surface carries a possible correction: the slope's radius is
    // strictly positive, so even a slope that rounds to zero flows through the
    // quotient below rather than short-circuiting to N(d2). The scalar kernel does
    // short-circuit on a zero slope center, and the two still agree — a zero center
    // makes `mul_div_down`'s product zero, so the subtraction is a no-op.

    // Smile correction phi(d2) * w'(k) / (2 sqrt(w)), carried signed so the
    // subtraction moves in the correct direction. `|phi'|` is bounded globally by
    // `max_pdf_slope`, so `max_pdf_slope * dx` bounds phi's propagated error.
    let pdf = math::normal_pdf(&d2);
    let pdf_error = ceil_mul(max_pdf_slope!(), d2_error).saturating_add(pdf_leaf!());
    let two_sqrt_var = sqrt_var.add(&sqrt_var);
    let (correction, correction_error) = certified_smile_correction(
        pdf,
        pdf_error,
        &w_prime,
        w_prime_error,
        &two_sqrt_var,
        sqrt_var_error.saturating_add(sqrt_var_error),
    );

    // N(d2) - correction, floored then capped to [0, 1]. Both projections are
    // 1-Lipschitz, so each retains the radius even on its clamped branch.
    let adjusted = i64::from_u64(nd2).sub(&correction);
    let value = if (adjusted.is_negative()) {
        0
    } else {
        adjusted.magnitude().min(math::float_scaling!())
    };
    certified::new(value, nd2_error.saturating_add(correction_error))
}

/// `ln(numerator / denominator)` for exact positive inputs, with its radius. The
/// ordinary 1e9 quotient path certifies one raw unit of quotient rounding; ratios
/// whose floored quotient cannot keep a positive lower corner instead subtract two
/// certified logarithms, so every finite ratio remains finite.
fun certified_ln_ratio(numerator: u64, denominator: u64): (I64, u64) {
    let ratio_opt = math::try_div_down(numerator, denominator);
    if (ratio_opt.is_some()) {
        let ratio = ratio_opt.destroy_some();
        if (ratio > 1) return certified_ln(ratio, round_leaf!())
    };

    let (numerator_log, numerator_error) = certified_ln(numerator, 0);
    let (denominator_log, denominator_error) = certified_ln(denominator, 0);
    // Subtraction cannot cancel uncertainty, so the absolute errors add.
    (numerator_log.sub(&denominator_log), numerator_error.saturating_add(denominator_error))
}

/// `ln` of a positive value carrying radius `x_error`. Error is the worst-corner
/// `1 / x` derivative bound `dx / (x - dx)`, rounded up, plus `ln`'s approximation
/// error: `1e-7` relative plus a three-raw-unit margin covering the near-`ln(1)`
/// quantization regime. Callers reach the propagation only after `math::ln` has
/// established `x > 0`, and both supplied radii keep the lower endpoint positive.
fun certified_ln(x: u64, x_error: u64): (I64, u64) {
    let value = math::ln(x);
    let leaf = value.magnitude() / 10_000_000 + 3;
    (value, ceil_div(x_error, x - x_error).saturating_add(leaf))
}

/// Scaled quotient with the quotient rule taken at the worst denominator corner
/// `|b| - db`. The `|a| db / b^2` term is computed division-first (`ceil(|a| db / b)`
/// then `/ b`) so a small numerator cannot underflow it to zero. The center is
/// evaluated first and aborts when the denominator center is zero; a nonzero center
/// whose ball can reach zero saturates so any downstream gate rejects it.
fun certified_div(a: &I64, a_error: u64, b: &I64, b_error: u64): (I64, u64) {
    let value = a.div_scaled(b);
    let magnitude = b.magnitude();
    if (magnitude <= b_error) {
        return (value, std::u64::max_value!())
    };
    let denominator = magnitude - b_error;
    let numerator_term = ceil_div(a_error, denominator);
    let denominator_term = ceil_div(
        ceil_mul_div(a.magnitude(), b_error, denominator),
        denominator,
    );
    (value, numerator_term.saturating_add(denominator_term).saturating_add(round_leaf!()))
}

/// The smile correction `phi * w' / (2 sqrt(w))`. The center matches
/// `math::mul_div_down`'s single floor so the scalar kernel stays bit-identical.
/// The radius is exact outward corner evaluation, not a linearization: `phi` and
/// `2 sqrt(w)` are nonnegative, so the result carries `w'`'s sign and — while both
/// numerator factors keep their signs — its magnitude lies in
/// `[(phi-dphi)(|w'|-dw)/(D+dD), (phi+dphi)(|w'|+dw)/(D-dD)]`. Otherwise the
/// numerator may cross zero and either output sign must be covered. A denominator
/// ball reaching zero, or an endpoint outside the u64 error domain, saturates.
fun certified_smile_correction(
    pdf: u64,
    pdf_error: u64,
    w_prime: &I64,
    w_prime_error: u64,
    denominator: &I64,
    denominator_error: u64,
): (I64, u64) {
    let slope_magnitude = w_prime.magnitude();
    let denominator_magnitude = denominator.magnitude();
    let center = math::mul_div_down(pdf, slope_magnitude, denominator_magnitude);
    let value = i64::from_parts(center, w_prime.is_negative());
    let max = std::u64::max_value!();
    if (denominator_magnitude <= denominator_error) {
        return (value, max)
    };
    if (pdf > max - pdf_error || slope_magnitude > max - w_prime_error) {
        return (value, max)
    };

    let upper = ceil_mul_div(
        pdf + pdf_error,
        slope_magnitude + w_prime_error,
        denominator_magnitude - denominator_error,
    );
    if (upper == max) {
        return (value, max)
    };
    if (pdf > pdf_error && slope_magnitude > w_prime_error) {
        let lower = if (denominator_magnitude > max - denominator_error) {
            0
        } else {
            math::mul_div_down(
                pdf - pdf_error,
                slope_magnitude - w_prime_error,
                denominator_magnitude + denominator_error,
            )
        };
        let upper_distance = if (upper > center) upper - center else 0;
        (value, (center - lower).max(upper_distance))
    } else {
        // Crossing either numerator factor through zero can reverse the quotient's
        // sign relative to the canonical center, so the farthest endpoint is the
        // sum of their magnitudes.
        (value, center.saturating_add(upper))
    }
}

/// `ceil(x * y / 1e9)`, saturating to `u64::MAX`. Scaled error products round up.
fun ceil_mul(x: u64, y: u64): u64 {
    ceil_mul_div(x, y, math::float_scaling!())
}

/// `ceil(x * 1e9 / y)`, saturating to `u64::MAX`. Scaled error quotients round up.
fun ceil_div(x: u64, y: u64): u64 {
    ceil_mul_div(x, math::float_scaling!(), y)
}

/// `ceil(x * y / d)`, saturating to `u64::MAX` when the denominator is zero or
/// the result does not fit in `u64`.
fun ceil_mul_div(x: u64, y: u64, d: u64): u64 {
    math::try_mul_div_up(x, y, d).destroy_or!(std::u64::max_value!())
}
