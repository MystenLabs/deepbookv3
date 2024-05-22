// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook::fill {
    use deepbook::balances::{Self, Balances};
    /// Fill struct represents the results of a match between two orders.
    /// It is used to update the state.
    public struct Fill has store, drop, copy {
        // ID of the maker order
        order_id: u128,
        // account_id of the maker order
        balance_manager_id: ID,
        // Whether the maker order is expired
        expired: bool,
        // Whether the maker order is fully filled
        completed: bool,
        // Quantity filled
        volume: u64,
        // Quantity of quote currency filled
        quote_quantity: u64,
        // Whether the taker is bid
        taker_is_bid: bool,
    }

    public(package) fun new(
        order_id: u128,
        balance_manager_id: ID,
        expired: bool,
        completed: bool,
        volume: u64,
        quote_quantity: u64,
        taker_is_bid: bool,
    ): Fill {
        Fill {
            order_id,
            balance_manager_id,
            expired,
            completed,
            volume,
            quote_quantity,
            taker_is_bid,
        }
    }

    public(package) fun order_id(self: &Fill): u128 {
        self.order_id
    }

    public(package) fun balance_manager_id(self: &Fill): ID {
        self.balance_manager_id
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
    
    public(package) fun taker_is_bid(self: &Fill): bool {
        self.taker_is_bid
    }

    public(package) fun quote_quantity(self: &Fill): u64 {
        if (self.expired) {
            0
        } else {
            self.quote_quantity
        }
    }

    public(package) fun get_settled_maker_quantities(self: &Fill): Balances {
        let (base, quote) = if (self.expired) {
            if (self.taker_is_bid) {
                (self.volume, 0)
            } else {
                (0, self.quote_quantity)
            }
        } else {
            if (self.taker_is_bid) {
                (0, self.quote_quantity)
            } else {
                (self.volume, 0)
            }
        };

        balances::new(base, quote, 0)
    }
}