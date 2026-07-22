// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Duplicate, missing-order, and active-cap guards of the liquidation index.
#[test_only]
module deepbook_predict::scope_mechanics__intent_guard__liquidation_book_tests;

use deepbook_predict::{constants, liquidation_book, order::{Self, Order}};

const LOWER_TICK: u64 = 2;
const HIGHER_TICK: u64 = 8;
const FLOOR_SHARES: u64 = 5_000;
const FIRST_SEQUENCE: u64 = 0;
const SECOND_SEQUENCE: u64 = 1;

fun leveraged_order(sequence: u64): Order {
    order::new_from_ticks(
        LOWER_TICK,
        HIGHER_TICK,
        FLOOR_SHARES,
        constants::position_lot_size!(),
        sequence,
    )
}

#[test, expected_failure(abort_code = liquidation_book::EActiveOrderAlreadyExists)]
fun duplicate_active_order_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut book = liquidation_book::new(ctx);
    let order = leveraged_order(FIRST_SEQUENCE);
    book.insert_order(&order);
    book.insert_order(&order);
    abort 999
}

#[test, expected_failure(abort_code = liquidation_book::EActiveOrderNotFound)]
fun removal_from_empty_book_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut book = liquidation_book::new(ctx);
    book.remove_order(&leveraged_order(FIRST_SEQUENCE));
    abort 999
}

#[test, expected_failure(abort_code = liquidation_book::EActiveOrderNotFound)]
fun removal_of_missing_order_from_nonempty_book_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut book = liquidation_book::new(ctx);
    book.insert_order(&leveraged_order(FIRST_SEQUENCE));
    book.remove_order(&leveraged_order(SECOND_SEQUENCE));
    abort 999
}

#[test, expected_failure(abort_code = liquidation_book::EMaxActiveLeveragedOrders)]
fun leveraged_order_above_active_cap_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut book = liquidation_book::new(ctx);
    let cap = constants::max_active_leveraged_orders!();
    let mut sequence = FIRST_SEQUENCE;
    while (sequence < cap) {
        book.insert_order(&leveraged_order(sequence));
        sequence = sequence + 1;
    };
    book.insert_order(&leveraged_order(cap));
    abort 999
}
