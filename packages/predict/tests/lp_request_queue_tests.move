// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit coverage for the `lp_request_queue` storage primitive: FIFO indexing,
/// pooled-escrow conservation, hole semantics on `remove`, the monotonic head/tail
/// cursor (carry-over and drain-then-enqueue), and the not-found abort. Expected
/// values are the inputs fed in, summed by hand — independent of the queue code.
#[test_only]
module deepbook_predict::lp_request_queue_tests;

use deepbook_predict::lp_request_queue;
use dusdc::dusdc::DUSDC;
use std::unit_test::{assert_eq, destroy};
use sui::balance;

const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;
const CAROL: address = @0xCA401;

// Distinct escrow amounts so a misrouted entry/escrow is visible.
const A1: u64 = 10_000_000;
const A2: u64 = 25_000_000;
const A3: u64 = 7_000_000;

#[test]
fun enqueue_assigns_sequential_indices_and_pools_escrow() {
    let ctx = &mut tx_context::dummy();
    let mut q = lp_request_queue::new<DUSDC>(ctx);

    let i0 = q.enqueue(ALICE, balance::create_for_testing<DUSDC>(A1));
    let i1 = q.enqueue(BOB, balance::create_for_testing<DUSDC>(A2));
    let i2 = q.enqueue(CAROL, balance::create_for_testing<DUSDC>(A3));

    assert_eq!(i0, 0);
    assert_eq!(i1, 1);
    assert_eq!(i2, 2);
    assert_eq!(q.head(), 0);
    assert_eq!(q.tail(), 3);
    assert_eq!(q.pending(), 3);
    assert_eq!(q.escrow_value(), A1 + A2 + A3);
    assert!(!q.is_empty());
    // The middle entry reads back the exact recipient/amount it was enqueued with.
    assert_eq!(q.borrow(1).recipient(), BOB);
    assert_eq!(q.borrow(1).amount(), A2);

    destroy(q);
}

#[test]
fun remove_splits_exact_escrow_and_leaves_a_hole() {
    let ctx = &mut tx_context::dummy();
    let mut q = lp_request_queue::new<DUSDC>(ctx);
    q.enqueue(ALICE, balance::create_for_testing<DUSDC>(A1));
    q.enqueue(BOB, balance::create_for_testing<DUSDC>(A2));
    q.enqueue(CAROL, balance::create_for_testing<DUSDC>(A3));

    let refund = q.remove(1); // BOB's entry, at a non-head index.

    assert_eq!(refund.value(), A2);
    assert_eq!(q.pending(), 2);
    assert_eq!(q.escrow_value(), A1 + A3);
    // The cursor is untouched: removing a middle index punches a hole, not a shift.
    assert_eq!(q.head(), 0);
    assert_eq!(q.tail(), 3);
    assert!(!q.contains(1));
    assert!(q.contains(0));
    assert!(q.contains(2));

    destroy(refund);
    destroy(q);
}

#[test]
fun drain_from_head_advances_cursor_and_empties() {
    let ctx = &mut tx_context::dummy();
    let mut q = lp_request_queue::new<DUSDC>(ctx);
    q.enqueue(ALICE, balance::create_for_testing<DUSDC>(A1));
    q.enqueue(BOB, balance::create_for_testing<DUSDC>(A2));

    let b0 = q.remove(0);
    q.advance_head();
    assert_eq!(q.head(), 1);
    assert!(!q.is_empty());

    let b1 = q.remove(1);
    q.advance_head();
    assert_eq!(q.head(), 2);
    assert_eq!(q.tail(), 2);
    assert!(q.is_empty());
    assert_eq!(q.pending(), 0);
    assert_eq!(q.escrow_value(), 0);

    // FIFO order: head-first removal returned ALICE then BOB.
    assert_eq!(b0.value(), A1);
    assert_eq!(b1.value(), A2);

    destroy(b0);
    destroy(b1);
    destroy(q);
}

#[test]
fun partial_drain_carries_rest_with_tail_untouched() {
    let ctx = &mut tx_context::dummy();
    let mut q = lp_request_queue::new<DUSDC>(ctx);
    q.enqueue(ALICE, balance::create_for_testing<DUSDC>(A1));
    q.enqueue(BOB, balance::create_for_testing<DUSDC>(A2));
    q.enqueue(CAROL, balance::create_for_testing<DUSDC>(A3));

    // Process only the head entry, then stop (a capped flush).
    let b = q.remove(0);
    q.advance_head();

    assert_eq!(q.head(), 1); // advanced only past the processed entry
    assert_eq!(q.tail(), 3); // tail untouched — the rest carry
    assert_eq!(q.pending(), 2);
    assert_eq!(q.escrow_value(), A2 + A3);
    assert!(!q.is_empty());
    assert!(q.contains(1));
    assert!(q.contains(2));

    destroy(b);
    destroy(q);
}

#[test]
fun enqueue_after_drain_continues_monotonic_cursor() {
    let ctx = &mut tx_context::dummy();
    let mut q = lp_request_queue::new<DUSDC>(ctx);
    q.enqueue(ALICE, balance::create_for_testing<DUSDC>(A1));
    let b = q.remove(0);
    q.advance_head();
    assert!(q.is_empty()); // head == tail == 1

    // A later enqueue continues from the tail, never reusing index 0.
    let i = q.enqueue(BOB, balance::create_for_testing<DUSDC>(A2));
    assert_eq!(i, 1);
    assert_eq!(q.head(), 1);
    assert_eq!(q.tail(), 2);
    assert_eq!(q.pending(), 1);
    assert_eq!(q.escrow_value(), A2);
    assert!(!q.is_empty());

    destroy(b);
    destroy(q);
}

#[test, expected_failure(abort_code = lp_request_queue::ERequestNotFound)]
fun remove_already_removed_index_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut q = lp_request_queue::new<DUSDC>(ctx);
    q.enqueue(ALICE, balance::create_for_testing<DUSDC>(A1));
    destroy(q.remove(0));

    // The entry is gone; a second remove finds no live entry.
    destroy(q.remove(0));

    abort 999
}

#[test, expected_failure(abort_code = lp_request_queue::ERequestNotFound)]
fun borrow_unknown_index_aborts() {
    let ctx = &mut tx_context::dummy();
    let q = lp_request_queue::new<DUSDC>(ctx);
    let _ = q.borrow(0); // empty queue: no entry at index 0.

    abort 999
}
