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
    /// Fixed wall-clock maximum age for Pyth spot; it does not vary with time to expiry.
    pyth_spot_freshness_ms: u64,
    /// Fixed wall-clock maximum age for Block Scholes spot and forward; it does not vary with time to expiry.
    block_scholes_price_freshness_ms: u64,
    /// Fixed wall-clock maximum age for Block Scholes SVI parameters; it does not vary with time to expiry.
    block_scholes_svi_freshness_ms: u64,
}

// === Public-Package Functions ===

public(package) fun pyth_spot_freshness_ms(config: &PricingConfig): u64 {
    config.pyth_spot_freshness_ms
}

public(package) fun block_scholes_price_freshness_ms(config: &PricingConfig): u64 {
    config.block_scholes_price_freshness_ms
}

public(package) fun block_scholes_svi_freshness_ms(config: &PricingConfig): u64 {
    config.block_scholes_svi_freshness_ms
}

public(package) fun new(): PricingConfig {
    PricingConfig {
        pyth_spot_freshness_ms: config_constants::default_pyth_spot_freshness_ms!(),
        block_scholes_price_freshness_ms: config_constants::default_block_scholes_price_freshness_ms!(),
        block_scholes_svi_freshness_ms: config_constants::default_block_scholes_svi_freshness_ms!(),
    }
}

public(package) fun set_pyth_spot_freshness_ms(config: &mut PricingConfig, value: u64) {
    config_constants::assert_pyth_spot_freshness_ms(value);
    config.pyth_spot_freshness_ms = value;
}

public(package) fun set_block_scholes_price_freshness_ms(config: &mut PricingConfig, value: u64) {
    config_constants::assert_block_scholes_price_freshness_ms(value);
    config.block_scholes_price_freshness_ms = value;
}

public(package) fun set_block_scholes_svi_freshness_ms(config: &mut PricingConfig, value: u64) {
    config_constants::assert_block_scholes_svi_freshness_ms(value);
    config.block_scholes_svi_freshness_ms = value;
}
