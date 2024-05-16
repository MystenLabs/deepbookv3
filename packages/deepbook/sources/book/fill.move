// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook::fill {
    /// Fill struct represents the results of a match between two orders.
    /// It is used to update the state.
    public struct Fill has store, drop, copy {
        // ID of the maker order
        order_id: u128,
        // account_id of the maker order
        account_id: ID,
        // Whether the maker order is expired
        expired: bool,
        // Whether the maker order is fully filled
        completed: bool,
        // Quantity filled
        volume: u64,
        // Quantity settled in base asset terms for maker
        settled_base: u64,
        // Quantity settled in quote asset terms for maker
        settled_quote: u64,
        // Quantity settled in DEEP for maker
        settled_deep: u64,
    }

    public(package) fun new(
        order_id: u128,
        account_id: ID,
        expired: bool,
        completed: bool,
        volume: u64,
        settled_base: u64,
        settled_quote: u64,
        settled_deep: u64,
    ): Fill {
        Fill {
            order_id,
            account_id,
            expired,
            completed,
            volume,
            settled_base,
            settled_quote,
            settled_deep,
        }
    }

    public(package) fun order_id(self: &Fill): u128 {
        self.order_id
    }

    public(package) fun account_id(self: &Fill): ID {
        self.account_id
    }

    public(package) fun expired(self: &Fill): bool {
        self.expired
    }

    public(package) fun completed(self: &Fill): bool {
        self.completed
    }

    public(package) fun volume(self: &Fill): u64 {
        self.volume
    }

    public(package) fun settled_base(self: &Fill): u64 {
        self.settled_base
    }

    public(package) fun settled_quote(self: &Fill): u64 {
        self.settled_quote
    }

    public(package) fun settled_deep(self: &Fill): u64 {
        self.settled_deep
    }
}