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
        timestamp: u64,
        base_conversion_rate: u64,
    }

    /// DEEP price points used for trading fee calculations.
    public struct DeepPrice has store, drop {
        prices: vector<Price>,
        index_to_replace: u64,
        cumulative_base: u64,
    }

    public(package) fun empty(): DeepPrice {
        DeepPrice {
            prices: vector[],
            index_to_replace: 0,
            cumulative_base: 0,
        }
    }

    /// Add a price point. If max data points are reached, the oldest data point is removed.
    /// Remove all data points older than MAX_DATA_POINT_AGE_MS.
    public(package) fun add_price_point(
        self: &mut DeepPrice,
        timestamp: u64,
        base_conversion_rate: u64,
    ) {
        assert!(self.last_insert_timestamp() + MIN_DURATION_BETWEEN_DATA_POINTS_MS < timestamp, EDataPointRecentlyAdded);
        self.prices.push_back(Price {
            timestamp: timestamp,
            base_conversion_rate: base_conversion_rate,
        });
        self.cumulative_base = self.cumulative_base + base_conversion_rate;

        let idx = self.index_to_replace;
        if (self.prices.length() == MAX_DATA_POINTS + 1) {
            self.cumulative_base = self.cumulative_base - self.prices[idx].base_conversion_rate;
            self.prices.swap_remove(idx);
            self.prices.swap_remove(idx);
            self.index_to_replace = self.index_to_replace + 1 % MAX_DATA_POINTS;
        };

        let mut idx = self.index_to_replace;
        while (self.prices[idx].timestamp + MAX_DATA_POINT_AGE_MS < timestamp) {
            self.cumulative_base = self.cumulative_base - self.prices[idx].base_conversion_rate;
            self.prices.remove(idx);
            self.index_to_replace = self.index_to_replace + 1 % MAX_DATA_POINTS;
            idx = self.index_to_replace;
        }
    }

    public(package) fun conversion_rate(
        self: &DeepPrice,
    ): u64 {
        // TODO: Add assert, assert!(self.last_insert_timestamp() > 0, ENoDataPoints);
        if (self.last_insert_timestamp() == 0) return 10 * 1_000_000_000; // Default deep conversion rate to 10
        let deep_per_base = math::div(self.cumulative_base, self.prices.length());

        deep_per_base
    }

    fun last_insert_timestamp(self: &DeepPrice): u64 {
        if (self.prices.length() > 0) {
            self.prices[self.prices.length() - 1].timestamp
        } else {
            0
        }
    }
}
