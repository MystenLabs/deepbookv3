// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook::fill {
    use deepbook::math;

    /// Fill struct represents the results of a match between two orders.
    /// It is used to update the state.
    public struct Fill has store, drop, copy {
        // ID of the maker order
        order_id: u128,
        // account_id of the maker order
        maker_account_id: ID,
        // Whether the maker order is expired
        expired: bool,
        // Whether the maker order is fully filled
        completed: bool,
        // Quantity filled
        base_quantity: u64,
        maker_epoch: u64,
        maker_deep_per_base: u64,
        taker_is_bid: bool,
        price: u64,
    }

    public(package) fun new_fill(
        order_id: u128,
        maker_account_id: ID,
        expired: bool,
        completed: bool,
        base_quantity: u64,
        maker_epoch: u64,
        maker_deep_per_base: u64,
        taker_is_bid: bool,
        price: u64,
    ): Fill {
        Fill {
            order_id,
            maker_account_id,
            expired,
            completed,
            base_quantity,
            maker_epoch,
            maker_deep_per_base,
            taker_is_bid,
            price,
        }
    }

    public(package) fun order_id(self: &Fill): u128 {
        self.order_id
    }

    public(package) fun maker_account_id(self: &Fill): ID {
        self.maker_account_id
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

    public(package) fun maker_epoch(self: &Fill): u64 {
        self.maker_epoch
    }

    public(package) fun calculate_maker_settled_amounts(
        self: &Fill,
        maker_fee: u64,
    ): (u64, u64, u64) {
        let is_bid = self.taker_is_bid;
        let expired = self.expired;
        let base = self.base_quantity;
        let quote = math::mul(self.base_quantity, self.price);
        let mut deep = math::mul(self.base_quantity, maker_fee);
        deep = math::mul(deep, self.maker_deep_per_base);
        if (!expired) deep = 0;
        let mut settled_base = 0;
        let mut settled_quote = 0;

        if ((expired && is_bid) || (!expired && !is_bid)) {
            settled_base = base;
        } else {
            settled_quote = quote;
        };

        (settled_base, settled_quote, deep)
    }

    public(package) fun calculate_taker_owed_amounts(
        self: &Fill,
        taker_fee: u64,
        deep_per_base: u64,
    ): (u64, u64, u64) {
        let is_bid = self.taker_is_bid;
        let base = self.base_quantity;
        let quote = math::mul(self.base_quantity, self.price);
        let mut deep = math::mul(self.base_quantity, taker_fee);
        deep = math::mul(deep, deep_per_base);
        let mut owed_base = 0;
        let mut owed_quote = 0;

        if (is_bid) {
            owed_quote = quote;
        } else {
            owed_base = base;
        };

        (owed_base, owed_quote, deep)
    }
}