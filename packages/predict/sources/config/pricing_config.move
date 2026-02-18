// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pricing configuration - spread parameters for binary option pricing.
module deepbook_predict::pricing_config;

use deepbook_predict::constants;

// === Structs ===

public struct PricingConfig has store {
    /// Base spread in FLOAT_SCALING (e.g., 10_000_000 = 1%)
    base_spread: u64,
    /// Max skew multiplier in FLOAT_SCALING (e.g., 1_000_000_000 = 1x).
    /// Controls how much vault imbalance affects the spread.
    max_skew_multiplier: u64,
    /// Utilization multiplier in FLOAT_SCALING (e.g., 2_000_000_000 = 2x).
    /// Controls how aggressively spread widens as vault approaches capacity.
    utilization_multiplier: u64,
}

// === Public Functions ===

public fun base_spread(config: &PricingConfig): u64 {
    config.base_spread
}

public fun max_skew_multiplier(config: &PricingConfig): u64 {
    config.max_skew_multiplier
}

public fun utilization_multiplier(config: &PricingConfig): u64 {
    config.utilization_multiplier
}

// === Public-Package Functions ===

public(package) fun new(): PricingConfig {
    PricingConfig {
        base_spread: constants::default_base_spread!(),
        max_skew_multiplier: constants::default_max_skew_multiplier!(),
        utilization_multiplier: constants::default_utilization_multiplier!(),
    }
}

public(package) fun set_base_spread(config: &mut PricingConfig, spread: u64) {
    config.base_spread = spread;
}

public(package) fun set_max_skew_multiplier(config: &mut PricingConfig, multiplier: u64) {
    config.max_skew_multiplier = multiplier;
}

public(package) fun set_utilization_multiplier(config: &mut PricingConfig, multiplier: u64) {
    config.utilization_multiplier = multiplier;
}
