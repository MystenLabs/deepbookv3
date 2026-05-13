// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Stored pricing and freshness config for Predict markets.
module deepbook_predict::pricing_config;

use deepbook_predict::config_constants;

const EInvalidAskBound: u64 = 0;

/// Fee and ask-bound parameters used when quoting Predict markets.
/// The quoted fee is a per-unit absolute price increment, not a bps rate.
public struct PricingConfig has store {
    /// Base fee multiplier for Bernoulli scaling.
    /// Effective fee rate = base_fee * sqrt(price * (1 - price)).
    base_fee: u64,
    /// Minimum per-unit fee floor; live quotes never go below this value.
    min_fee: u64,
    /// Utilization multiplier in FLOAT_SCALING (e.g., 2_000_000_000 = 2x).
    /// Controls how aggressively fees increase as capacity utilization rises.
    utilization_multiplier: u64,
    /// Global minimum allowed all-in mint price after adding the fee.
    min_ask_price: u64,
    /// Global maximum allowed all-in mint price after adding the fee.
    max_ask_price: u64,
    /// Maximum age for Pyth spot to be used as canonical live spot.
    pyth_spot_freshness_ms: u64,
    /// Maximum age for Block Scholes spot/forward to be used in live pricing.
    block_scholes_prices_freshness_ms: u64,
    /// Maximum age for Block Scholes SVI params to be used in live pricing.
    block_scholes_svi_freshness_ms: u64,
}

// === Public-Package Functions ===

/// Return the base fee multiplier.
public(package) fun base_fee(config: &PricingConfig): u64 {
    config.base_fee
}

/// Return the minimum per-unit fee floor.
public(package) fun min_fee(config: &PricingConfig): u64 {
    config.min_fee
}

/// Return the utilization multiplier.
public(package) fun utilization_multiplier(config: &PricingConfig): u64 {
    config.utilization_multiplier
}

/// Return the global minimum allowed all-in mint price.
public(package) fun min_ask_price(config: &PricingConfig): u64 {
    config.min_ask_price
}

/// Return the global maximum allowed all-in mint price.
public(package) fun max_ask_price(config: &PricingConfig): u64 {
    config.max_ask_price
}

/// Return the live Pyth spot freshness threshold.
public(package) fun pyth_spot_freshness_ms(config: &PricingConfig): u64 {
    config.pyth_spot_freshness_ms
}

/// Return the live Block Scholes spot/forward freshness threshold.
public(package) fun block_scholes_prices_freshness_ms(config: &PricingConfig): u64 {
    config.block_scholes_prices_freshness_ms
}

/// Return the live Block Scholes SVI freshness threshold.
public(package) fun block_scholes_svi_freshness_ms(config: &PricingConfig): u64 {
    config.block_scholes_svi_freshness_ms
}

/// Create pricing config seeded from protocol defaults.
public(package) fun new(): PricingConfig {
    PricingConfig {
        base_fee: config_constants::default_base_fee!(),
        min_fee: config_constants::default_min_fee!(),
        utilization_multiplier: config_constants::default_utilization_multiplier!(),
        min_ask_price: config_constants::default_min_ask_price!(),
        max_ask_price: config_constants::default_max_ask_price!(),
        pyth_spot_freshness_ms: config_constants::default_pyth_spot_freshness_ms!(),
        block_scholes_prices_freshness_ms: config_constants::default_block_scholes_prices_freshness_ms!(),
        block_scholes_svi_freshness_ms: config_constants::default_block_scholes_svi_freshness_ms!(),
    }
}

/// Set the base fee multiplier.
public(package) fun set_base_fee(config: &mut PricingConfig, fee: u64) {
    config_constants::assert_base_fee(fee);
    config.base_fee = fee;
}

/// Set the minimum fee floor.
public(package) fun set_min_fee(config: &mut PricingConfig, fee: u64) {
    config_constants::assert_min_fee(fee);
    config.min_fee = fee;
}

/// Set the utilization multiplier.
public(package) fun set_utilization_multiplier(config: &mut PricingConfig, multiplier: u64) {
    config_constants::assert_utilization_multiplier(multiplier);
    config.utilization_multiplier = multiplier;
}

/// Set the global minimum allowed mint price.
public(package) fun set_min_ask_price(config: &mut PricingConfig, value: u64) {
    config_constants::assert_min_ask_price(value);
    assert!(value < config.max_ask_price, EInvalidAskBound);
    config.min_ask_price = value;
}

/// Set the global maximum allowed mint price.
public(package) fun set_max_ask_price(config: &mut PricingConfig, value: u64) {
    config_constants::assert_max_ask_price(value);
    assert!(value > config.min_ask_price, EInvalidAskBound);
    config.max_ask_price = value;
}

/// Set the live Pyth spot freshness threshold.
public(package) fun set_pyth_spot_freshness_ms(config: &mut PricingConfig, value: u64) {
    config_constants::assert_pyth_spot_freshness_ms(value);
    config.pyth_spot_freshness_ms = value;
}

/// Set the live Block Scholes spot/forward freshness threshold.
public(package) fun set_block_scholes_prices_freshness_ms(config: &mut PricingConfig, value: u64) {
    config_constants::assert_block_scholes_prices_freshness_ms(value);
    config.block_scholes_prices_freshness_ms = value;
}

/// Set the live Block Scholes SVI freshness threshold.
public(package) fun set_block_scholes_svi_freshness_ms(config: &mut PricingConfig, value: u64) {
    config_constants::assert_block_scholes_svi_freshness_ms(value);
    config.block_scholes_svi_freshness_ms = value;
}

// === Test-Only Functions ===

#[test_only]
public fun destroy_for_testing(config: PricingConfig) {
    let PricingConfig {
        base_fee: _,
        min_fee: _,
        utilization_multiplier: _,
        min_ask_price: _,
        max_ask_price: _,
        pyth_spot_freshness_ms: _,
        block_scholes_prices_freshness_ms: _,
        block_scholes_svi_freshness_ms: _,
    } = config;
}
