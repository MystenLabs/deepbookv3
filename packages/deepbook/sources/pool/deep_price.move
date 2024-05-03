// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook::deep_price {
    use deepbook::math;

    // Minimum of 15 minutes between data points
    const MIN_DURATION_BETWEEN_DATA_POINTS_MS: u64 = 1000 * 60 * 15;
    // Maximum number of data points to maintan
    const MAX_DATA_POINTS: u64 = 100;

    const EDataPointRecentlyAdded: u64 = 1;

    // DEEP price points used for trading fee calculations.
    public struct DeepPrice has store, drop {
        last_insert_timestamp: u64,
        price_points_base: vector<u64>,
        price_points_quote: vector<u64>,
        index_to_replace: u64,
        cumulative_base: u64,
        cumulative_quote: u64,
    }

    public(package) fun new(): DeepPrice {
        DeepPrice {
            last_insert_timestamp: 0,
            price_points_base: vector[],
            price_points_quote: vector[],
            index_to_replace: 0,
            cumulative_base: 0,
            cumulative_quote: 0,
        }
    }

    /// Add a price point. All values are validated by this point.
    public(package) fun add_price_point(
        self: &mut DeepPrice,
        timestamp: u64,
        base_conversion_rate: u64,
        quote_conversion_rate: u64,
    ) {
        assert!(self.last_insert_timestamp + MIN_DURATION_BETWEEN_DATA_POINTS_MS < timestamp, EDataPointRecentlyAdded);
        self.price_points_base.push_back(base_conversion_rate);
        self.price_points_quote.push_back(quote_conversion_rate);
        self.cumulative_base = self.cumulative_base + base_conversion_rate;
        self.cumulative_quote = self.cumulative_quote + quote_conversion_rate;

        if (self.price_points_base.length() == MAX_DATA_POINTS + 1) {
            let idx = self.index_to_replace;
            self.cumulative_base = self.cumulative_base - self.price_points_base[idx];
            self.cumulative_quote = self.cumulative_quote - self.price_points_quote[idx];
            self.price_points_base.swap_remove(idx);
            self.price_points_quote.swap_remove(idx);
            self.index_to_replace = self.index_to_replace + 1 % MAX_DATA_POINTS;
        }
    }

    public(package) fun verified(
        self: &DeepPrice,
    ): bool {
        self.last_insert_timestamp > 0
    }

    public(package) fun calculate_fees(
        self: &DeepPrice,
        fee_rate: u64,
        base_quantity: u64,
        quote_quantity: u64,
    ): (u64, u64, u64) {
        if (self.verified()) {
            let deep_per_base = math::div(self.cumulative_base, self.price_points_base.length());
            let deep_per_quote = math::div(self.cumulative_quote, self.price_points_quote.length());
            let base_fee = math::mul(fee_rate, math::mul(base_quantity, deep_per_base));
            let quote_fee = math::mul(fee_rate, math::mul(quote_quantity, deep_per_quote));
            
            return (0, 0, base_fee + quote_fee)
        };

        let base_fee = math::mul(fee_rate, base_quantity);
        let quote_fee = math::mul(fee_rate, quote_quantity);

        (base_fee, quote_fee, 0)
    }
}
