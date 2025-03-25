// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// `Fill` struct represents the results of a match between two orders.
module deepbook::fill;

use deepbook::{balances::{Self, Balances}, deep_price::OrderDeepPrice};

// === Structs ===
/// Fill struct represents the results of a match between two orders.
/// It is used to update the state.
public struct Fill has copy, drop, store {
    // ID of the maker order
    maker_order_id: u128,
    // Client Order ID of the maker order
    maker_client_order_id: u64,
    // Execution price
    execution_price: u64,
    // account_id of the maker order
    balance_manager_id: ID,
    // Whether the maker order is expired
    expired: bool,
    // Whether the maker order is fully filled
    completed: bool,
    // Original maker quantity
    original_maker_quantity: u64,
    // Quantity filled
    base_quantity: u64,
    // Quantity of quote currency filled
    quote_quantity: u64,
    // Whether the taker is bid
    taker_is_bid: bool,
    // Maker epoch
    maker_epoch: u64,
    // Maker deep price
    maker_deep_price: OrderDeepPrice,
    // Taker fee paid for fill
    taker_fee: u64,
    // Whether taker_fee is DEEP
    taker_fee_is_deep: bool,
    // Maker fee paid for fill
    maker_fee: u64,
    // Whether maker_fee is DEEP
    maker_fee_is_deep: bool,
}

// === Public-View Functions ===
public fun maker_order_id(self: &Fill): u128 {
    self.maker_order_id
}

public fun maker_client_order_id(self: &Fill): u64 {
    self.maker_client_order_id
}

public fun execution_price(self: &Fill): u64 {
    self.execution_price
}

public fun balance_manager_id(self: &Fill): ID {
    self.balance_manager_id
}

public fun expired(self: &Fill): bool {
    self.expired
}

public fun completed(self: &Fill): bool {
    self.completed
}

public fun original_maker_quantity(self: &Fill): u64 {
    self.original_maker_quantity
}

public fun base_quantity(self: &Fill): u64 {
    self.base_quantity
}

public fun taker_is_bid(self: &Fill): bool {
    self.taker_is_bid
}

public fun quote_quantity(self: &Fill): u64 {
    self.quote_quantity
}

public fun maker_epoch(self: &Fill): u64 {
    self.maker_epoch
}

public fun maker_deep_price(self: &Fill): OrderDeepPrice {
    self.maker_deep_price
}

public fun taker_fee(self: &Fill): u64 {
    self.taker_fee
}

public fun taker_fee_is_deep(self: &Fill): bool {
    self.taker_fee_is_deep
}

public fun maker_fee(self: &Fill): u64 {
    self.maker_fee
}

public fun maker_fee_is_deep(self: &Fill): bool {
    self.maker_fee_is_deep
}

// === Public-Package Functions ===
public(package) fun new(
    maker_order_id: u128,
    maker_client_order_id: u64,
    execution_price: u64,
    balance_manager_id: ID,
    expired: bool,
    completed: bool,
    original_maker_quantity: u64,
    base_quantity: u64,
    quote_quantity: u64,
    taker_is_bid: bool,
    maker_epoch: u64,
    maker_deep_price: OrderDeepPrice,
    taker_fee_is_deep: bool,
    maker_fee_is_deep: bool,
): Fill {
    Fill {
        maker_order_id,
        maker_client_order_id,
        execution_price,
        balance_manager_id,
        expired,
        completed,
        original_maker_quantity,
        base_quantity,
        quote_quantity,
        taker_is_bid,
        maker_epoch,
        maker_deep_price,
        taker_fee: 0,
        taker_fee_is_deep,
        maker_fee: 0,
        maker_fee_is_deep,
    }
}

/// Calculate the quantities to settle for the maker.
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

public(package) fun set_fill_maker_fee(self: &mut Fill, fee: &Balances) {
    if (fee.deep() > 0) {
        self.maker_fee_is_deep = true;
    } else {
        self.maker_fee_is_deep = false;
    };

    self.maker_fee = fee.non_zero_value();
}

public(package) fun set_fill_taker_fee(self: &mut Fill, fee: &Balances) {
    if (fee.deep() > 0) {
        self.taker_fee_is_deep = true;
    } else {
        self.taker_fee_is_deep = false;
    };

    self.taker_fee = fee.non_zero_value();
}
