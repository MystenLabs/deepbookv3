// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Brute-force leveraged order lifecycle index for one strike exposure book.
///
/// The book tracks active leveraged order IDs and liquidated tombstones. Debt
/// terms are immutable order-id facts and are derived by the exposure owner.
module deepbook_predict::leverage_book;

use deepbook_predict::predict_order_id;
use sui::table::{Self, Table};

const EInvalidLeveragedOrder: u64 = 0;
const EOrderNotActive: u64 = 1;
const ELiquidatedOrderNotFound: u64 = 2;
const EZeroQuantity: u64 = 4;

/// Active and liquidated leveraged orders for one exposure book.
public struct LeverageBook has store {
    active_order_ids: vector<u256>,
    active_orders: Table<u256, bool>,
    liquidated_orders: Table<u256, bool>,
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
    book.active_orders.contains(order_id)
}

public(package) fun is_liquidated(book: &LeverageBook, order_id: u256): bool {
    book.liquidated_orders.contains(order_id)
}

public(package) fun has_active_orders(book: &LeverageBook): bool {
    !book.active_order_ids.is_empty()
}

public(package) fun new(ctx: &mut TxContext): LeverageBook {
    LeverageBook {
        active_order_ids: vector[],
        active_orders: table::new(ctx),
        liquidated_orders: table::new(ctx),
    }
}

public(package) fun insert_order(book: &mut LeverageBook, order_id: u256) {
    assert!(predict_order_id::quantity(order_id) > 0, EZeroQuantity);
    assert!(predict_order_id::is_leveraged_order(order_id), EInvalidLeveragedOrder);
    book.active_order_ids.push_back(order_id);
    book.active_orders.add(order_id, true);
}

public(package) fun remove_order(book: &mut LeverageBook, order_id: u256) {
    assert!(book.active_orders.contains(order_id), EOrderNotActive);
    let _active = book.active_orders.remove(order_id);
    book.remove_active_order_id(order_id);
}

public(package) fun liquidate_order(book: &mut LeverageBook, order_id: u256) {
    book.remove_order(order_id);
    book.liquidated_orders.add(order_id, true);
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
