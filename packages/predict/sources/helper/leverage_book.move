// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Brute-force leveraged order index for one expiry market.
///
/// The book stores only active leveraged order terms needed for debt accounting
/// and liquidation. The first liquidation path intentionally scans all active
/// leveraged order IDs.
module deepbook_predict::leverage_book;

use deepbook_predict::{math, predict_order_id};
use sui::table::{Self, Table};

const EInvalidLeveragedOrder: u64 = 0;
const EOrderNotActive: u64 = 1;
const ELiquidatedOrderNotFound: u64 = 2;
const EInsufficientLiquidatedQuantity: u64 = 3;
const EZeroQuantity: u64 = 4;

/// Active and liquidated leveraged orders for one expiry market.
public struct LeverageBook has store {
    active_order_ids: vector<u256>,
    orders: Table<u256, LeveragedOrder>,
    liquidated_orders: Table<u256, LiquidatedOrder>,
}

/// Debt and cleanup terms for one active leveraged order.
public struct LeveragedOrder has copy, drop, store {
    quantity: u64,
    borrowed_principal: u64,
    fee_basis: u64,
}

/// Remaining manager-side quantity for an order already liquidated by the market.
public struct LiquidatedOrder has copy, drop, store {
    quantity: u64,
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

public(package) fun order_terms(book: &LeverageBook, order_id: u256): (u64, u64, u64) {
    let order = &book.orders[order_id];
    (order.quantity, order.borrowed_principal, order.fee_basis)
}

public(package) fun borrowed_principal_to_remove(
    book: &LeverageBook,
    order_id: u256,
    quantity: u64,
): u64 {
    assert_nonzero_quantity(quantity);
    let order = &book.orders[order_id];
    assert!(order.quantity >= quantity, EOrderNotActive);
    proportional_remove(order.borrowed_principal, quantity, order.quantity)
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
    quantity: u64,
    borrowed_principal: u64,
    fee_basis: u64,
) {
    assert_nonzero_quantity(quantity);
    assert!(predict_order_id::is_leveraged_order(order_id), EInvalidLeveragedOrder);
    book.active_order_ids.push_back(order_id);
    book
        .orders
        .add(
            order_id,
            LeveragedOrder {
                quantity,
                borrowed_principal,
                fee_basis,
            },
        );
}

public(package) fun decrease_order(book: &mut LeverageBook, order_id: u256, quantity: u64) {
    assert_nonzero_quantity(quantity);
    let remove_order;
    {
        let order = &mut book.orders[order_id];
        assert!(order.quantity >= quantity, EOrderNotActive);
        let borrowed_principal_removed = proportional_remove(
            order.borrowed_principal,
            quantity,
            order.quantity,
        );
        let fee_basis_removed = proportional_remove(order.fee_basis, quantity, order.quantity);
        order.quantity = order.quantity - quantity;
        order.borrowed_principal = order.borrowed_principal - borrowed_principal_removed;
        order.fee_basis = order.fee_basis - fee_basis_removed;
        remove_order = order.quantity == 0;
    };
    if (remove_order) {
        let LeveragedOrder {
            quantity: _,
            borrowed_principal: _,
            fee_basis: _,
        } = book.orders.remove(order_id);
        book.remove_active_order_id(order_id);
    };
}

public(package) fun liquidate_order(book: &mut LeverageBook, order_id: u256): (u64, u64, u64) {
    let LeveragedOrder {
        quantity,
        borrowed_principal,
        fee_basis,
    } = book.orders.remove(order_id);
    book.remove_active_order_id(order_id);
    book
        .liquidated_orders
        .add(
            order_id,
            LiquidatedOrder {
                quantity,
            },
        );
    (quantity, borrowed_principal, fee_basis)
}

public(package) fun decrease_liquidated_order(
    book: &mut LeverageBook,
    order_id: u256,
    quantity: u64,
) {
    assert_nonzero_quantity(quantity);
    assert!(book.liquidated_orders.contains(order_id), ELiquidatedOrderNotFound);
    let remove_order;
    {
        let order = &mut book.liquidated_orders[order_id];
        assert!(order.quantity >= quantity, EInsufficientLiquidatedQuantity);
        order.quantity = order.quantity - quantity;
        remove_order = order.quantity == 0;
    };
    if (remove_order) {
        let LiquidatedOrder { quantity: _ } = book.liquidated_orders.remove(order_id);
    };
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

fun proportional_remove(amount: u64, quantity: u64, total_quantity: u64): u64 {
    if (quantity == total_quantity) amount
    else math::mul_div_round_up(amount, quantity, total_quantity)
}

fun assert_nonzero_quantity(quantity: u64) {
    assert!(quantity > 0, EZeroQuantity);
}
