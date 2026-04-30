// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Live quote fee model for Predict binary markets.
///
/// This module computes the fee increment added on top of a fair price. It
/// does not store fee parameters, compute fair prices, enforce ask bounds, or
/// route collected fees.
module deepbook_predict::fee_model;

use deepbook::{constants::max_u64, math};
use deepbook_predict::{constants, math as predict_math, pricing_config::PricingConfig};

const EInvalidLiveFairPrice: u64 = 0;
const EFeeOverflow: u64 = 1;

// === Public-Package Functions ===

/// Quote the dynamic per-unit fee rate for a live fair price.
public(package) fun quote_fee_rate(
    config: &PricingConfig,
    fair_price: u64,
    liability: u64,
    balance: u64,
): u64 {
    let price_fee = price_fee_rate(config, fair_price);
    let utilization_fee = utilization_fee_rate(config, liability, balance);
    assert!(price_fee <= max_u64() - utilization_fee, EFeeOverflow);

    price_fee + utilization_fee
}

/// Compute the fair-price component, including the configured minimum fee.
public(package) fun price_fee_rate(config: &PricingConfig, fair_price: u64): u64 {
    let raw_fee = raw_bernoulli_fee_rate(config, fair_price);
    let min_fee = config.min_fee();
    if (raw_fee > min_fee) raw_fee else min_fee
}

/// Compute the unfloored Bernoulli fee component.
public(package) fun raw_bernoulli_fee_rate(config: &PricingConfig, fair_price: u64): u64 {
    assert!(fair_price > 0 && fair_price < constants::float_scaling!(), EInvalidLiveFairPrice);

    let complement = constants::float_scaling!() - fair_price;
    let variance = math::mul(fair_price, complement);
    let bernoulli_factor = predict_math::sqrt(variance, constants::float_scaling!());
    math::mul(config.base_fee(), bernoulli_factor)
}

/// Compute fee pressure from current liability utilization.
public(package) fun utilization_fee_rate(
    config: &PricingConfig,
    liability: u64,
    balance: u64,
): u64 {
    if (balance == 0 || liability == 0) return 0;

    let util = if (liability >= balance) {
        constants::float_scaling!()
    } else {
        math::div(liability, balance)
    };
    let util_sq = math::mul(util, util);
    math::mul(
        config.base_fee(),
        math::mul(config.utilization_multiplier(), util_sq),
    )
}
