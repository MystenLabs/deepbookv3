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

const LOWER_TICK: u64 = 1;
const HIGHER_TICK: u64 = 3;
const SEQUENCE: u64 = 7;
const PRIORITY_QUANTITY_LOTS: u64 = 10;
const LOW_FLOOR_SHARES: u64 = 10_000;
const HIGH_FLOOR_SHARES: u64 = 20_000;
const ORDERS_OVER_ONE_PAGE: u64 = 70;
const EXPECTED_LEFT_SPLIT_LEN: u64 = 32;
const REMOVED_FOR_MERGE: u64 = 6;
const EXPECTED_MERGED_PAGE_LEN: u64 = 64;
const PASSIVE_SCAN_BUDGET: u64 = 30;
const PASSIVE_HEAD_COUNT: u64 = 20;
const PASSIVE_TAIL_COUNT: u64 = 10;
const PASSIVE_TAIL_START_INDEX: u64 = 20;

/// One lot above zero so the order is structurally valid; floor_shares > 0
/// makes it leveraged (the book ignores 1x orders).
fun leveraged_order(): Order {
    let quantity = constants::position_lot_size!();
    order::new_from_ticks(
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

#[test, expected_failure(abort_code = liquidation_book::EMaxActiveLeveragedOrders)]
fun insert_above_active_leveraged_order_cap_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut book = liquidation_book::new(ctx);
    insert_sequential_orders(&mut book, constants::max_active_leveraged_orders!());

    book.insert_order(&leveraged_order_with_sequence(constants::max_active_leveraged_orders!()));
    abort 999
}

#[test]
fun one_x_orders_do_not_count_toward_active_leveraged_order_cap() {
    let ctx = &mut tx_context::dummy();
    let mut book = liquidation_book::new(ctx);
    insert_sequential_orders(&mut book, constants::max_active_leveraged_orders!());

    // The book is AT the leveraged cap. A 1x order must NOT consume a slot: inserting it
    // succeeds (no EMaxActiveLeveragedOrders abort — a leveraged insert here would abort, see
    // insert_above_active_leveraged_order_cap_aborts) and leaves the active leveraged set
    // unchanged, so the candidate scan still returns exactly the cap. (`contains_active_order`
    // is not asserted here — it short-circuits false for any 1x order regardless of book state,
    // so it would be tautological; the unchanged candidate count is the real property.)
    let one_x = one_x_order_with_sequence(constants::max_active_leveraged_orders!());
    book.insert_order(&one_x);

    let candidates = book.select_liquidation_candidates(constants::max_active_leveraged_orders!());
    assert_eq!(candidates.length(), constants::max_active_leveraged_orders!());
    destroy(book);
}

#[test]
fun removing_active_leveraged_order_frees_cap_slot() {
    let ctx = &mut tx_context::dummy();
    let mut book = liquidation_book::new(ctx);
    insert_sequential_orders(&mut book, constants::max_active_leveraged_orders!());

    let removed = leveraged_order_with_sequence(0);
    book.remove_order(&removed);
    let replacement = leveraged_order_with_sequence(constants::max_active_leveraged_orders!());
    book.insert_order(&replacement);

    assert!(!book.contains_active_order(&removed));
    assert!(book.contains_active_order(&replacement));
    destroy(book);
}

#[test]
fun head_candidate_prefers_higher_floor_for_equal_quantity() {
    let ctx = &mut tx_context::dummy();
    let mut book = liquidation_book::new(ctx);
    let quantity = constants::position_lot_size!() * PRIORITY_QUANTITY_LOTS;
    let low_floor = order::new_from_ticks(
        LOWER_TICK,
        HIGHER_TICK,
        LOW_FLOOR_SHARES,
        quantity,
        SEQUENCE,
    );
    let high_floor = order::new_from_ticks(
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

#[test]
fun insert_over_page_capacity_splits_and_preserves_candidate_order() {
    let ctx = &mut tx_context::dummy();
    let mut book = liquidation_book::new(ctx);
    let inserted = insert_sequential_orders(&mut book, ORDERS_OVER_ONE_PAGE);

    let candidates = book.select_liquidation_candidates(ORDERS_OVER_ONE_PAGE);
    assert_eq!(candidates.length(), ORDERS_OVER_ONE_PAGE);
    assert_eq!(candidates[0], inserted[0]);
    assert_eq!(candidates[EXPECTED_LEFT_SPLIT_LEN - 1], inserted[EXPECTED_LEFT_SPLIT_LEN - 1]);
    assert_eq!(candidates[EXPECTED_LEFT_SPLIT_LEN], inserted[EXPECTED_LEFT_SPLIT_LEN]);
    assert_eq!(candidates[ORDERS_OVER_ONE_PAGE - 1], inserted[ORDERS_OVER_ONE_PAGE - 1]);

    destroy(book);
}

#[test]
fun removing_from_small_left_page_merges_pages_without_losing_orders() {
    let ctx = &mut tx_context::dummy();
    let mut book = liquidation_book::new(ctx);
    let inserted = insert_sequential_orders(&mut book, ORDERS_OVER_ONE_PAGE);

    let mut i = 0;
    while (i < REMOVED_FOR_MERGE) {
        book.remove_order(&leveraged_order_with_sequence(i));
        i = i + 1;
    };

    assert!(!book.contains_active_order(&leveraged_order_with_sequence(0)));
    assert!(book.contains_active_order(&leveraged_order_with_sequence(REMOVED_FOR_MERGE)));

    let candidates = book.select_liquidation_candidates(ORDERS_OVER_ONE_PAGE);
    assert_eq!(candidates.length(), EXPECTED_MERGED_PAGE_LEN);
    assert_eq!(candidates[0], inserted[REMOVED_FOR_MERGE]);

    destroy(book);
}

#[test]
fun passive_tail_scan_resumes_and_wraps_after_watermark() {
    let ctx = &mut tx_context::dummy();
    let mut book = liquidation_book::new(ctx);
    let inserted = insert_sequential_orders(&mut book, ORDERS_OVER_ONE_PAGE);

    let candidates = book.select_liquidation_candidates(PASSIVE_SCAN_BUDGET);
    assert_passive_window(&candidates, &inserted, PASSIVE_TAIL_START_INDEX);

    let candidates = book.select_liquidation_candidates(PASSIVE_SCAN_BUDGET);
    assert_passive_window(&candidates, &inserted, PASSIVE_TAIL_START_INDEX + PASSIVE_TAIL_COUNT);

    let candidates = book.select_liquidation_candidates(PASSIVE_SCAN_BUDGET);
    assert_passive_window(
        &candidates,
        &inserted,
        PASSIVE_TAIL_START_INDEX + 2 * PASSIVE_TAIL_COUNT,
    );

    let candidates = book.select_liquidation_candidates(PASSIVE_SCAN_BUDGET);
    assert_passive_window(
        &candidates,
        &inserted,
        PASSIVE_TAIL_START_INDEX + 3 * PASSIVE_TAIL_COUNT,
    );

    let candidates = book.select_liquidation_candidates(PASSIVE_SCAN_BUDGET);
    assert_passive_window(
        &candidates,
        &inserted,
        PASSIVE_TAIL_START_INDEX + 4 * PASSIVE_TAIL_COUNT,
    );

    let candidates = book.select_liquidation_candidates(PASSIVE_SCAN_BUDGET);
    assert_passive_window(&candidates, &inserted, PASSIVE_TAIL_START_INDEX);

    destroy(book);
}

fun leveraged_order_with_sequence(sequence: u64): Order {
    let quantity = constants::position_lot_size!();
    order::new_from_ticks(
        LOWER_TICK,
        HIGHER_TICK,
        quantity / 2,
        quantity,
        sequence,
    )
}

fun one_x_order_with_sequence(sequence: u64): Order {
    order::new_from_ticks(
        LOWER_TICK,
        HIGHER_TICK,
        0,
        constants::position_lot_size!(),
        sequence,
    )
}

fun insert_sequential_orders(
    book: &mut liquidation_book::LiquidationBook,
    count: u64,
): vector<u256> {
    let mut inserted = vector[];
    let mut i = 0;
    while (i < count) {
        let order = leveraged_order_with_sequence(i);
        inserted.push_back(order.id());
        book.insert_order(&order);
        i = i + 1;
    };
    inserted
}

fun assert_passive_window(candidates: &vector<u256>, inserted: &vector<u256>, start_index: u64) {
    assert_eq!(candidates.length(), PASSIVE_SCAN_BUDGET);
    assert_eq!(candidates[0], inserted[0]);
    assert_eq!(candidates[PASSIVE_HEAD_COUNT - 1], inserted[PASSIVE_HEAD_COUNT - 1]);
    assert_eq!(candidates[PASSIVE_HEAD_COUNT], inserted[start_index]);
    assert_eq!(candidates[PASSIVE_SCAN_BUDGET - 1], inserted[start_index + PASSIVE_TAIL_COUNT - 1]);
}
