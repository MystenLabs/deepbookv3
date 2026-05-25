// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Active leveraged-order debt book for one strike exposure book.
///
/// The book tracks active membership and aggregate debt basis. It does not own
/// borrow-index math, liquidation state, or payout movement.
module deepbook_predict::leverage_book;

use deepbook_predict::{constants, math, order::Order};
use sui::table::{Self, Table};

const EInvalidLeveragedOrder: u64 = 0;
const EOrderNotActive: u64 = 1;
const EOrderAlreadyActive: u64 = 2;
const EInvalidBorrowTerms: u64 = 3;

/// Active leveraged order membership and aggregate debt basis.
public struct LeverageBook has store {
    active_orders: Table<u256, bool>,
    /// Sum of leveraged orders' borrowed principal before accrued borrow fees.
    total_borrowed_principal: u64,
    /// Sum of borrowed principal normalized by each order's opening borrow index.
    total_normalized_debt: u64,
}

public(package) fun new(ctx: &mut TxContext): LeverageBook {
    LeverageBook {
        active_orders: table::new(ctx),
        total_borrowed_principal: 0,
        total_normalized_debt: 0,
    }
}

/// Return aggregate debt by applying one borrow index to aggregate normalized debt.
public(package) fun aggregate_debt_terms(book: &LeverageBook, current_index: u64): (u64, u64) {
    let indexed_debt = math::mul_div_round_up(
        book.total_normalized_debt,
        current_index,
        constants::float_scaling!(),
    );
    let borrowed_principal = book.total_borrowed_principal;
    let debt_amount = indexed_debt.max(borrowed_principal);
    (debt_amount, debt_amount - borrowed_principal)
}

public(package) fun assert_active(book: &LeverageBook, order: &Order) {
    assert!(book.active_orders.contains(order.id()), EOrderNotActive);
}

public(package) fun insert_order(book: &mut LeverageBook, order: &Order, normalized_debt: u64) {
    assert!(order.is_leveraged(), EInvalidLeveragedOrder);
    let order_id = order.id();
    assert!(!book.active_orders.contains(order_id), EOrderAlreadyActive);
    book.active_orders.add(order_id, true);
    let borrowed_principal = order.borrowed_principal();
    book.total_borrowed_principal = book.total_borrowed_principal + borrowed_principal;
    book.total_normalized_debt = book.total_normalized_debt + normalized_debt;
}

public(package) fun remove_order(book: &mut LeverageBook, order: &Order, normalized_debt: u64) {
    assert!(order.is_leveraged(), EInvalidLeveragedOrder);
    let order_id = order.id();
    assert!(book.active_orders.contains(order_id), EOrderNotActive);
    let _active = book.active_orders.remove(order_id);
    let borrowed_principal = order.borrowed_principal();
    assert!(
        book.total_borrowed_principal >= borrowed_principal
            && book.total_normalized_debt >= normalized_debt,
        EInvalidBorrowTerms,
    );
    book.total_borrowed_principal = book.total_borrowed_principal - borrowed_principal;
    book.total_normalized_debt = book.total_normalized_debt - normalized_debt;
}
