// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pricing configuration - spread parameters for binary option pricing.
module deepbook_predict::pricing_config;

use deepbook::math;
use deepbook_predict::{constants, math as predict_math};

// === Errors ===
const EInvalidSpread: u64 = 0;
const EFairPriceAlreadySettled: u64 = 1;
const EInvalidAskBound: u64 = 2;

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

// === Public-Package Functions ===

public(package) fun new(): PricingConfig {
    PricingConfig {
        base_spread: constants::default_base_spread!(),
        min_spread: constants::default_min_spread!(),
        utilization_multiplier: constants::default_utilization_multiplier!(),
        min_ask_price: constants::default_min_ask_price!(),
        max_ask_price: constants::default_max_ask_price!(),
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
