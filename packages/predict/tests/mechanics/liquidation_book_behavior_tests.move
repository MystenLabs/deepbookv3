// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Local active-order membership, priority, and one-x exclusion behavior.
#[test_only]
module deepbook_predict::scope_mechanics__intent_behavior__liquidation_book_tests;

use deepbook_predict::{constants, liquidation_book, order::{Self, Order}};
use std::unit_test::{assert_eq, destroy};

const LOWER_TICK: u64 = 2;
const HIGHER_TICK: u64 = 8;
const FIRST_SEQUENCE: u64 = 1;
const SECOND_SEQUENCE: u64 = 2;
const THIRD_SEQUENCE: u64 = 3;
const ZERO_FLOOR: u64 = 0;
const LOW_FLOOR: u64 = 10_000;
const HIGH_FLOOR: u64 = 20_000;
const SMALL_QUANTITY_LOTS: u64 = 2;
const LARGE_QUANTITY_LOTS: u64 = 3;
const EMPTY_BUDGET: u64 = 0;
const SINGLE_CANDIDATE_BUDGET: u64 = 1;
const FIRST_CANDIDATE_INDEX: u64 = 0;

fun order_with_terms(quantity_lots: u64, floor_shares: u64, sequence: u64): Order {
    order::new_from_ticks(
        LOWER_TICK,
        HIGHER_TICK,
        floor_shares,
        quantity_lots * constants::position_lot_size!(),
        sequence,
    )
}

#[test]
fun empty_book_and_zero_budget_return_no_candidates() {
    let ctx = &mut tx_context::dummy();
    let mut book = liquidation_book::new(ctx);

    let empty = book.select_liquidation_candidates(SINGLE_CANDIDATE_BUDGET);
    assert_eq!(empty.length(), EMPTY_BUDGET);

    let leveraged = order_with_terms(SMALL_QUANTITY_LOTS, LOW_FLOOR, FIRST_SEQUENCE);
    book.insert_order(&leveraged);
    let zero_budget = book.select_liquidation_candidates(EMPTY_BUDGET);
    assert_eq!(zero_budget.length(), EMPTY_BUDGET);
    assert!(book.contains_active_order(&leveraged));
    destroy(book);
}

#[test]
fun one_x_is_ignored_while_leveraged_membership_tracks_insert_and_remove() {
    let ctx = &mut tx_context::dummy();
    let mut book = liquidation_book::new(ctx);
    let one_x = order_with_terms(SMALL_QUANTITY_LOTS, ZERO_FLOOR, FIRST_SEQUENCE);
    let leveraged = order_with_terms(SMALL_QUANTITY_LOTS, LOW_FLOOR, SECOND_SEQUENCE);

    book.insert_order(&one_x);
    assert!(!book.contains_active_order(&one_x));
    assert_eq!(book.select_liquidation_candidates(SINGLE_CANDIDATE_BUDGET).length(), EMPTY_BUDGET);
    book.remove_order(&one_x);
    assert!(!book.contains_active_order(&one_x));

    book.insert_order(&leveraged);
    assert!(book.contains_active_order(&leveraged));
    assert_eq!(
        book.select_liquidation_candidates(SINGLE_CANDIDATE_BUDGET)[FIRST_CANDIDATE_INDEX],
        leveraged.id(),
    );
    book.remove_order(&leveraged);
    assert!(!book.contains_active_order(&leveraged));
    assert_eq!(book.select_liquidation_candidates(SINGLE_CANDIDATE_BUDGET).length(), EMPTY_BUDGET);
    destroy(book);
}

#[test]
fun priority_is_larger_quantity_then_larger_floor() {
    let ctx = &mut tx_context::dummy();
    let mut book = liquidation_book::new(ctx);
    let small = order_with_terms(SMALL_QUANTITY_LOTS, HIGH_FLOOR, FIRST_SEQUENCE);
    let large_low_floor = order_with_terms(LARGE_QUANTITY_LOTS, LOW_FLOOR, SECOND_SEQUENCE);
    let large_high_floor = order_with_terms(LARGE_QUANTITY_LOTS, HIGH_FLOOR, THIRD_SEQUENCE);

    book.insert_order(&small);
    book.insert_order(&large_low_floor);
    book.insert_order(&large_high_floor);
    let candidates = book.select_liquidation_candidates(SINGLE_CANDIDATE_BUDGET);

    assert_eq!(candidates.length(), SINGLE_CANDIDATE_BUDGET);
    assert_eq!(candidates[FIRST_CANDIDATE_INDEX], large_high_floor.id());
    destroy(book);
}
