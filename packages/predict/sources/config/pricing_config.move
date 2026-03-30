// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pricing configuration - spread parameters for binary option pricing.
module deepbook_predict::pricing_config;

use deepbook_predict::constants;

// === Errors ===
const EInvalidSpread: u64 = 1;

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

// === Public-Package Functions ===

public(package) fun new(): PricingConfig {
    PricingConfig {
        base_spread: constants::default_base_spread!(),
        min_spread: constants::default_min_spread!(),
        utilization_multiplier: constants::default_utilization_multiplier!(),
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
