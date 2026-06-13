// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::strike_payout_tree_tests;

use deepbook_predict::{
    constants,
    strike_grid::{Self, StrikeGrid},
    strike_payout_tree::{Self, StrikePayoutTree}
};
use std::unit_test::assert_eq;

// Production-shaped grid whose first finite boundaries are still small enough
// for hand-checkable test ranges: 100_000, 110_000, 120_000, ...
const MIN_STRIKE: u64 = 100_000;
const TICK_SIZE: u64 = 10_000;
const DESTROY_INSERT_TICKS: u64 = 10;
const PARTIAL_SURVIVOR_TERMINAL: u64 = 449_992_342;
const PARTIAL_SURVIVOR_LIVE: u64 = 449_992_501;
const LEVERAGED_TERMINAL: u64 = 749_999_737;
const LEVERAGED_LIVE: u64 = 750_000_001;

fun grid_center_spot(): u64 {
    MIN_STRIKE + TICK_SIZE * (constants::oracle_strike_grid_ticks!() / 2)
}

fun max_strike(): u64 {
    MIN_STRIKE + TICK_SIZE * constants::oracle_strike_grid_ticks!()
}

fun strike(tick_offset: u64): u64 {
    MIN_STRIKE + tick_offset * TICK_SIZE
}

fun grid(): StrikeGrid {
    strike_grid::new_centered(grid_center_spot(), TICK_SIZE)
}

fun new_tree(ctx: &mut TxContext): (StrikeGrid, StrikePayoutTree) {
    let grid = grid();
    let tree = strike_payout_tree::new(ctx);
    (grid, tree)
}

fun insert_range(
    tree: &mut StrikePayoutTree,
    grid: &StrikeGrid,
    lower: u64,
    higher: u64,
    terminal_payout: u64,
    live_backing_payout: u64,
) {
    tree.insert_range(
        grid,
        lower,
        higher,
        terminal_payout,
        terminal_payout,
        live_backing_payout,
    );
}

fun remove_range(
    tree: &mut StrikePayoutTree,
    grid: &StrikeGrid,
    lower: u64,
    higher: u64,
    terminal_payout: u64,
    live_backing_payout: u64,
) {
    tree.remove_range(
        grid,
        lower,
        higher,
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
    let settled = tree.settled_payout_liability(settlement);
    assert_eq!(settled, expected_settled);
    assert!(settled <= floor);
}

// === Constructor (new + grid validation) ===

#[test]
fun new_returns_empty_tree() {
    let ctx = &mut tx_context::dummy();
    let (_grid, tree) = new_tree(ctx);
    // Empty tree has zero conservative backing and zero settled liability at any
    // settlement price.
    assert_eq!(tree.max_live_backing_payout(), 0);
    assert_eq!(tree.settled_payout_liability(MIN_STRIKE), 0);
    assert_eq!(tree.settled_payout_liability(max_strike()), 0);
    tree.destroy();
}

// === max_live_backing_payout ===

#[test]
fun insert_open_low_range_returns_backing_at_max_strike() {
    // (neg_inf, strike(5)]: backing required for the entire low-prefix bucket. The
    // max live backing prefix is the base value (since the boundary at strike(5)
    // closes it).
    let ctx = &mut tx_context::dummy();
    let (grid, mut tree) = new_tree(ctx);
    insert_range(&mut tree, &grid, constants::neg_inf!(), strike(5), 100, 100);

    assert_eq!(tree.max_live_backing_payout(), 100);
    tree.destroy();
}

#[test]
fun insert_open_high_range_returns_max_backing() {
    // (strike(5), pos_inf]: backing accrues at strike(5) and never closes.
    let ctx = &mut tx_context::dummy();
    let (grid, mut tree) = new_tree(ctx);
    insert_range(&mut tree, &grid, strike(5), constants::pos_inf!(), 100, 100);

    assert_eq!(tree.max_live_backing_payout(), 100);
    tree.destroy();
}

#[test]
fun insert_finite_range_returns_max_backing_in_range() {
    // (strike(2), strike(6)]: backing is required across the finite gain side.
    let ctx = &mut tx_context::dummy();
    let (grid, mut tree) = new_tree(ctx);
    insert_range(&mut tree, &grid, strike(2), strike(6), 50, 50);

    assert_eq!(tree.max_live_backing_payout(), 50);
    tree.destroy();
}

#[test]
fun two_disjoint_ranges_only_count_max_overlap() {
    // (strike(1), strike(3)] and (strike(5), strike(7)] never overlap, so the peak prefix gain is the
    // single-order backing, not the sum.
    let ctx = &mut tx_context::dummy();
    let (grid, mut tree) = new_tree(ctx);
    insert_range(&mut tree, &grid, strike(1), strike(3), 40, 40);
    insert_range(&mut tree, &grid, strike(5), strike(7), 30, 30);

    assert_eq!(tree.max_live_backing_payout(), 40);
    tree.destroy();
}

#[test]
fun two_overlapping_ranges_sum_backing() {
    // (strike(1), strike(6)] and (strike(3), strike(7)] overlap on (strike(3), strike(6)]; the peak prefix gain
    // is the sum of both backings during the overlap window.
    let ctx = &mut tx_context::dummy();
    let (grid, mut tree) = new_tree(ctx);
    insert_range(&mut tree, &grid, strike(1), strike(6), 40, 40);
    insert_range(&mut tree, &grid, strike(3), strike(7), 30, 30);

    assert_eq!(tree.max_live_backing_payout(), 70);
    tree.destroy();
}

#[test]
fun settled_liability_is_bounded_by_max_live_floor_for_mixed_book() {
    let ctx = &mut tx_context::dummy();
    let (grid, mut tree) = new_tree(ctx);
    insert_range(&mut tree, &grid, constants::neg_inf!(), strike(1), 200, 200);
    // Partial-close survivor terms from the C1 gap-one row.
    insert_range(
        &mut tree,
        &grid,
        strike(1),
        strike(3),
        PARTIAL_SURVIVOR_TERMINAL,
        PARTIAL_SURVIVOR_LIVE,
    );
    // Leveraged 2x UP terms from the compaction parity book.
    insert_range(
        &mut tree,
        &grid,
        strike(2),
        constants::pos_inf!(),
        LEVERAGED_TERMINAL,
        LEVERAGED_LIVE,
    );

    let floor = tree.max_live_backing_payout();
    assert_eq!(floor, PARTIAL_SURVIVOR_LIVE + LEVERAGED_LIVE);
    assert_settled_at_most_floor(&tree, MIN_STRIKE, 200, floor);
    assert_settled_at_most_floor(&tree, strike(1), 200, floor);
    assert_settled_at_most_floor(&tree, strike(1) + 1, PARTIAL_SURVIVOR_TERMINAL, floor);
    assert_settled_at_most_floor(&tree, strike(2), PARTIAL_SURVIVOR_TERMINAL, floor);
    assert_settled_at_most_floor(
        &tree,
        strike(2) + 1,
        PARTIAL_SURVIVOR_TERMINAL + LEVERAGED_TERMINAL,
        floor,
    );
    assert_settled_at_most_floor(
        &tree,
        strike(3),
        PARTIAL_SURVIVOR_TERMINAL + LEVERAGED_TERMINAL,
        floor,
    );
    assert_settled_at_most_floor(&tree, strike(3) + 1, LEVERAGED_TERMINAL, floor);
    assert_settled_at_most_floor(&tree, max_strike(), LEVERAGED_TERMINAL, floor);
    tree.destroy();
}

// === insert_range early-return and abort cases ===

#[test]
fun insert_with_both_terms_zero_is_no_op() {
    // The module short-circuits on `terminal_payout == 0 && live_backing_payout == 0`.
    // Otherwise EInvalidPayoutTerms would not even be reached.
    let ctx = &mut tx_context::dummy();
    let (grid, mut tree) = new_tree(ctx);
    insert_range(&mut tree, &grid, strike(2), strike(6), 0, 0);

    assert_eq!(tree.max_live_backing_payout(), 0);
    tree.destroy();
}

#[test, expected_failure(abort_code = strike_payout_tree::EInvalidPayoutTerms)]
fun insert_terminal_greater_than_backing_aborts() {
    // Module invariant: terminal_payout <= live_backing_payout (the live
    // requirement must be at least the terminal liability).
    let ctx = &mut tx_context::dummy();
    let (grid, mut tree) = new_tree(ctx);
    insert_range(&mut tree, &grid, strike(2), strike(6), 100, 50);
    abort 999
}

#[test, expected_failure(abort_code = strike_grid::EInvalidStrikeGrid)]
fun insert_lower_equal_higher_aborts() {
    let ctx = &mut tx_context::dummy();
    let (grid, mut tree) = new_tree(ctx);
    insert_range(&mut tree, &grid, strike(5), strike(5), 10, 10);
    abort 999
}

#[test, expected_failure(abort_code = strike_grid::EInvalidStrikeGrid)]
fun insert_lower_above_higher_aborts() {
    let ctx = &mut tx_context::dummy();
    let (grid, mut tree) = new_tree(ctx);
    insert_range(&mut tree, &grid, strike(6), strike(4), 10, 10);
    abort 999
}

#[test, expected_failure(abort_code = strike_grid::EInvalidStrikeGrid)]
fun insert_full_open_range_aborts() {
    // (neg_inf, pos_inf] is rejected to keep settlement liability finite.
    let ctx = &mut tx_context::dummy();
    let (grid, mut tree) = new_tree(ctx);
    insert_range(&mut tree, &grid, constants::neg_inf!(), constants::pos_inf!(), 10, 10);
    abort 999
}

#[test, expected_failure(abort_code = strike_grid::EInvalidStrikeGrid)]
fun insert_finite_below_grid_aborts() {
    let ctx = &mut tx_context::dummy();
    let (grid, mut tree) = new_tree(ctx);
    insert_range(&mut tree, &grid, MIN_STRIKE - TICK_SIZE, strike(5), 10, 10);
    abort 999
}

#[test, expected_failure(abort_code = strike_grid::EInvalidStrikeGrid)]
fun insert_finite_above_grid_aborts() {
    let ctx = &mut tx_context::dummy();
    let (grid, mut tree) = new_tree(ctx);
    insert_range(&mut tree, &grid, strike(5), max_strike() + TICK_SIZE, 10, 10);
    abort 999
}

#[test, expected_failure(abort_code = strike_grid::EInvalidStrikeGrid)]
fun insert_unaligned_strike_aborts() {
    let ctx = &mut tx_context::dummy();
    let (grid, mut tree) = new_tree(ctx);
    insert_range(&mut tree, &grid, strike(1) + TICK_SIZE / 2, strike(5), 10, 10);
    abort 999
}

// === remove_range ===

#[test]
fun insert_then_remove_restores_empty_state() {
    let ctx = &mut tx_context::dummy();
    let (grid, mut tree) = new_tree(ctx);

    insert_range(&mut tree, &grid, strike(2), strike(6), 50, 50);
    assert_eq!(tree.max_live_backing_payout(), 50);
    remove_range(&mut tree, &grid, strike(2), strike(6), 50, 50);
    assert_eq!(tree.max_live_backing_payout(), 0);
    tree.destroy();
}

#[test]
fun insert_two_then_remove_one_leaves_other() {
    let ctx = &mut tx_context::dummy();
    let (grid, mut tree) = new_tree(ctx);

    insert_range(&mut tree, &grid, strike(1), strike(6), 40, 40);
    insert_range(&mut tree, &grid, strike(3), strike(7), 30, 30);
    assert_eq!(tree.max_live_backing_payout(), 70);

    remove_range(&mut tree, &grid, strike(3), strike(7), 30, 30);
    assert_eq!(tree.max_live_backing_payout(), 40);
    tree.destroy();
}

#[test, expected_failure(abort_code = strike_payout_tree::EInsufficientPayoutTerms)]
fun remove_more_than_inserted_aborts() {
    let ctx = &mut tx_context::dummy();
    let (grid, mut tree) = new_tree(ctx);
    insert_range(&mut tree, &grid, strike(2), strike(6), 50, 50);
    // Bump both terms together so the EInvalidPayoutTerms shape check passes
    // and the failure surfaces in the boundary delta's available-terms check.
    remove_range(&mut tree, &grid, strike(2), strike(6), 51, 51);
    abort 999
}

#[test, expected_failure(abort_code = strike_payout_tree::EInsufficientPayoutTerms)]
fun remove_from_empty_tree_aborts() {
    let ctx = &mut tx_context::dummy();
    let (grid, mut tree) = new_tree(ctx);
    remove_range(&mut tree, &grid, strike(2), strike(6), 1, 1);
    abort 999
}

// === settled_payout_liability ===

#[test]
fun settled_liability_zero_below_winning_range() {
    // (strike(2), strike(6)] only wins for settlement > strike(2).
    let ctx = &mut tx_context::dummy();
    let (grid, mut tree) = new_tree(ctx);
    insert_range(&mut tree, &grid, strike(2), strike(6), 50, 50);

    assert_eq!(tree.settled_payout_liability(strike(2)), 0);
    assert_eq!(tree.settled_payout_liability(strike(1)), 0);
    tree.destroy();
}

#[test]
fun settled_liability_owed_inside_winning_range() {
    let ctx = &mut tx_context::dummy();
    let (grid, mut tree) = new_tree(ctx);
    insert_range(&mut tree, &grid, strike(2), strike(6), 50, 50);

    // (strike(2), strike(6)] means winning for settlement in the finite interior up to strike(6).
    assert_eq!(tree.settled_payout_liability(strike(3)), 50);
    assert_eq!(tree.settled_payout_liability(strike(6)), 50);
    tree.destroy();
}

#[test]
fun settled_liability_zero_above_winning_range() {
    // (strike(2), strike(6)] does not win for settlement > strike(6). The higher boundary closes
    // the range out at strike+1.
    let ctx = &mut tx_context::dummy();
    let (grid, mut tree) = new_tree(ctx);
    insert_range(&mut tree, &grid, strike(2), strike(6), 50, 50);

    assert_eq!(tree.settled_payout_liability(strike(7)), 0);
    assert_eq!(tree.settled_payout_liability(max_strike()), 0);
    tree.destroy();
}

#[test]
fun settled_liability_neg_inf_range_owed_until_close() {
    // (neg_inf, strike(5)] wins for all settlement <= strike(5).
    let ctx = &mut tx_context::dummy();
    let (grid, mut tree) = new_tree(ctx);
    insert_range(&mut tree, &grid, constants::neg_inf!(), strike(5), 100, 100);

    assert_eq!(tree.settled_payout_liability(MIN_STRIKE), 100);
    assert_eq!(tree.settled_payout_liability(strike(5)), 100);
    assert_eq!(tree.settled_payout_liability(strike(6)), 0);
    tree.destroy();
}

#[test]
fun settled_liability_pos_inf_range_owed_from_lower() {
    // (strike(5), pos_inf] wins for all settlement > strike(5).
    let ctx = &mut tx_context::dummy();
    let (grid, mut tree) = new_tree(ctx);
    insert_range(&mut tree, &grid, strike(5), constants::pos_inf!(), 100, 100);

    assert_eq!(tree.settled_payout_liability(strike(5)), 0);
    assert_eq!(tree.settled_payout_liability(strike(6)), 100);
    assert_eq!(tree.settled_payout_liability(max_strike()), 100);
    tree.destroy();
}

#[test]
fun settled_liability_sums_multiple_winners() {
    // Settlement strike(5) wins for both finite ranges. A settlement strictly
    // above the first range wins only the second.
    let ctx = &mut tx_context::dummy();
    let (grid, mut tree) = new_tree(ctx);
    insert_range(&mut tree, &grid, strike(2), strike(6), 50, 50);
    insert_range(&mut tree, &grid, strike(4), strike(7), 30, 30);

    assert_eq!(tree.settled_payout_liability(strike(5)), 80);
    assert_eq!(tree.settled_payout_liability(strike(7)), 30);
    assert_eq!(tree.settled_payout_liability(strike(8)), 0);
    tree.destroy();
}

#[test]
fun settled_liability_uses_terminal_not_backing() {
    // Terminal payout < live backing (e.g. when an order has a floor that
    // grows between open and expiry). settled_payout_liability must report
    // the terminal value, not the (larger) live-backing value.
    let ctx = &mut tx_context::dummy();
    let (grid, mut tree) = new_tree(ctx);
    insert_range(&mut tree, &grid, strike(2), strike(6), 30, 50);

    assert_eq!(tree.settled_payout_liability(strike(5)), 30);
    // Live backing peak still reflects 50.
    assert_eq!(tree.max_live_backing_payout(), 50);
    tree.destroy();
}

// === destroy ===

#[test]
fun destroy_after_many_inserts_succeeds() {
    let ctx = &mut tx_context::dummy();
    let (grid, mut tree) = new_tree(ctx);
    // Insert across several finite boundaries to exercise the treap's
    // node-by-node destroy path.
    let mut i = 0;
    while (i < DESTROY_INSERT_TICKS) {
        insert_range(&mut tree, &grid, strike(i), strike(i + 1), 1, 1);
        i = i + 1;
    };
    tree.destroy();
}

#[test]
fun destroy_empty_tree() {
    let ctx = &mut tx_context::dummy();
    let (_grid, tree) = new_tree(ctx);
    tree.destroy();
}
