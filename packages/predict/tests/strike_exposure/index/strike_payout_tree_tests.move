// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit tests for `strike_payout_tree`. The tree keys finite interval boundaries
/// by absolute tick; raw strikes are recovered only at settlement via the caller-
/// supplied `tick_size` (`raw_strike = tick * tick_size`). Range-shape validity
/// (lower < higher, sentinels) is enforced by `order` when ticks are packed, not by
/// the tree, so the only tree-level aborts are the payout-term invariants.
#[test_only]
module deepbook_predict::strike_payout_tree_tests;

use deepbook_predict::{constants, strike_payout_tree::{Self, StrikePayoutTree}};
use std::unit_test::assert_eq;

/// Per-tick raw-strike scale used to turn a settlement tick into a raw oracle
/// price (`settlement = tick * TICK_SIZE`). The exact value is arbitrary for the
/// tree's integer math; small so settlement prices stay hand-checkable.
const TICK_SIZE: u64 = 10_000;
/// A tick comfortably above every key inserted in these tests, used where the old
/// grid tests settled at `max_strike()`.
const HIGH_SETTLEMENT_TICK: u64 = 10;
const DESTROY_INSERT_TICKS: u64 = 10;
const PARTIAL_SURVIVOR_TERMINAL: u64 = 449_992_342;
const PARTIAL_SURVIVOR_LIVE: u64 = 449_992_501;
const LEVERAGED_TERMINAL: u64 = 749_999_737;
const LEVERAGED_LIVE: u64 = 750_000_001;

/// Raw oracle price at the lower edge of `tick` (a settlement equal to a higher
/// boundary still wins under the half-open `(lower, higher]` payoff).
fun settle_at_tick(tick: u64): u64 {
    tick * TICK_SIZE
}

/// Raw oracle price one unit above `tick` (settlement strictly inside the next
/// interval).
fun settle_above_tick(tick: u64): u64 {
    tick * TICK_SIZE + 1
}

fun new_tree(ctx: &mut TxContext): StrikePayoutTree {
    strike_payout_tree::new(ctx)
}

fun insert_range(
    tree: &mut StrikePayoutTree,
    lower_tick: u64,
    higher_tick: u64,
    terminal_payout: u64,
    live_backing_payout: u64,
) {
    tree.insert_range(
        lower_tick,
        higher_tick,
        terminal_payout,
        terminal_payout,
        live_backing_payout,
    );
}

fun remove_range(
    tree: &mut StrikePayoutTree,
    lower_tick: u64,
    higher_tick: u64,
    terminal_payout: u64,
    live_backing_payout: u64,
) {
    tree.remove_range(
        lower_tick,
        higher_tick,
        terminal_payout,
        terminal_payout,
        live_backing_payout,
    );
}

fun assert_settled_at_most_floor(
    tree: &StrikePayoutTree,
    settlement: u64,
    expected_settled: u64,
    floor: u64,
) {
    let settled = tree.settled_payout_liability(settlement, TICK_SIZE);
    assert_eq!(settled, expected_settled);
    assert!(settled <= floor);
}

// === Constructor ===

#[test]
fun new_returns_empty_tree() {
    let ctx = &mut tx_context::dummy();
    let tree = new_tree(ctx);
    // Empty tree has zero conservative backing and zero settled liability at any
    // settlement price.
    assert_eq!(tree.max_live_backing_payout(), 0);
    assert_eq!(tree.settled_payout_liability(settle_at_tick(0), TICK_SIZE), 0);
    assert_eq!(tree.settled_payout_liability(settle_at_tick(HIGH_SETTLEMENT_TICK), TICK_SIZE), 0);
    tree.destroy();
}

// === max_live_backing_payout ===

#[test]
fun insert_open_low_range_returns_backing_at_max_strike() {
    // (neg_inf, tick 5]: backing required for the entire low-prefix bucket. The
    // max live backing prefix is the base value (since the boundary at tick 5
    // closes it).
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);
    insert_range(&mut tree, 0, 5, 100, 100);

    assert_eq!(tree.max_live_backing_payout(), 100);
    tree.destroy();
}

#[test]
fun insert_open_high_range_returns_max_backing() {
    // (tick 5, pos_inf]: backing accrues at tick 5 and never closes.
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);
    insert_range(&mut tree, 5, constants::pos_inf_tick!(), 100, 100);

    assert_eq!(tree.max_live_backing_payout(), 100);
    tree.destroy();
}

#[test]
fun insert_finite_range_returns_max_backing_in_range() {
    // (tick 2, tick 6]: backing is required across the finite gain side.
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);
    insert_range(&mut tree, 2, 6, 50, 50);

    assert_eq!(tree.max_live_backing_payout(), 50);
    tree.destroy();
}

#[test]
fun two_disjoint_ranges_only_count_max_overlap() {
    // (tick 1, tick 3] and (tick 5, tick 7] never overlap, so the peak prefix gain
    // is the single-order backing, not the sum.
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);
    insert_range(&mut tree, 1, 3, 40, 40);
    insert_range(&mut tree, 5, 7, 30, 30);

    assert_eq!(tree.max_live_backing_payout(), 40);
    tree.destroy();
}

#[test]
fun two_overlapping_ranges_sum_backing() {
    // (tick 1, tick 6] and (tick 3, tick 7] overlap on (tick 3, tick 6]; the peak
    // prefix gain is the sum of both backings during the overlap window.
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);
    insert_range(&mut tree, 1, 6, 40, 40);
    insert_range(&mut tree, 3, 7, 30, 30);

    assert_eq!(tree.max_live_backing_payout(), 70);
    tree.destroy();
}

#[test]
fun settled_liability_is_bounded_by_max_live_floor_for_mixed_book() {
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);
    insert_range(&mut tree, 0, 1, 200, 200);
    // Partial-close survivor terms from the C1 gap-one row.
    insert_range(&mut tree, 1, 3, PARTIAL_SURVIVOR_TERMINAL, PARTIAL_SURVIVOR_LIVE);
    // Leveraged 2x UP terms from the compaction parity book.
    insert_range(
        &mut tree,
        2,
        constants::pos_inf_tick!(),
        LEVERAGED_TERMINAL,
        LEVERAGED_LIVE,
    );

    let floor = tree.max_live_backing_payout();
    assert_eq!(floor, PARTIAL_SURVIVOR_LIVE + LEVERAGED_LIVE);
    assert_settled_at_most_floor(&tree, settle_at_tick(0), 200, floor);
    assert_settled_at_most_floor(&tree, settle_at_tick(1), 200, floor);
    assert_settled_at_most_floor(&tree, settle_above_tick(1), PARTIAL_SURVIVOR_TERMINAL, floor);
    assert_settled_at_most_floor(&tree, settle_at_tick(2), PARTIAL_SURVIVOR_TERMINAL, floor);
    assert_settled_at_most_floor(
        &tree,
        settle_above_tick(2),
        PARTIAL_SURVIVOR_TERMINAL + LEVERAGED_TERMINAL,
        floor,
    );
    assert_settled_at_most_floor(
        &tree,
        settle_at_tick(3),
        PARTIAL_SURVIVOR_TERMINAL + LEVERAGED_TERMINAL,
        floor,
    );
    assert_settled_at_most_floor(&tree, settle_above_tick(3), LEVERAGED_TERMINAL, floor);
    assert_settled_at_most_floor(
        &tree,
        settle_at_tick(HIGH_SETTLEMENT_TICK),
        LEVERAGED_TERMINAL,
        floor,
    );
    tree.destroy();
}

// === insert_range early-return and abort cases ===

#[test]
fun insert_with_both_terms_zero_is_no_op() {
    // The module short-circuits on `quantity == 0 && terminal_payout == 0 &&
    // live_backing_payout == 0`. Otherwise EInvalidPayoutTerms would not be reached.
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);
    insert_range(&mut tree, 2, 6, 0, 0);

    assert_eq!(tree.max_live_backing_payout(), 0);
    tree.destroy();
}

#[test, expected_failure(abort_code = strike_payout_tree::EInvalidPayoutTerms)]
fun insert_terminal_greater_than_backing_aborts() {
    // Module invariant: terminal_payout <= live_backing_payout (the live
    // requirement must be at least the terminal liability).
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);
    insert_range(&mut tree, 2, 6, 100, 50);
    abort 999
}

// === remove_range ===

#[test]
fun insert_then_remove_restores_empty_state() {
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);

    insert_range(&mut tree, 2, 6, 50, 50);
    assert_eq!(tree.max_live_backing_payout(), 50);
    remove_range(&mut tree, 2, 6, 50, 50);
    assert_eq!(tree.max_live_backing_payout(), 0);
    tree.destroy();
}

#[test]
fun insert_two_then_remove_one_leaves_other() {
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);

    insert_range(&mut tree, 1, 6, 40, 40);
    insert_range(&mut tree, 3, 7, 30, 30);
    assert_eq!(tree.max_live_backing_payout(), 70);

    remove_range(&mut tree, 3, 7, 30, 30);
    assert_eq!(tree.max_live_backing_payout(), 40);
    tree.destroy();
}

#[test, expected_failure(abort_code = strike_payout_tree::EInsufficientPayoutTerms)]
fun remove_more_than_inserted_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);
    insert_range(&mut tree, 2, 6, 50, 50);
    // Bump both terms together so the EInvalidPayoutTerms shape check passes
    // and the failure surfaces in the boundary delta's available-terms check.
    remove_range(&mut tree, 2, 6, 51, 51);
    abort 999
}

#[test, expected_failure(abort_code = strike_payout_tree::EInsufficientPayoutTerms)]
fun remove_from_empty_tree_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);
    remove_range(&mut tree, 2, 6, 1, 1);
    abort 999
}

// === settled_payout_liability ===

#[test]
fun settled_liability_zero_below_winning_range() {
    // (tick 2, tick 6] only wins for settlement > tick 2.
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);
    insert_range(&mut tree, 2, 6, 50, 50);

    assert_eq!(tree.settled_payout_liability(settle_at_tick(2), TICK_SIZE), 0);
    assert_eq!(tree.settled_payout_liability(settle_at_tick(1), TICK_SIZE), 0);
    tree.destroy();
}

#[test]
fun settled_liability_owed_inside_winning_range() {
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);
    insert_range(&mut tree, 2, 6, 50, 50);

    // (tick 2, tick 6] wins for settlement in the finite interior up to tick 6.
    assert_eq!(tree.settled_payout_liability(settle_at_tick(3), TICK_SIZE), 50);
    assert_eq!(tree.settled_payout_liability(settle_at_tick(6), TICK_SIZE), 50);
    tree.destroy();
}

#[test]
fun settled_liability_zero_above_winning_range() {
    // (tick 2, tick 6] does not win for settlement > tick 6. The higher boundary
    // closes the range out one unit past tick 6.
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);
    insert_range(&mut tree, 2, 6, 50, 50);

    assert_eq!(tree.settled_payout_liability(settle_at_tick(7), TICK_SIZE), 0);
    assert_eq!(
        tree.settled_payout_liability(settle_at_tick(HIGH_SETTLEMENT_TICK), TICK_SIZE),
        0,
    );
    tree.destroy();
}

#[test]
fun settled_liability_neg_inf_range_owed_until_close() {
    // (neg_inf, tick 5] wins for all settlement <= tick 5.
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);
    insert_range(&mut tree, 0, 5, 100, 100);

    assert_eq!(tree.settled_payout_liability(settle_at_tick(0), TICK_SIZE), 100);
    assert_eq!(tree.settled_payout_liability(settle_at_tick(5), TICK_SIZE), 100);
    assert_eq!(tree.settled_payout_liability(settle_at_tick(6), TICK_SIZE), 0);
    tree.destroy();
}

#[test]
fun settled_liability_pos_inf_range_owed_from_lower() {
    // (tick 5, pos_inf] wins for all settlement > tick 5.
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);
    insert_range(&mut tree, 5, constants::pos_inf_tick!(), 100, 100);

    assert_eq!(tree.settled_payout_liability(settle_at_tick(5), TICK_SIZE), 0);
    assert_eq!(tree.settled_payout_liability(settle_at_tick(6), TICK_SIZE), 100);
    assert_eq!(
        tree.settled_payout_liability(settle_at_tick(HIGH_SETTLEMENT_TICK), TICK_SIZE),
        100,
    );
    tree.destroy();
}

#[test]
fun settled_liability_sums_multiple_winners() {
    // Settlement tick 5 wins for both finite ranges. A settlement strictly above
    // the first range wins only the second.
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);
    insert_range(&mut tree, 2, 6, 50, 50);
    insert_range(&mut tree, 4, 7, 30, 30);

    assert_eq!(tree.settled_payout_liability(settle_at_tick(5), TICK_SIZE), 80);
    assert_eq!(tree.settled_payout_liability(settle_at_tick(7), TICK_SIZE), 30);
    assert_eq!(tree.settled_payout_liability(settle_at_tick(8), TICK_SIZE), 0);
    tree.destroy();
}

#[test]
fun settled_liability_uses_terminal_not_backing() {
    // Terminal payout < live backing (e.g. when an order has a floor that
    // grows between open and expiry). settled_payout_liability must report
    // the terminal value, not the (larger) live-backing value.
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);
    insert_range(&mut tree, 2, 6, 30, 50);

    assert_eq!(tree.settled_payout_liability(settle_at_tick(5), TICK_SIZE), 30);
    // Live backing peak still reflects 50.
    assert_eq!(tree.max_live_backing_payout(), 50);
    tree.destroy();
}

// === destroy ===

#[test]
fun destroy_after_many_inserts_succeeds() {
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);
    // Insert across several finite boundaries (ticks 1..=10) to exercise the
    // treap's node-by-node destroy path.
    let mut t = 1;
    while (t <= DESTROY_INSERT_TICKS) {
        insert_range(&mut tree, t, t + 1, 1, 1);
        t = t + 1;
    };
    tree.destroy();
}

#[test]
fun destroy_empty_tree() {
    let ctx = &mut tx_context::dummy();
    let tree = new_tree(ctx);
    tree.destroy();
}
