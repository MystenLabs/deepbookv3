// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pricing configuration - spread parameters for binary option pricing.
module deepbook_predict::pricing_config;

use deepbook::math;
use deepbook_predict::{constants, i64::{Self, I64}, math as predict_math};

// === Errors ===
const EInvalidSpread: u64 = 0;
const EFairPriceAlreadySettled: u64 = 1;
const EInvalidAskBound: u64 = 2;
const EInvalidTteBound: u64 = 3;

// === Structs ===

public struct PricingConfig has store {
    /// Base spread multiplier for Bernoulli scaling.
    /// Effective spread = base_spread * √(price * (1 - price))
    base_spread: u64,
    /// Minimum spread floor — spread never goes below this value
    min_spread: u64,
    /// Utilization multiplier in FLOAT_SCALING (e.g., 2_000_000_000 = 2x).
    /// Controls how aggressively spread widens as vault approaches capacity.
    utilization_multiplier: u64,
    /// Global minimum allowed post-spread ask price at mint time.
    min_ask_price: u64,
    /// Global maximum allowed post-spread ask price at mint time.
    max_ask_price: u64,
    /// Depth multiplier for the inventory-aware mid shift, in FLOAT_SCALING.
    /// `raw_ratio = aggregate · tte_factor / (balance · depth_multiplier)`, so
    /// lower values make the shift respond more aggressively to a given
    /// directional inventory.
    depth_multiplier: u64,
    /// Reference time-to-expiry for the inventory-aware mid shift.
    /// `tte_factor = √(reference_tte_ms / max(tte_ms, min_tte_ms))`, so
    /// `tte_factor == 1` when `tte_ms == reference_tte_ms`.
    reference_tte_ms: u64,
    /// Minimum TTE floor used to cap near-expiry amplification of `tte_factor`.
    /// Once `tte_ms < min_tte_ms`, further time decay stops increasing the shift.
    min_tte_ms: u64,
}

// === Public Functions ===

public fun base_spread(config: &PricingConfig): u64 {
    config.base_spread
}

public fun min_spread(config: &PricingConfig): u64 {
    config.min_spread
}

public fun utilization_multiplier(config: &PricingConfig): u64 {
    config.utilization_multiplier
}

public fun min_ask_price(config: &PricingConfig): u64 {
    config.min_ask_price
}

public fun max_ask_price(config: &PricingConfig): u64 {
    config.max_ask_price
}

public fun depth_multiplier(config: &PricingConfig): u64 {
    config.depth_multiplier
}

public fun reference_tte_ms(config: &PricingConfig): u64 {
    config.reference_tte_ms
}

public fun min_tte_ms(config: &PricingConfig): u64 {
    config.min_tte_ms
}

// === Public-Package Functions ===

public(package) fun new(): PricingConfig {
    PricingConfig {
        base_spread: constants::default_base_spread!(),
        min_spread: constants::default_min_spread!(),
        utilization_multiplier: constants::default_utilization_multiplier!(),
        min_ask_price: constants::default_min_ask_price!(),
        max_ask_price: constants::default_max_ask_price!(),
        depth_multiplier: constants::default_depth_multiplier!(),
        reference_tte_ms: constants::default_reference_tte_ms!(),
        min_tte_ms: constants::default_min_tte_ms!(),
    }
}

public(package) fun set_base_spread(config: &mut PricingConfig, spread: u64) {
    assert!(spread > 0 && spread <= constants::float_scaling!(), EInvalidSpread);
    config.base_spread = spread;
}

public(package) fun set_min_spread(config: &mut PricingConfig, spread: u64) {
    assert!(spread <= constants::float_scaling!(), EInvalidSpread);
    config.min_spread = spread;
}

public(package) fun set_utilization_multiplier(config: &mut PricingConfig, multiplier: u64) {
    config.utilization_multiplier = multiplier;
}

public(package) fun set_min_ask_price(config: &mut PricingConfig, value: u64) {
    assert!(value < config.max_ask_price, EInvalidAskBound);
    config.min_ask_price = value;
}

public(package) fun set_max_ask_price(config: &mut PricingConfig, value: u64) {
    assert!(value > config.min_ask_price, EInvalidAskBound);
    assert!(value < constants::float_scaling!(), EInvalidAskBound);
    config.max_ask_price = value;
}

public(package) fun set_depth_multiplier(config: &mut PricingConfig, multiplier: u64) {
    config.depth_multiplier = multiplier;
}

public(package) fun set_reference_tte_ms(config: &mut PricingConfig, value: u64) {
    assert!(value >= config.min_tte_ms, EInvalidTteBound);
    config.reference_tte_ms = value;
}

public(package) fun set_min_tte_ms(config: &mut PricingConfig, value: u64) {
    assert!(value > 0 && value <= config.reference_tte_ms, EInvalidTteBound);
    config.min_tte_ms = value;
}

public(package) fun quote_spread_from_fair_price(
    config: &PricingConfig,
    fair_price: u64,
    liability: u64,
    balance: u64,
): u64 {
    assert!(fair_price > 0 && fair_price < constants::float_scaling!(), EFairPriceAlreadySettled);
    let complement = constants::float_scaling!() - fair_price;
    let variance = math::mul(fair_price, complement);
    let bernoulli_factor = predict_math::sqrt(variance, constants::float_scaling!());
    let bernoulli_spread = math::mul(config.base_spread, bernoulli_factor);
    let spread =
        bernoulli_spread.max(config.min_spread)
        + utilization_spread(config, liability, balance);

    spread
}

/// Compute the post-shift UP ask / bid for `up_price`. Applies a symmetric
/// spread around the inventory-shifted mid and clamps both quotes at the fair
/// price (zero-edge floor — LP never sells UP below fair or buys UP above fair).
public(package) fun compute_up_quote(
    config: &PricingConfig,
    up_price: u64,
    aggregate: &I64,
    liability: u64,
    balance: u64,
    tte_ms: u64,
): (u64, u64) {
    let spread = config.quote_spread_from_fair_price(up_price, liability, balance);
    let shifted_mid = shifted_up_mid(
        up_price,
        aggregate,
        balance,
        tte_ms,
        config.depth_multiplier,
        config.reference_tte_ms,
        config.min_tte_ms,
    );

    let up_ask = (shifted_mid + spread).max(up_price).min(constants::float_scaling!());
    let up_bid = if (shifted_mid > spread) {
        (shifted_mid - spread).min(up_price)
    } else {
        0
    };

    (up_ask, up_bid)
}

fun utilization_spread(config: &PricingConfig, liability: u64, balance: u64): u64 {
    if (balance == 0 || liability == 0) return 0;

    // Cap utilization at 1.0 and square it so spread stays mild at low usage
    // and widens sharply only as the vault approaches full utilization.
    let util = if (liability >= balance) {
        constants::float_scaling!()
    } else {
        math::div(liability, balance)
    };
    let util_sq = math::mul(util, util);
    math::mul(
        config.base_spread,
        math::mul(config.utilization_multiplier, util_sq),
    )
}

/// Shifted UP mid in FLOAT_SCALING. The shift is
/// `clamp(aggregate · tte_factor / (balance · depth_multiplier), −1, +1)`
/// scaled by the per-strike distance to the nearest bound: `(1 − p)` for a
/// positive ratio (LP net short UP, push the mid up) or `p` for a negative
/// ratio. Result is always in `[0, float_scaling]` because the scaling caps
/// each direction at the bound.
fun shifted_up_mid(
    up_price: u64,
    aggregate: &I64,
    balance: u64,
    tte_ms: u64,
    depth_multiplier: u64,
    reference_tte_ms: u64,
    min_tte_ms: u64,
): u64 {
    if (i64::is_zero(aggregate) || balance == 0 || depth_multiplier == 0) return up_price;

    let fs = constants::float_scaling!();
    let clamped_tte = tte_ms.max(min_tte_ms);
    let tte_ratio = predict_math::mul_div_round_down(
        reference_tte_ms,
        fs,
        clamped_tte,
    );
    let tte_factor = predict_math::sqrt(tte_ratio, fs);

    let denominator = math::mul(balance, depth_multiplier);
    if (denominator == 0) return up_price;

    let num = i64::mul_scaled(aggregate, &i64::from_u64(tte_factor));
    let ratio = i64::div_scaled(&num, &i64::from_u64(denominator));
    let ratio_mag = i64::magnitude(&ratio).min(fs);
    if (ratio_mag == 0) return up_price;

    let ratio_negative = i64::is_negative(&ratio);
    let room = if (ratio_negative) up_price else fs - up_price;
    let shift = math::mul(ratio_mag, room);

    if (ratio_negative) {
        up_price - shift
    } else {
        up_price + shift
    }
}
