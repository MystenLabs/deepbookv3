// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The enqueue stuck gate's two rules. Cohorts are placed with the default
/// policy (delay 1_000 on the 200 ms channel): an order at `BASE + k * 200`
/// gets τ = `BASE + 1_000 + k * 200`.
#[test_only]
module deepbook_predict_orders::stuck_gate_tests;

use deepbook_predict_orders::{order_queue::{Self, OrderBook}, order_queue_test_helpers as h};
use std::unit_test::{assert_eq, destroy};

const BASE: u64 = 1_000_000_000;
const STUCK_THRESHOLD: u64 = 1_500;
/// τ of the cohorts placed at BASE, BASE + 200, and BASE + 400.
const TAU_A: u64 = 1_000_001_000;
const TAU_B: u64 = 1_000_001_200;
const TAU_C: u64 = 1_000_001_400;
/// Far past every τ.
const MUCH_LATER: u64 = 1_000_100_000;

const BUDGET: u64 = 1_000_000;
const ORDER_FEE: u64 = 20_000;
const CASH_NEED: u64 = 990_001;

#[test]
fun an_empty_book_is_never_stuck() {
    let ctx = &mut tx_context::dummy();
    let book = order_queue::new_book(ctx);
    assert!(!book.is_stuck(STUCK_THRESHOLD, MUCH_LATER));
    destroy(book);
}

#[test]
fun rule_one_one_stale_cohort_with_nothing_newer_committed() {
    let ctx = &mut tx_context::dummy();
    let mut book = order_queue::new_book(ctx);
    place_cohort(&mut book, BASE);

    // Stale exactly when τ + threshold <= now.
    assert!(!book.is_stuck(STUCK_THRESHOLD, TAU_A + STUCK_THRESHOLD - 1));
    assert!(book.is_stuck(STUCK_THRESHOLD, TAU_A + STUCK_THRESHOLD));
    destroy(book);
}

#[test]
fun rule_one_watches_the_newest_cohort_above_an_older_commit() {
    let ctx = &mut tx_context::dummy();
    let mut book = order_queue::new_book(ctx);
    place_cohort(&mut book, BASE);
    place_cohort(&mut book, BASE + 200);
    // A committed, B not: B's τ is above last_committed_tau_ms.
    book.mark_cohort_committed(0);

    assert!(!book.is_stuck(STUCK_THRESHOLD, TAU_B + STUCK_THRESHOLD - 1));
    assert!(book.is_stuck(STUCK_THRESHOLD, TAU_B + STUCK_THRESHOLD));
    destroy(book);
}

#[test]
fun a_single_missing_tick_with_a_later_cohort_committed_never_sticks() {
    let ctx = &mut tx_context::dummy();
    let mut book = order_queue::new_book(ctx);
    place_cohort(&mut book, BASE);
    place_cohort(&mut book, BASE + 200);
    // B committed, A skipped: A's τ is at or below last_committed_tau_ms, so rule
    // one ignores it, and it is the only stale uncommitted cohort.
    book.mark_cohort_committed(1);

    assert!(!book.is_stuck(STUCK_THRESHOLD, MUCH_LATER));
    destroy(book);
}

#[test]
fun rule_two_two_stale_uncommitted_cohorts_stick_despite_a_later_commit() {
    let ctx = &mut tx_context::dummy();
    let mut book = order_queue::new_book(ctx);
    place_cohort(&mut book, BASE);
    place_cohort(&mut book, BASE + 200);
    place_cohort(&mut book, BASE + 400);
    // A selective filler commits C and leaves A and B.
    book.mark_cohort_committed(2);
    assert_eq!(book.last_committed_tau_ms(), TAU_C);

    // Only A is stale one ms before B turns stale.
    assert!(!book.is_stuck(STUCK_THRESHOLD, TAU_B + STUCK_THRESHOLD - 1));
    // A and B are both stale.
    assert!(book.is_stuck(STUCK_THRESHOLD, TAU_B + STUCK_THRESHOLD));
    destroy(book);
}

#[test]
fun committed_stale_cohorts_never_stick() {
    let ctx = &mut tx_context::dummy();
    let mut book = order_queue::new_book(ctx);
    place_cohort(&mut book, BASE);
    place_cohort(&mut book, BASE + 200);
    book.mark_cohort_committed(0);
    book.mark_cohort_committed(1);

    assert!(!book.is_stuck(STUCK_THRESHOLD, MUCH_LATER));
    destroy(book);
}

fun place_cohort(book: &mut OrderBook, now_ms: u64) {
    h::place_mint(
        book,
        &h::default_policy(),
        now_ms,
        h::account(0),
        h::lower_tick(),
        h::higher_tick(),
        BUDGET,
        ORDER_FEE,
        CASH_NEED,
    );
}
