// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook::fill {
    use deepbook::balances::Balances;

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
        // Volume * price
        quote_quantity: u64,
        // Quantities settled for maker
        settled_balances: Balances,
    }

    public(package) fun new(
        order_id: u128,
        account_id: ID,
        expired: bool,
        completed: bool,
        volume: u64,
        quote_quantity: u64,
        settled_balances: Balances,
    ): Fill {
        Fill {
            order_id,
            account_id,
            expired,
            completed,
            volume,
            quote_quantity,
            settled_balances,
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

    public(package) fun quote_quantity(self: &Fill): u64 {
        self.quote_quantity
    }

    public(package) fun settled_balances(self: &Fill): &Balances {
        &self.settled_balances
    }
}