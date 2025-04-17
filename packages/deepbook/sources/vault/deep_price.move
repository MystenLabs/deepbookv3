// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// DEEP price module. This module maintains the conversion rate
/// between DEEP and the base and quote assets.
module deepbook::deep_price;

use deepbook::{balances::{Self, Balances}, constants, math};
use sui::event;

// === Errors ===
const EDataPointRecentlyAdded: u64 = 1;
const ENoDataPoints: u64 = 2;

// === Constants ===
// Minimum of 1 minutes between data points
const MIN_DURATION_BETWEEN_DATA_POINTS_MS: u64 = 1000 * 60;
// Price points older than 1 day will be removed
const MAX_DATA_POINT_AGE_MS: u64 = 1000 * 60 * 60 * 24;
// Maximum number of data points to maintan
const MAX_DATA_POINTS: u64 = 100;

// === Structs ===
/// DEEP price point.
public struct Price has drop, store {
    conversion_rate: u64,
    timestamp: u64,
}

/// DEEP price point added event.
public struct PriceAdded has copy, drop {
    conversion_rate: u64,
    timestamp: u64,
    is_base_conversion: bool,
    reference_pool: ID,
    target_pool: ID,
}

/// DEEP price points used for trading fee calculations.
public struct DeepPrice has drop, store {
    base_prices: vector<Price>,
    cumulative_base: u64,
    quote_prices: vector<Price>,
    cumulative_quote: u64,
}

public struct OrderDeepPrice has copy, drop, store {
    asset_is_base: bool,
    deep_per_asset: u64,
}

// === Public-View Functions ===
public fun asset_is_base(self: &OrderDeepPrice): bool {
    self.asset_is_base
}

public fun deep_per_asset(self: &OrderDeepPrice): u64 {
    self.deep_per_asset
}

// === Public-Package Functions ===
public(package) fun empty(): DeepPrice {
    DeepPrice {
        base_prices: vector[],
        cumulative_base: 0,
        quote_prices: vector[],
        cumulative_quote: 0,
    }
}

public(package) fun new_order_deep_price(asset_is_base: bool, deep_per_asset: u64): OrderDeepPrice {
    OrderDeepPrice {
        asset_is_base: asset_is_base,
        deep_per_asset: deep_per_asset,
    }
}

public(package) fun get_order_deep_price(self: &DeepPrice, whitelisted: bool): OrderDeepPrice {
    let (asset_is_base, deep_per_asset) = self.calculate_order_deep_price(
        whitelisted,
    );

    new_order_deep_price(asset_is_base, deep_per_asset)
}

public(package) fun empty_deep_price(_self: &DeepPrice): OrderDeepPrice {
    new_order_deep_price(false, 0)
}

public(package) fun fee_quantity(
    self: &OrderDeepPrice,
    base_quantity: u64,
    quote_quantity: u64,
    is_bid: bool,
): Balances {
    let deep_quantity = if (self.asset_is_base) {
        math::mul(base_quantity, self.deep_per_asset)
    } else {
        math::mul(quote_quantity, self.deep_per_asset)
    };

    if (self.deep_per_asset > 0) {
        balances::new(0, 0, deep_quantity)
    } else if (is_bid) {
        balances::new(
            0,
            math::mul(
                quote_quantity,
                constants::fee_penalty_multiplier(),
            ),
            0,
        )
    } else {
        balances::new(
            math::mul(base_quantity, constants::fee_penalty_multiplier()),
            0,
            0,
        )
    }
}

public(package) fun deep_quantity_u128(
    self: &OrderDeepPrice,
    base_quantity: u128,
    quote_quantity: u128,
): u128 {
    if (self.asset_is_base) {
        math::mul_u128(base_quantity, self.deep_per_asset as u128)
    } else {
        math::mul_u128(quote_quantity, self.deep_per_asset as u128)
    }
}

/// Add a price point. If max data points are reached, the oldest data point is removed.
/// Remove all data points older than MAX_DATA_POINT_AGE_MS.
public(package) fun add_price_point(
    self: &mut DeepPrice,
    conversion_rate: u64,
    timestamp: u64,
    is_base_conversion: bool,
) {
    assert!(
        self.last_insert_timestamp(is_base_conversion) +
        MIN_DURATION_BETWEEN_DATA_POINTS_MS <
        timestamp,
        EDataPointRecentlyAdded,
    );
    let asset_prices = if (is_base_conversion) {
        &mut self.base_prices
    } else {
        &mut self.quote_prices
    };

    asset_prices.push_back(Price {
        timestamp: timestamp,
        conversion_rate: conversion_rate,
    });
    if (is_base_conversion) {
        self.cumulative_base = self.cumulative_base + conversion_rate;
        while (
            asset_prices.length() == MAX_DATA_POINTS + 1 ||
            asset_prices[0].timestamp + MAX_DATA_POINT_AGE_MS < timestamp
        ) {
            self.cumulative_base = self.cumulative_base - asset_prices[0].conversion_rate;
            asset_prices.remove(0);
        }
    } else {
        self.cumulative_quote = self.cumulative_quote + conversion_rate;
        while (
            asset_prices.length() == MAX_DATA_POINTS + 1 ||
            asset_prices[0].timestamp + MAX_DATA_POINT_AGE_MS < timestamp
        ) {
            self.cumulative_quote = self.cumulative_quote - asset_prices[0].conversion_rate;
            asset_prices.remove(0);
        }
    };
}

public(package) fun emit_deep_price_added(
    conversion_rate: u64,
    timestamp: u64,
    is_base_conversion: bool,
    reference_pool: ID,
    target_pool: ID,
) {
    event::emit(PriceAdded {
        conversion_rate,
        timestamp,
        is_base_conversion,
        reference_pool,
        target_pool,
    });
}

// === Private Functions ===
/// Returns the conversion rate of DEEP per asset token.
/// Quote will be used by default, if there are no quote data then base will be used
fun calculate_order_deep_price(self: &DeepPrice, whitelisted: bool): (bool, u64) {
    if (whitelisted) {
        return (false, 0) // no fees for whitelist
    };
    assert!(
        self.last_insert_timestamp(true) > 0 ||
        self.last_insert_timestamp(false) > 0,
        ENoDataPoints,
    );

    let is_base_conversion = self.last_insert_timestamp(false) == 0;

    let cumulative_asset = if (is_base_conversion) {
        self.cumulative_base
    } else {
        self.cumulative_quote
    };
    let asset_length = if (is_base_conversion) {
        self.base_prices.length()
    } else {
        self.quote_prices.length()
    };
    let deep_per_asset = cumulative_asset / asset_length;

    (is_base_conversion, deep_per_asset)
}

fun last_insert_timestamp(self: &DeepPrice, is_base_conversion: bool): u64 {
    let prices = if (is_base_conversion) {
        &self.base_prices
    } else {
        &self.quote_prices
    };
    if (prices.length() > 0) {
        prices[prices.length() - 1].timestamp
    } else {
        0
    }
}
