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
        cumulative_base: u64,
        quote_prices: vector<Price>,
        cumulative_quote: u64,
    }

    public(package) fun empty(): DeepPrice {
        DeepPrice {
            base_prices: vector[],
            cumulative_base: 0,
            quote_prices: vector[],
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
        assert!(self.last_insert_timestamp(is_base_conversion) + MIN_DURATION_BETWEEN_DATA_POINTS_MS < timestamp, EDataPointRecentlyAdded);
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
        std::debug::print(&self.cumulative_base);
        std::debug::print(&self.cumulative_quote);
    }

    /// Returns the conversion rate of DEEP per asset token.
    /// is_base is true if the asset is the base asset.
    public(package) fun deep_per_asset(
        self: &DeepPrice,
    ): (bool, u64) {
        // TODO: Add assert, then remove override below.
        // assert!(self.last_insert_timestamp(true) > 0 || self.last_insert_timestamp(false) > 0, ENoDataPoints);
        if (self.last_insert_timestamp(true) == 0 && self.last_insert_timestamp(false) == 0) {
            return (true, 10 * 1_000_000_000); // Default deep conversion rate to 10, remove after testing
        };

        let is_base_conversion = self.last_insert_timestamp(true) > 0;

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

        (true, deep_per_asset)
    }

    fun last_insert_timestamp(
        self: &DeepPrice,
        is_base_conversion: bool,
    ): u64 {
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
}
