// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit quote composition for Predict binary markets.
///
/// This module combines fair binary pricing, fee calculation, and ask-bound
/// checks. It does not select oracle inputs, resolve per-oracle ask-bound
/// overrides, compute trade amounts, or route funds.
module deepbook_predict::quote_pricing;

use deepbook::constants::max_u64;
use deepbook_predict::{
    binary_pricing,
    constants,
    fee_model,
    meta_oracle::CanonicalSnapshot,
    pricing_config::PricingConfig,
    range_key::RangeKey
};

const EInvalidAskBounds: u64 = 0;
const EAskPriceOverflow: u64 = 1;
const EAskPriceOutOfBounds: u64 = 2;

/// Resolved mint ask bounds for a quote.
public struct AskBounds has copy, drop, store {
    min_ask_price: u64,
    max_ask_price: u64,
}

/// Per-unit quote in FLOAT_SCALING units.
public struct UnitQuote has copy, drop, store {
    fair_price: u64,
    fee_rate: u64,
    ask_price: u64,
}

// === Public Functions ===

/// Create ask bounds from already-resolved minimum and maximum prices.
/// Empty intersections are representable; applying them rejects every ask.
public fun new_ask_bounds(min_ask_price: u64, max_ask_price: u64): AskBounds {
    assert!(max_ask_price < constants::float_scaling!(), EInvalidAskBounds);
    AskBounds {
        min_ask_price,
        max_ask_price,
    }
}

/// Return the minimum allowed ask price.
public fun min_ask_price(bounds: &AskBounds): u64 {
    bounds.min_ask_price
}

/// Return the maximum allowed ask price.
public fun max_ask_price(bounds: &AskBounds): u64 {
    bounds.max_ask_price
}

/// Return the fair price component.
public fun fair_price(quote: &UnitQuote): u64 {
    quote.fair_price
}

/// Return the per-unit fee increment.
public fun fee_rate(quote: &UnitQuote): u64 {
    quote.fee_rate
}

/// Return the all-in mint ask price.
public fun ask_price(quote: &UnitQuote): u64 {
    quote.ask_price
}

// === Public-Package Functions ===

/// Build the resolved global ask bounds from pricing config.
public(package) fun global_ask_bounds(config: &PricingConfig): AskBounds {
    new_ask_bounds(config.min_ask_price(), config.max_ask_price())
}

/// Quote a live range from canonical oracle state and current vault utilization.
public(package) fun quote_live_range(
    config: &PricingConfig,
    snapshot: &CanonicalSnapshot,
    key: &RangeKey,
    liability: u64,
    balance: u64,
): UnitQuote {
    let fair_price = binary_pricing::compute_range_price(
        snapshot,
        key.lower_strike(),
        key.higher_strike(),
    );
    quote_live_fair_price(config, fair_price, liability, balance)
}

/// Quote a live fair price from current fee config and vault utilization.
public(package) fun quote_live_fair_price(
    config: &PricingConfig,
    fair_price: u64,
    liability: u64,
    balance: u64,
): UnitQuote {
    let fee_rate = fee_model::quote_fee_rate(config, fair_price, liability, balance);
    new_unit_quote(fair_price, fee_rate)
}

/// Quote an already-finalized fair price with no live fee.
public(package) fun quote_zero_fee(fair_price: u64): UnitQuote {
    new_unit_quote(fair_price, 0)
}

/// Abort unless the quote's all-in ask price is inside `bounds`.
public(package) fun assert_ask_price_allowed(quote: &UnitQuote, bounds: &AskBounds) {
    let ask_price = quote.ask_price;
    assert!(
        ask_price >= bounds.min_ask_price && ask_price <= bounds.max_ask_price,
        EAskPriceOutOfBounds,
    );
}

// === Private Functions ===

fun new_unit_quote(fair_price: u64, fee_rate: u64): UnitQuote {
    assert!(fair_price <= max_u64() - fee_rate, EAskPriceOverflow);
    UnitQuote {
        fair_price,
        fee_rate,
        ask_price: fair_price + fee_rate,
    }
}
