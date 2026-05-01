// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pricing configuration - dynamic fee parameters for Predict pricing.
module deepbook_predict::pricing_config;

use deepbook::math;
use deepbook_predict::{constants, i64::{Self, I64}, math as predict_math};

const EInvalidFee: u64 = 0;
const EFairPriceAlreadySettled: u64 = 1;
const EInvalidAskBound: u64 = 2;
const EInvalidTteBound: u64 = 3;
const EInvalidDepthMultiplier: u64 = 4;

/// Fee and ask-bound parameters used when quoting Predict markets.
/// The quoted fee is a per-unit absolute price increment, not a bps rate.
public struct PricingConfig has store {
    /// Base fee multiplier for Bernoulli scaling.
    /// Effective fee rate = base_fee * sqrt(price * (1 - price)).
    base_fee: u64,
    /// Minimum per-unit fee floor; live quotes never go below this value.
    min_fee: u64,
    /// Utilization multiplier in FLOAT_SCALING (e.g., 2_000_000_000 = 2x).
    /// Controls how aggressively fees increase as vault approaches capacity.
    utilization_multiplier: u64,
    /// Global minimum allowed all-in mint price after adding the fee.
    min_ask_price: u64,
    /// Global maximum allowed all-in mint price after adding the fee.
    max_ask_price: u64,
    /// Depth multiplier for the inventory-aware mid shift, in FLOAT_SCALING.
    /// `raw_ratio = aggregate · tte_factor / (balance · depth_multiplier)`,
    /// so lower values produce larger shifts from the same directional inventory.
    depth_multiplier: u64,
    /// Reference time-to-expiry for the inventory-aware mid shift.
    /// `tte_factor = √(reference_tte_ms / max(tte_ms, min_tte_ms))`, so
    /// `tte_factor == 1` exactly when `tte_ms == reference_tte_ms`.
    reference_tte_ms: u64,
    /// Minimum TTE floor used to cap near-expiry amplification of `tte_factor`.
    /// Once `tte_ms < min_tte_ms`, further time decay no longer amplifies the
    /// inventory shift.
    min_tte_ms: u64,
}

// === Public Functions ===

/// Return the base fee multiplier.
public fun base_fee(config: &PricingConfig): u64 {
    config.base_fee
}

/// Return the minimum per-unit fee floor.
public fun min_fee(config: &PricingConfig): u64 {
    config.min_fee
}

/// Return the utilization multiplier.
public fun utilization_multiplier(config: &PricingConfig): u64 {
    config.utilization_multiplier
}

/// Return the global minimum allowed all-in mint price.
public fun min_ask_price(config: &PricingConfig): u64 {
    config.min_ask_price
}

/// Return the global maximum allowed all-in mint price.
public fun max_ask_price(config: &PricingConfig): u64 {
    config.max_ask_price
}

/// Return the depth multiplier for the inventory-aware mid shift.
public fun depth_multiplier(config: &PricingConfig): u64 {
    config.depth_multiplier
}

/// Return the reference time-to-expiry for the inventory-aware mid shift.
public fun reference_tte_ms(config: &PricingConfig): u64 {
    config.reference_tte_ms
}

/// Return the minimum TTE floor for the inventory-aware mid shift.
public fun min_tte_ms(config: &PricingConfig): u64 {
    config.min_tte_ms
}

// === Public-Package Functions ===

/// Create pricing config seeded from protocol defaults.
public(package) fun new(): PricingConfig {
    PricingConfig {
        base_fee: constants::default_base_fee!(),
        min_fee: constants::default_min_fee!(),
        utilization_multiplier: constants::default_utilization_multiplier!(),
        min_ask_price: constants::default_min_ask_price!(),
        max_ask_price: constants::default_max_ask_price!(),
        depth_multiplier: constants::default_depth_multiplier!(),
        reference_tte_ms: constants::default_reference_tte_ms!(),
        min_tte_ms: constants::default_min_tte_ms!(),
    }
}

/// Set the base fee multiplier.
public(package) fun set_base_fee(config: &mut PricingConfig, fee: u64) {
    assert!(fee > 0 && fee <= constants::float_scaling!(), EInvalidFee);
    config.base_fee = fee;
}

/// Set the minimum fee floor.
public(package) fun set_min_fee(config: &mut PricingConfig, fee: u64) {
    assert!(fee <= constants::float_scaling!(), EInvalidFee);
    config.min_fee = fee;
}

/// Set the utilization multiplier.
public(package) fun set_utilization_multiplier(config: &mut PricingConfig, multiplier: u64) {
    config.utilization_multiplier = multiplier;
}

/// Set the global minimum allowed mint price.
public(package) fun set_min_ask_price(config: &mut PricingConfig, value: u64) {
    assert!(value < config.max_ask_price, EInvalidAskBound);
    config.min_ask_price = value;
}

/// Set the global maximum allowed mint price.
public(package) fun set_max_ask_price(config: &mut PricingConfig, value: u64) {
    assert!(value > config.min_ask_price, EInvalidAskBound);
    assert!(value < constants::float_scaling!(), EInvalidAskBound);
    config.max_ask_price = value;
}

/// Set the depth multiplier. Zero is rejected: silently disabling the
/// inventory shift via admin error is a defense-in-depth gap.
public(package) fun set_depth_multiplier(config: &mut PricingConfig, multiplier: u64) {
    assert!(multiplier > 0, EInvalidDepthMultiplier);
    config.depth_multiplier = multiplier;
}

/// Set the reference TTE. Must be at least the current `min_tte_ms` so the
/// invariant `min_tte_ms <= reference_tte_ms` is preserved.
public(package) fun set_reference_tte_ms(config: &mut PricingConfig, value: u64) {
    assert!(value >= config.min_tte_ms, EInvalidTteBound);
    config.reference_tte_ms = value;
}

/// Set the minimum TTE floor. Must be positive (zero would let `tte_factor`
/// amplification grow without bound) and not exceed the current
/// `reference_tte_ms`.
public(package) fun set_min_tte_ms(config: &mut PricingConfig, value: u64) {
    assert!(value > 0 && value <= config.reference_tte_ms, EInvalidTteBound);
    config.min_tte_ms = value;
}

/// Quote the dynamic per-unit fee rate for a live fair price.
///
/// Uses Bernoulli variance scaling plus utilization pressure. Settled prices
/// at exactly 0 or 1 are rejected because no live fee should be applied.
public(package) fun quote_fee_rate_from_fair_price(
    config: &PricingConfig,
    fair_price: u64,
    liability: u64,
    balance: u64,
): u64 {
    assert!(fair_price > 0 && fair_price < constants::float_scaling!(), EFairPriceAlreadySettled);
    let complement = constants::float_scaling!() - fair_price;
    let variance = math::mul(fair_price, complement);
    let bernoulli_factor = predict_math::sqrt(variance, constants::float_scaling!());
    let bernoulli_fee = math::mul(config.base_fee, bernoulli_factor);
    let fee =
        bernoulli_fee.max(config.min_fee)
        + utilization_fee(config, liability, balance);

    fee
}

/// Post-shift `(mint_price, redeem_price)` for the range `(L, H]` whose
/// per-strike UP probabilities are `p_up_lower = p_up(L)` and
/// `p_up_higher = p_up(H)`, and whose unshifted fair is
/// `fair_range = p_up_lower - p_up_higher`.
///
/// Both boundaries are shifted independently by `shifted_up_strike_mid`
/// using the same oracle-level `aggregate`. The range mid is then
/// `m(L) - m(H)`, preserving the binary invariant
/// `mint_up + mint_dn == FS + 2·spread` and
/// `redeem_up + redeem_dn == FS - 2·spread` for any aggregate sign:
/// shifting UP up by Δ shifts DN down by Δ, since DN's mid is
/// `m(neg_inf) - m(K) = FS - m(K)`.
///
/// No zero-edge floor: under heavy imbalance the LP intentionally takes a
/// worse-than-fair fill on rebalancing trades — `mint < fair_range` on the
/// side the vault wants to grow, `redeem > fair_range` on the side the
/// vault wants to shrink. The only clamps are `[0, FS]` on the resulting
/// prices.
public(package) fun compute_range_quote(
    config: &PricingConfig,
    fair_range: u64,
    p_up_lower: u64,
    p_up_higher: u64,
    aggregate: &I64,
    liability: u64,
    balance: u64,
    tte_ms: u64,
): (u64, u64) {
    let fee = config.quote_fee_rate_from_fair_price(fair_range, liability, balance);
    let m_lower = shifted_up_strike_mid(
        p_up_lower,
        aggregate,
        balance,
        tte_ms,
        config.depth_multiplier,
        config.reference_tte_ms,
        config.min_tte_ms,
    );
    let m_higher = shifted_up_strike_mid(
        p_up_higher,
        aggregate,
        balance,
        tte_ms,
        config.depth_multiplier,
        config.reference_tte_ms,
        config.min_tte_ms,
    );
    // Both boundaries use the same oracle-level ratio, and `shifted_up_strike_mid`
    // is monotonically non-decreasing in `p_up`, so `m_lower >= m_higher`
    // whenever `p_up_lower >= p_up_higher`. Caller-side invariant; no abort
    // because the strike-matrix range invariant `lower < higher` and SVI
    // monotonicity guarantee it.
    let shifted_mid = m_lower - m_higher;

    let fs = constants::float_scaling!();
    let mint_price = (shifted_mid + fee).min(fs);
    let redeem_price = if (shifted_mid > fee) {
        shifted_mid - fee
    } else {
        0
    };

    (mint_price, redeem_price)
}

// === Private Functions ===

/// Compute fee pressure from current liability utilization.
fun utilization_fee(config: &PricingConfig, liability: u64, balance: u64): u64 {
    if (balance == 0 || liability == 0) return 0;

    // Cap utilization at 1.0 and square it so fees stay mild at low usage
    // and widens sharply only as the vault approaches full utilization.
    let util = if (liability >= balance) {
        constants::float_scaling!()
    } else {
        math::div(liability, balance)
    };
    let util_sq = math::mul(util, util);
    math::mul(
        config.base_fee,
        math::mul(config.utilization_multiplier, util_sq),
    )
}

/// Inventory-shifted UP probability at a single strike, in FLOAT_SCALING.
/// Operates on a per-strike `p_up`, not on a range fair: `compute_range_quote`
/// shifts each boundary independently and takes the difference.
///
/// Sentinel boundaries (`p_up == 0` for `+∞` or `p_up == FS` for `−∞`) are
/// inert: the range never has positions at infinity, so the directional
/// aggregate's accounting at sentinel weight `0` must be matched by leaving
/// the boundary mid at the sentinel value. Without this short-circuit, a
/// positive `ratio` at `p_up = 0` would produce `m = ratio · FS` (room is the
/// full `[0,1]`), breaking the symmetry and the `UP+DN=$1` invariant.
///
/// Otherwise the shift is
/// `clamp(aggregate · tte_factor / (balance · depth_multiplier), −1, +1)`
/// scaled by `room(p_up)`: `(1 − p_up)` for a positive ratio (push mid up)
/// or `p_up` for a negative ratio (push mid down). Result is in `[0, FS]`.
fun shifted_up_strike_mid(
    p_up: u64,
    aggregate: &I64,
    balance: u64,
    tte_ms: u64,
    depth_multiplier: u64,
    reference_tte_ms: u64,
    min_tte_ms: u64,
): u64 {
    let fs = constants::float_scaling!();
    if (p_up == 0 || p_up == fs) return p_up;
    if (aggregate.is_zero() || balance == 0 || depth_multiplier == 0) return p_up;

    let clamped_tte = tte_ms.max(min_tte_ms);
    let tte_ratio = predict_math::mul_div_round_down(reference_tte_ms, fs, clamped_tte);
    let tte_factor = predict_math::sqrt(tte_ratio, fs);

    let denominator = math::mul(balance, depth_multiplier);
    if (denominator == 0) return p_up;

    let num = aggregate.mul_scaled(&i64::from_u64(tte_factor));
    let ratio = num.div_scaled(&i64::from_u64(denominator));
    let ratio_mag = ratio.magnitude().min(fs);
    if (ratio_mag == 0) return p_up;

    let ratio_negative = ratio.is_negative();
    let room = if (ratio_negative) p_up else fs - p_up;
    let shift = math::mul(ratio_mag, room);

    if (ratio_negative) {
        p_up - shift
    } else {
        p_up + shift
    }
}

#[test_only]
public fun destroy_for_testing(config: PricingConfig) {
    let PricingConfig {
        base_fee: _,
        min_fee: _,
        utilization_multiplier: _,
        min_ask_price: _,
        max_ask_price: _,
        depth_multiplier: _,
        reference_tte_ms: _,
        min_tte_ms: _,
    } = config;
}
