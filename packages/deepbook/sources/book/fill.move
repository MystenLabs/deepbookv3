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
        base_quantity: u64,
        // Quantity of quote currency filled
        quote_quantity: u64,
        // Whether the taker is bid
        taker_is_bid: bool,
        // Maker epoch
        maker_epoch: u64,
        // Maker deep per base
        maker_deep_per_asset: u64,
        // Deep conversion is
    }

    public(package) fun new(
        order_id: u128,
        balance_manager_id: ID,
        expired: bool,
        completed: bool,
        base_quantity: u64,
        quote_quantity: u64,
        taker_is_bid: bool,
        maker_epoch: u64,
        maker_deep_per_asset: u64,
    ): Fill {
        Fill {
            order_id,
            balance_manager_id,
            expired,
            completed,
            base_quantity,
            quote_quantity,
            taker_is_bid,
            maker_epoch,
            maker_deep_per_asset,
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

    public(package) fun base_quantity(self: &Fill): u64 {
        self.base_quantity
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

    public(package) fun maker_epoch(self: &Fill): u64 {
        self.maker_epoch
    }

    public(package) fun maker_deep_per_asset(self: &Fill): u64 {
        self.maker_deep_per_asset
    }

    public(package) fun get_settled_maker_quantities(self: &Fill): Balances {
        let (base, quote) = if (self.expired) {
            if (self.taker_is_bid) {
                (self.base_quantity, 0)
            } else {
                (0, self.quote_quantity)
            }
        } else {
            if (self.taker_is_bid) {
                (0, self.quote_quantity)
            } else {
                (self.base_quantity, 0)
            }
        };

        balances::new(base, quote, 0)
    }
}
