// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook::deep_price {
    use deepbook::math;

    // Minimum of 1 minutes between data points
    const MIN_DURATION_BETWEEN_DATA_POINTS_MS: u64 = 1000 * 60;
    // Price points older than 1 day will be removed
    const MAX_DATA_POINT_AGE_MS: u64 = 1000 * 60 * 60 * 24;
    // Maximum number of data points to maintan
    const MAX_DATA_POINTS: u64 = 100;

    const EDataPointRecentlyAdded: u64 = 1;
    // const ENoDataPoints: u64 = 2;

    /// DEEP price point.
    public struct Price has store, drop {
        conversion_rate: u64,
        timestamp: u64,
    }

    /// DEEP price points used for trading fee calculations.
    public struct DeepPrice has store, drop {
        base_prices: vector<Price>,
        index_to_replace_base: u64,
        cumulative_base: u64,
        quote_prices: vector<Price>,
        index_to_replace_quote: u64,
        cumulative_quote: u64,
    }

    public(package) fun empty(): DeepPrice {
        DeepPrice {
            base_prices: vector[],
            index_to_replace_base: 0,
            cumulative_base: 0,
            quote_prices: vector[],
            index_to_replace_quote: 0,
            cumulative_quote: 0,
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
        // assert!(self.last_insert_timestamp(is_base_conversion) + MIN_DURATION_BETWEEN_DATA_POINTS_MS < timestamp, EDataPointRecentlyAdded);
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
            let idx = self.index_to_replace_base;

            if (asset_prices.length() == MAX_DATA_POINTS + 1) {
                self.cumulative_base = self.cumulative_base - asset_prices[idx].conversion_rate;
                asset_prices.swap_remove(idx);
                asset_prices.swap_remove(idx);
                self.index_to_replace_base = self.index_to_replace_base + 1 % MAX_DATA_POINTS;
            };

            let mut idx = self.index_to_replace_base;
            while (asset_prices[idx].timestamp + MAX_DATA_POINT_AGE_MS < timestamp) {
                self.cumulative_base = self.cumulative_base - asset_prices[idx].conversion_rate;
                asset_prices.remove(idx);
                self.index_to_replace_base = self.index_to_replace_base + 1 % MAX_DATA_POINTS;
                idx = self.index_to_replace_base;
            }
        } else {
            self.cumulative_quote = self.cumulative_quote + conversion_rate;
            let idx = self.index_to_replace_quote;

            if (asset_prices.length() == MAX_DATA_POINTS + 1) {
                self.cumulative_quote = self.cumulative_quote - asset_prices[idx].conversion_rate;
                asset_prices.swap_remove(idx);
                asset_prices.swap_remove(idx);
                self.index_to_replace_quote = self.index_to_replace_quote + 1 % MAX_DATA_POINTS;
            };

            let mut idx = self.index_to_replace_quote;
            while (asset_prices[idx].timestamp + MAX_DATA_POINT_AGE_MS < timestamp) {
                self.cumulative_quote = self.cumulative_quote - asset_prices[idx].conversion_rate;
                asset_prices.remove(idx);
                self.index_to_replace_quote = self.index_to_replace_quote + 1 % MAX_DATA_POINTS;
                idx = self.index_to_replace_quote;
            }
        }
    }

    /// Returns the conversion rate of DEEP per asset token.
    /// is_base is true if the asset is the base asset.
    public(package) fun deep_per_asset(
        self: &DeepPrice,
        is_base: bool,
    ): u64 {
        // TODO: Add assert, assert!(self.last_insert_timestamp() > 0, ENoDataPoints);
        if (self.last_insert_timestamp(is_base) == 0) return 10 * 1_000_000_000; // Default deep conversion rate to 10, remove after testing
        let cumulative_asset = if (is_base) {
            self.cumulative_base
        } else {
            self.cumulative_quote
        };
        let asset_length = if (is_base) {
            self.base_prices.length()
        } else {
            self.quote_prices.length()
        };
        let deep_per_asset = math::div(cumulative_asset, asset_length);

        deep_per_asset
    }

    fun last_insert_timestamp(
        self: &DeepPrice,
        is_base: bool,
    ): u64 {
        let prices = if (is_base) {
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
}
