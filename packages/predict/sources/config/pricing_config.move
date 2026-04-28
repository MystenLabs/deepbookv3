// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pricing configuration - dynamic fee parameters for binary option pricing.
module deepbook_predict::pricing_config;

use deepbook::math;
use deepbook_predict::{constants, math as predict_math};

const EInvalidFee: u64 = 0;
const EFairPriceAlreadySettled: u64 = 1;
const EInvalidAskBound: u64 = 2;

/// Fee and ask-bound parameters used when quoting Predict markets.
public struct PricingConfig has store {
    /// Base fee multiplier for Bernoulli scaling.
    /// Effective fee = base_fee * √(price * (1 - price)).
    base_fee: u64,
    /// Minimum fee floor — fee never goes below this value.
    min_fee: u64,
    /// Utilization multiplier in FLOAT_SCALING (e.g., 2_000_000_000 = 2x).
    /// Controls how aggressively fees increase as vault approaches capacity.
    utilization_multiplier: u64,
    /// Global minimum allowed all-in mint price.
    min_ask_price: u64,
    /// Global maximum allowed all-in mint price.
    max_ask_price: u64,
}

// === Public Functions ===

/// Return the base fee multiplier.
public fun base_fee(config: &PricingConfig): u64 {
    config.base_fee
}

/// Return the minimum fee floor.
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

// === Public-Package Functions ===

/// Create pricing config seeded from protocol defaults.
public(package) fun new(): PricingConfig {
    PricingConfig {
        base_fee: constants::default_base_fee!(),
        min_fee: constants::default_min_fee!(),
        utilization_multiplier: constants::default_utilization_multiplier!(),
        min_ask_price: constants::default_min_ask_price!(),
        max_ask_price: constants::default_max_ask_price!(),
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

/// Quote the dynamic fee rate for a live fair price.
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

#[test_only]
public fun destroy_for_testing(config: PricingConfig) {
    let PricingConfig {
        base_fee: _,
        min_fee: _,
        utilization_multiplier: _,
        min_ask_price: _,
        max_ask_price: _,
    } = config;
}