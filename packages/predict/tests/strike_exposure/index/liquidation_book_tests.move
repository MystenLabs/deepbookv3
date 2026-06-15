// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit tests for the `liquidation_book` active-index and tombstone lifecycle
/// guards. The book is a pure data structure (no shared protocol state), so
/// orders are constructed directly via `order::new_from_ticks` with nonzero
/// `floor_shares` (leveraged) — only leveraged orders are indexed.
#[test_only]
module deepbook_predict::liquidation_book_tests;

use deepbook_predict::{constants, liquidation_book, order::{Self, Order}};
use std::unit_test::{assert_eq, destroy};

const OPENED_AT_MS: u64 = 1_000;
// Leveraged orders must be semi-infinite (order.move assert_valid_order_shape:
// lower tick 0 or higher tick == pos_inf_tick), so use an open lower end.
const LOWER_TICK: u64 = 0;
const HIGHER_TICK: u64 = 2;
const SEQUENCE: u64 = 7;
const PRIORITY_QUANTITY_LOTS: u64 = 10;
const LOW_FLOOR_SHARES: u64 = 10_000;
const HIGH_FLOOR_SHARES: u64 = 20_000;

/// One lot above zero so the order is structurally valid; floor_shares > 0
/// makes it leveraged (the book ignores 1x orders).
fun leveraged_order(): Order {
    let quantity = constants::position_lot_size!();
    order::new_from_ticks(
        OPENED_AT_MS,
        LOWER_TICK,
        HIGHER_TICK,
        quantity / 2, // floor_shares > 0 => leveraged
        quantity,
        SEQUENCE,
    )
}

#[test, expected_failure(abort_code = liquidation_book::EActiveOrderAlreadyExists)]
fun insert_same_active_order_twice_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut book = liquidation_book::new(ctx);
    let o = leveraged_order();
    book.insert_order(&o);
    book.insert_order(&o);
    abort 999
}

#[test, expected_failure(abort_code = liquidation_book::EActiveOrderNotFound)]
fun remove_from_empty_book_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut book = liquidation_book::new(ctx);
    let o = leveraged_order();
    book.remove_order(&o);
    abort 999
}

#[test, expected_failure(abort_code = liquidation_book::EActiveOrderNotFound)]
fun remove_uninserted_order_from_nonempty_book_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut book = liquidation_book::new(ctx);
    let inserted = leveraged_order();
    book.insert_order(&inserted);
    // Same ticks, different sequence => different packed id.
    let quantity = constants::position_lot_size!();
    let missing = order::new_from_ticks(
        OPENED_AT_MS,
        LOWER_TICK,
        HIGHER_TICK,
        quantity / 2,
        quantity,
        SEQUENCE + 1,
    );
    book.remove_order(&missing);
    abort 999
}

#[test, expected_failure(abort_code = liquidation_book::ELiquidatedOrderAlreadyExists)]
fun insert_liquidated_order_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut book = liquidation_book::new(ctx);
    let o = leveraged_order();
    book.insert_order(&o);
    book.mark_liquidated(&o);
    // Tombstone persists until cleared; re-indexing the same order is blocked.
    book.insert_order(&o);
    abort 999
}

#[test, expected_failure(abort_code = liquidation_book::ELiquidatedOrderNotFound)]
fun clear_never_liquidated_order_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut book = liquidation_book::new(ctx);
    let o = leveraged_order();
    book.clear_liquidated(&o);
    abort 999
}

#[test]
fun mark_liquidated_removes_active_and_records_tombstone() {
    let ctx = &mut tx_context::dummy();
    let mut book = liquidation_book::new(ctx);
    let o = leveraged_order();
    book.insert_order(&o);
    assert!(book.contains_active_order(&o));
    assert!(!book.is_liquidated(&o));

    book.mark_liquidated(&o);
    assert!(!book.contains_active_order(&o));
    assert!(book.is_liquidated(&o));

    book.clear_liquidated(&o);
    assert!(!book.is_liquidated(&o));
    destroy(book);
}

#[test]
fun head_candidate_prefers_higher_floor_for_equal_quantity() {
    let ctx = &mut tx_context::dummy();
    let mut book = liquidation_book::new(ctx);
    let quantity = constants::position_lot_size!() * PRIORITY_QUANTITY_LOTS;
    let low_floor = order::new_from_ticks(
        OPENED_AT_MS,
        LOWER_TICK,
        HIGHER_TICK,
        LOW_FLOOR_SHARES,
        quantity,
        SEQUENCE,
    );
    let high_floor = order::new_from_ticks(
        OPENED_AT_MS,
        LOWER_TICK,
        HIGHER_TICK,
        HIGH_FLOOR_SHARES,
        quantity,
        SEQUENCE + 1,
    );

    book.insert_order(&low_floor);
    book.insert_order(&high_floor);
    let candidates = book.select_liquidation_candidates(1);

    assert_eq!(candidates.length(), 1);
    assert_eq!(candidates[0], high_floor.id());
    destroy(book);
}
