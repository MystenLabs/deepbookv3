// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Brute-force leveraged order index for one expiry market.
///
/// The book stores only active leveraged order terms needed for debt accounting
/// and liquidation. The first liquidation path intentionally scans all active
/// leveraged order IDs.
module deepbook_predict::leverage_book;

use deepbook_predict::predict_order_id;
use sui::table::{Self, Table};

const EInvalidLeveragedOrder: u64 = 0;
const EOrderNotActive: u64 = 1;
const ELiquidatedOrderNotFound: u64 = 2;
const EZeroQuantity: u64 = 4;

/// Active and liquidated leveraged orders for one expiry market.
public struct LeverageBook has store {
    active_order_ids: vector<u256>,
    orders: Table<u256, LeveragedOrder>,
    liquidated_orders: Table<u256, bool>,
}

/// Debt and cleanup terms for one active leveraged order.
public struct LeveragedOrder has copy, drop, store {
    borrowed_principal: u64,
}

// === Public-Package Functions ===

public(package) fun active_order_ids(book: &LeverageBook): vector<u256> {
    let mut order_ids = vector[];
    let mut i = 0;
    while (i < book.active_order_ids.length()) {
        order_ids.push_back(book.active_order_ids[i]);
        i = i + 1;
    };
    order_ids
}

public(package) fun is_active(book: &LeverageBook, order_id: u256): bool {
    book.orders.contains(order_id)
}

public(package) fun is_liquidated(book: &LeverageBook, order_id: u256): bool {
    book.liquidated_orders.contains(order_id)
}

public(package) fun borrowed_principal(book: &LeverageBook, order_id: u256): u64 {
    book.orders[order_id].borrowed_principal
}

public(package) fun new(ctx: &mut TxContext): LeverageBook {
    LeverageBook {
        active_order_ids: vector[],
        orders: table::new(ctx),
        liquidated_orders: table::new(ctx),
    }
}

public(package) fun insert_order(
    book: &mut LeverageBook,
    order_id: u256,
    borrowed_principal: u64,
) {
    assert_nonzero_quantity(predict_order_id::quantity(order_id));
    assert!(predict_order_id::is_leveraged_order(order_id), EInvalidLeveragedOrder);
    book.active_order_ids.push_back(order_id);
    book
        .orders
        .add(
            order_id,
            LeveragedOrder {
                borrowed_principal,
            },
        );
}

public(package) fun remove_order(book: &mut LeverageBook, order_id: u256) {
    assert!(book.orders.contains(order_id), EOrderNotActive);
    let LeveragedOrder { borrowed_principal: _ } = book.orders.remove(order_id);
    book.remove_active_order_id(order_id);
}

public(package) fun liquidate_order(book: &mut LeverageBook, order_id: u256): u64 {
    let LeveragedOrder { borrowed_principal } = book.orders.remove(order_id);
    book.remove_active_order_id(order_id);
    book
        .liquidated_orders
        .add(order_id, true);
    borrowed_principal
}

public(package) fun remove_liquidated_order(book: &mut LeverageBook, order_id: u256) {
    assert!(book.liquidated_orders.contains(order_id), ELiquidatedOrderNotFound);
    let _liquidated = book.liquidated_orders.remove(order_id);
}

// === Private Functions ===

fun remove_active_order_id(book: &mut LeverageBook, order_id: u256) {
    let mut i = 0;
    while (i < book.active_order_ids.length() && book.active_order_ids[i] != order_id) {
        i = i + 1;
    };
    assert!(i < book.active_order_ids.length(), EOrderNotActive);
    book.active_order_ids.swap_remove(i);
}

fun assert_nonzero_quantity(quantity: u64) {
    assert!(quantity > 0, EZeroQuantity);
}
