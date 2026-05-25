// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Active leveraged-order membership for one strike exposure book.
///
/// The book tracks which leveraged orders are currently open. It does not own
/// borrow-index math, aggregate valuation, liquidation state, or payout movement.
module deepbook_predict::leverage_book;

use deepbook_predict::order::Order;
use sui::table::{Self, Table};

const EInvalidLeveragedOrder: u64 = 0;
const EOrderNotActive: u64 = 1;
const EOrderAlreadyActive: u64 = 2;

/// Active leveraged order membership.
public struct LeverageBook has store {
    active_orders: Table<u256, bool>,
}

public(package) fun new(ctx: &mut TxContext): LeverageBook {
    LeverageBook {
        active_orders: table::new(ctx),
    }
}

public(package) fun assert_active(book: &LeverageBook, order: &Order) {
    assert!(book.active_orders.contains(order.id()), EOrderNotActive);
}

public(package) fun insert_order(book: &mut LeverageBook, order: &Order) {
    assert!(order.is_leveraged(), EInvalidLeveragedOrder);
    let order_id = order.id();
    assert!(!book.active_orders.contains(order_id), EOrderAlreadyActive);
    book.active_orders.add(order_id, true);
}

public(package) fun remove_order(book: &mut LeverageBook, order: &Order) {
    assert!(order.is_leveraged(), EInvalidLeveragedOrder);
    let order_id = order.id();
    assert!(book.active_orders.contains(order_id), EOrderNotActive);
    let _active = book.active_orders.remove(order_id);
}
