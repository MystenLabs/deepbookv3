// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Stored oracle freshness config for Predict quotes.
///
/// ProtocolConfig owns this mutable policy. Pricing reads it when resolving
/// live probabilities for mint and redeem flows.
module deepbook_predict::pricing_config;

use deepbook_predict::config_constants;

/// Freshness parameters used when resolving live Predict probabilities.
public struct PricingConfig has store {
    /// Maximum age for Pyth spot to be used as canonical live spot.
    pyth_spot_freshness_ms: u64,
    /// Maximum age for a Block Scholes surface row (spot + forward + SVI, written
    /// together per update) to be used in live pricing.
    block_scholes_surface_freshness_ms: u64,
}

// === Public-Package Functions ===

public(package) fun pyth_spot_freshness_ms(config: &PricingConfig): u64 {
    config.pyth_spot_freshness_ms
}

public(package) fun block_scholes_surface_freshness_ms(config: &PricingConfig): u64 {
    config.block_scholes_surface_freshness_ms
}

public(package) fun new(): PricingConfig {
    PricingConfig {
        pyth_spot_freshness_ms: config_constants::default_pyth_spot_freshness_ms!(),
        block_scholes_surface_freshness_ms: config_constants::default_block_scholes_surface_freshness_ms!(),
    }
}

public(package) fun set_pyth_spot_freshness_ms(config: &mut PricingConfig, value: u64) {
    config_constants::assert_pyth_spot_freshness_ms(value);
    config.pyth_spot_freshness_ms = value;
}

public(package) fun set_block_scholes_surface_freshness_ms(config: &mut PricingConfig, value: u64) {
    config_constants::assert_block_scholes_surface_freshness_ms(value);
    config.block_scholes_surface_freshness_ms = value;
}
