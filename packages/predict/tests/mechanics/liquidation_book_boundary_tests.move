// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Observable page, capacity, and rotating-tail boundaries of the active index.
#[test_only]
module deepbook_predict::scope_mechanics__intent_boundary__liquidation_book_tests;

use deepbook_predict::{constants, liquidation_book, order::{Self, Order}};
use std::unit_test::{assert_eq, destroy};

const LOWER_TICK: u64 = 2;
const HIGHER_TICK: u64 = 8;
const FLOOR_SHARES: u64 = 5_000;
const FIRST_SEQUENCE: u64 = 0;
const ONE_PAGE_PLUS_SIX: u64 = 70;
const SPLIT_LEFT_LENGTH: u64 = 32;
const REMOVED_BEFORE_MERGE: u64 = 6;
const MERGED_SURVIVORS: u64 = 64;
const PASSIVE_SCAN_BUDGET: u64 = 30;
const PASSIVE_HEAD_COUNT: u64 = 20;
const PASSIVE_TAIL_COUNT: u64 = 10;
const PASSIVE_DOMAIN_COUNT: u64 = 50;
const ONE_X_FLOOR: u64 = 0;
const FIRST_INDEX: u64 = 0;
const SECOND_TAIL_OFFSET: u64 = 20;
const THIRD_TAIL_OFFSET: u64 = 30;
const FOURTH_TAIL_OFFSET: u64 = 40;

fun leveraged_order(sequence: u64): Order {
    order::new_from_ticks(
        LOWER_TICK,
        HIGHER_TICK,
        FLOOR_SHARES,
        constants::position_lot_size!(),
        sequence,
    )
}

fun one_x_order(sequence: u64): Order {
    order::new_from_ticks(
        LOWER_TICK,
        HIGHER_TICK,
        ONE_X_FLOOR,
        constants::position_lot_size!(),
        sequence,
    )
}

fun assert_passive_tail(candidates: &vector<u256>, inserted: &vector<u256>, tail_offset: u64) {
    let mut offset = 0;
    while (offset < PASSIVE_TAIL_COUNT) {
        assert_eq!(
            candidates[PASSIVE_HEAD_COUNT + offset],
            inserted[PASSIVE_HEAD_COUNT + (tail_offset + offset) % PASSIVE_DOMAIN_COUNT],
        );
        offset = offset + 1;
    };
}

#[test]
fun split_boundary_preserves_global_candidate_order() {
    let ctx = &mut tx_context::dummy();
    let mut book = liquidation_book::new(ctx);
    let mut inserted = vector[];
    let mut sequence = FIRST_SEQUENCE;
    while (sequence < ONE_PAGE_PLUS_SIX) {
        let order = leveraged_order(sequence);
        inserted.push_back(order.id());
        book.insert_order(&order);
        sequence = sequence + 1;
    };

    let candidates = book.select_liquidation_candidates(ONE_PAGE_PLUS_SIX);

    assert_eq!(candidates.length(), ONE_PAGE_PLUS_SIX);
    assert_eq!(candidates[FIRST_INDEX], inserted[FIRST_INDEX]);
    assert_eq!(candidates[SPLIT_LEFT_LENGTH - 1], inserted[SPLIT_LEFT_LENGTH - 1]);
    assert_eq!(candidates[SPLIT_LEFT_LENGTH], inserted[SPLIT_LEFT_LENGTH]);
    assert_eq!(candidates[ONE_PAGE_PLUS_SIX - 1], inserted[ONE_PAGE_PLUS_SIX - 1]);
    destroy(book);
}

#[test]
fun removal_that_crosses_merge_threshold_preserves_survivors() {
    let ctx = &mut tx_context::dummy();
    let mut book = liquidation_book::new(ctx);
    let mut inserted = vector[];
    let mut sequence = FIRST_SEQUENCE;
    while (sequence < ONE_PAGE_PLUS_SIX) {
        let order = leveraged_order(sequence);
        inserted.push_back(order.id());
        book.insert_order(&order);
        sequence = sequence + 1;
    };
    sequence = FIRST_SEQUENCE;
    while (sequence < REMOVED_BEFORE_MERGE) {
        book.remove_order(&leveraged_order(sequence));
        sequence = sequence + 1;
    };

    let candidates = book.select_liquidation_candidates(ONE_PAGE_PLUS_SIX);

    assert_eq!(candidates.length(), MERGED_SURVIVORS);
    assert_eq!(candidates[FIRST_INDEX], inserted[REMOVED_BEFORE_MERGE]);
    assert_eq!(candidates[MERGED_SURVIVORS - 1], inserted[ONE_PAGE_PLUS_SIX - 1]);
    assert!(!book.contains_active_order(&leveraged_order(FIRST_SEQUENCE)));
    assert!(book.contains_active_order(&leveraged_order(REMOVED_BEFORE_MERGE)));
    destroy(book);
}

#[test]
fun passive_tail_advances_then_wraps_after_the_tail_domain() {
    let ctx = &mut tx_context::dummy();
    let mut book = liquidation_book::new(ctx);
    let mut inserted = vector[];
    let mut sequence = FIRST_SEQUENCE;
    while (sequence < ONE_PAGE_PLUS_SIX) {
        let order = leveraged_order(sequence);
        inserted.push_back(order.id());
        book.insert_order(&order);
        sequence = sequence + 1;
    };

    let first = book.select_liquidation_candidates(PASSIVE_SCAN_BUDGET);
    assert_eq!(first.length(), PASSIVE_SCAN_BUDGET);
    assert_passive_tail(&first, &inserted, FIRST_INDEX);
    let second = book.select_liquidation_candidates(PASSIVE_SCAN_BUDGET);
    assert_eq!(second.length(), PASSIVE_SCAN_BUDGET);
    assert_passive_tail(&second, &inserted, PASSIVE_TAIL_COUNT);
    let third = book.select_liquidation_candidates(PASSIVE_SCAN_BUDGET);
    assert_eq!(third.length(), PASSIVE_SCAN_BUDGET);
    assert_passive_tail(&third, &inserted, SECOND_TAIL_OFFSET);
    let fourth = book.select_liquidation_candidates(PASSIVE_SCAN_BUDGET);
    assert_eq!(fourth.length(), PASSIVE_SCAN_BUDGET);
    assert_passive_tail(&fourth, &inserted, THIRD_TAIL_OFFSET);
    let fifth = book.select_liquidation_candidates(PASSIVE_SCAN_BUDGET);
    assert_eq!(fifth.length(), PASSIVE_SCAN_BUDGET);
    assert_passive_tail(&fifth, &inserted, FOURTH_TAIL_OFFSET);
    let wrapped = book.select_liquidation_candidates(PASSIVE_SCAN_BUDGET);
    assert_eq!(wrapped.length(), PASSIVE_SCAN_BUDGET);
    assert_passive_tail(&wrapped, &inserted, FIRST_INDEX);
    destroy(book);
}

#[test]
fun one_x_at_cap_is_ignored_and_removal_frees_a_leveraged_slot() {
    let ctx = &mut tx_context::dummy();
    let mut book = liquidation_book::new(ctx);
    let cap = constants::max_active_leveraged_orders!();
    let mut sequence = FIRST_SEQUENCE;
    while (sequence < cap) {
        book.insert_order(&leveraged_order(sequence));
        sequence = sequence + 1;
    };

    let one_x = one_x_order(cap);
    book.insert_order(&one_x);
    assert!(!book.contains_active_order(&one_x));

    let removed = leveraged_order(FIRST_SEQUENCE);
    let replacement = leveraged_order(cap);
    book.remove_order(&removed);
    book.insert_order(&replacement);
    assert!(!book.contains_active_order(&removed));
    assert!(book.contains_active_order(&replacement));
    assert_eq!(book.select_liquidation_candidates(cap).length(), cap);
    destroy(book);
}
