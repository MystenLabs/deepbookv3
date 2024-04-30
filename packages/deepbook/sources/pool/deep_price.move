// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook::deep_price {
    // DEEP price points used for trading fee calculations
    public struct DeepPrice has store, drop {
	last_insert_timestamp: u64,
	price_points_base: vector<u64>, // deque with a max size
	price_points_quote: vector<u64>,
	deep_per_base: u64,
	deep_per_quote: u64,
    }

    public(package) fun empty(): DeepPrice {
        // Initialize the DEEP price points
        DeepPrice {
            last_insert_timestamp: 0,
            price_points_base: vector[],
            price_points_quote: vector[],
            deep_per_base: 0,
            deep_per_quote: 0,
        }
    }

    /// Add a price point. All values are validated by this point.
    /// Calculate the rolling average and update deep_per_base, deep_per_quote.
    public(package) fun add_price_point(
        _deep_price: &mut DeepPrice,
        _timestamp: u64,
        _base_conversion_rate: u64,
        _quote_conversion_rate: u64,
    ) {
        // TODO 
    }

    public(package) fun deep_per_base(deep_price: &DeepPrice): u64 {
        deep_price.deep_per_base
    }

    public(package) fun deep_per_quote(deep_price: &DeepPrice): u64 {
        deep_price.deep_per_quote
    }
}
