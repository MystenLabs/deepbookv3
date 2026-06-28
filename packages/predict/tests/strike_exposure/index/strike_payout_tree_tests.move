// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit tests for `strike_payout_tree`. The tree keys finite interval boundaries
/// by absolute tick; raw strikes are recovered only at settlement via the caller-
/// supplied `tick_size` (`raw_strike = tick * tick_size`). Range-shape validity
/// (lower < higher, sentinels) is enforced by `order` when ticks are packed, not by
/// the tree, so the only tree-level abort is removing terms that are not present.
#[test_only]
module deepbook_predict::strike_payout_tree_tests;

use deepbook_predict::{constants, strike_payout_tree::{Self, StrikePayoutTree}};
use std::unit_test::{assert_eq, destroy};

/// Per-tick raw-strike scale used to turn a settlement tick into a raw oracle
/// price (`settlement = tick * TICK_SIZE`). The exact value is arbitrary for the
/// tree's integer math; small so settlement prices stay hand-checkable.
const TICK_SIZE: u64 = 10_000;
/// A tick comfortably above every key inserted in these tests, used where the old
/// grid tests settled at `max_strike()`.
const HIGH_SETTLEMENT_TICK: u64 = 10;
const PARTIAL_SURVIVOR_QUANTITY: u64 = 599_990_000;
const PARTIAL_SURVIVOR_FLOOR_SHARES: u64 = 124_998_049;
const PARTIAL_SURVIVOR_NET_PAYOUT: u64 = 474_991_951;
const LEVERAGED_QUANTITY: u64 = 1_000_000_000;
const LEVERAGED_FLOOR_SHARES: u64 = 249_999_999;
const LEVERAGED_NET_PAYOUT: u64 = 750_000_001;

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
    quantity: u64,
    floor_shares: u64,
) {
    tree.insert_range(
        lower_tick,
        higher_tick,
        quantity,
        floor_shares,
    );
}

fun remove_range(
    tree: &mut StrikePayoutTree,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    floor_shares: u64,
) {
    tree.remove_range(
        lower_tick,
        higher_tick,
        quantity,
        floor_shares,
    );
}

fun assert_reserve_terms(
    tree: &StrikePayoutTree,
    expected_max_net_payout: u64,
    expected_total_net_payout: u64,
) {
    let (max_net_payout, total_net_payout) = tree.net_payout_reserve_terms();
    assert_eq!(max_net_payout, expected_max_net_payout);
    assert_eq!(total_net_payout, expected_total_net_payout);
}

fun assert_settled_at_most_max_net_payout(
    tree: &StrikePayoutTree,
    settlement: u64,
    expected_settled: u64,
    max_net_payout: u64,
) {
    let settled = tree.settled_payout_liability(settlement, TICK_SIZE);
    assert_eq!(settled, expected_settled);
    assert!(settled <= max_net_payout);
}

// === Constructor ===

#[test]
fun new_returns_empty_tree() {
    let ctx = &mut tx_context::dummy();
    let tree = new_tree(ctx);
    // Empty tree has zero conservative backing and zero settled liability at any
    // settlement price.
    assert_reserve_terms(&tree, 0, 0);
    assert_eq!(tree.debug_node_count(), 0);
    assert_eq!(tree.settled_payout_liability(settle_at_tick(0), TICK_SIZE), 0);
    assert_eq!(tree.settled_payout_liability(settle_at_tick(HIGH_SETTLEMENT_TICK), TICK_SIZE), 0);
    destroy(tree);
}

// === net_payout_reserve_terms ===

#[test]
fun insert_open_low_range_returns_backing_at_max_strike() {
    // (neg_inf, tick 5]: backing required for the entire low-prefix bucket. The
    // max live backing prefix is the base value (since the boundary at tick 5
    // closes it).
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);
    insert_range(&mut tree, 0, 5, 100, 0);

    assert_reserve_terms(&tree, 100, 100);
    destroy(tree);
}

#[test]
fun insert_open_high_range_returns_max_backing() {
    // (tick 5, pos_inf]: backing accrues at tick 5 and never closes.
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);
    insert_range(&mut tree, 5, constants::pos_inf_tick!(), 100, 0);

    assert_reserve_terms(&tree, 100, 100);
    destroy(tree);
}

#[test]
fun insert_finite_range_returns_max_backing_in_range() {
    // (tick 2, tick 6]: backing is required across the finite gain side.
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);
    insert_range(&mut tree, 2, 6, 50, 0);

    assert_reserve_terms(&tree, 50, 50);
    destroy(tree);
}

#[test]
fun two_disjoint_ranges_only_count_max_overlap() {
    // (tick 1, tick 3] and (tick 5, tick 7] never overlap, so the peak prefix gain
    // is the single-order backing, not the sum.
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);
    insert_range(&mut tree, 1, 3, 40, 0);
    insert_range(&mut tree, 5, 7, 30, 0);

    assert_reserve_terms(&tree, 40, 70);
    destroy(tree);
}

#[test]
fun two_overlapping_ranges_sum_backing() {
    // (tick 1, tick 6] and (tick 3, tick 7] overlap on (tick 3, tick 6]; the peak
    // prefix gain is the sum of both backings during the overlap window.
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);
    insert_range(&mut tree, 1, 6, 40, 0);
    insert_range(&mut tree, 3, 7, 30, 0);

    assert_reserve_terms(&tree, 70, 70);
    destroy(tree);
}

#[test]
fun settled_liability_is_bounded_by_max_live_floor_for_mixed_book() {
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);
    insert_range(&mut tree, 0, 1, 200, 0);
    // Partial-close survivor terms from the C1 gap-one row, now stored as
    // quantity plus static floor shares.
    insert_range(
        &mut tree,
        1,
        3,
        PARTIAL_SURVIVOR_QUANTITY,
        PARTIAL_SURVIVOR_FLOOR_SHARES,
    );
    // Leveraged UP terms stored as quantity plus static floor shares.
    insert_range(
        &mut tree,
        2,
        constants::pos_inf_tick!(),
        LEVERAGED_QUANTITY,
        LEVERAGED_FLOOR_SHARES,
    );

    let max_net_payout = PARTIAL_SURVIVOR_NET_PAYOUT + LEVERAGED_NET_PAYOUT;
    assert_reserve_terms(
        &tree,
        max_net_payout,
        200 + PARTIAL_SURVIVOR_NET_PAYOUT + LEVERAGED_NET_PAYOUT,
    );
    assert_settled_at_most_max_net_payout(&tree, settle_at_tick(0), 200, max_net_payout);
    assert_settled_at_most_max_net_payout(&tree, settle_at_tick(1), 200, max_net_payout);
    assert_settled_at_most_max_net_payout(
        &tree,
        settle_above_tick(1),
        PARTIAL_SURVIVOR_NET_PAYOUT,
        max_net_payout,
    );
    assert_settled_at_most_max_net_payout(
        &tree,
        settle_at_tick(2),
        PARTIAL_SURVIVOR_NET_PAYOUT,
        max_net_payout,
    );
    assert_settled_at_most_max_net_payout(
        &tree,
        settle_above_tick(2),
        PARTIAL_SURVIVOR_NET_PAYOUT + LEVERAGED_NET_PAYOUT,
        max_net_payout,
    );
    assert_settled_at_most_max_net_payout(
        &tree,
        settle_at_tick(3),
        PARTIAL_SURVIVOR_NET_PAYOUT + LEVERAGED_NET_PAYOUT,
        max_net_payout,
    );
    assert_settled_at_most_max_net_payout(
        &tree,
        settle_above_tick(3),
        LEVERAGED_NET_PAYOUT,
        max_net_payout,
    );
    assert_settled_at_most_max_net_payout(
        &tree,
        settle_at_tick(HIGH_SETTLEMENT_TICK),
        LEVERAGED_NET_PAYOUT,
        max_net_payout,
    );
    destroy(tree);
}

// === insert_range early-return and abort cases ===

#[test]
fun insert_with_both_terms_zero_is_no_op() {
    // The module short-circuits on `quantity == 0 && floor_shares == 0`.
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);
    insert_range(&mut tree, 2, 6, 0, 0);

    assert_reserve_terms(&tree, 0, 0);
    assert_eq!(tree.debug_node_count(), 0);
    destroy(tree);
}

#[test, expected_failure(abort_code = strike_payout_tree::EMaxPayoutTreeNodes)]
fun insert_new_boundary_above_node_cap_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);
    seed_single_boundary_at_node_cap(&mut tree);

    insert_range(
        &mut tree,
        2,
        constants::pos_inf_tick!(),
        1,
        0,
    );
    abort 999
}

#[test, expected_failure(abort_code = strike_payout_tree::EMaxPayoutTreeNodes)]
fun insert_finite_range_requiring_two_new_boundaries_above_node_cap_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);
    seed_single_boundary_one_slot_below_node_cap(&mut tree);

    insert_range(&mut tree, 2, 3, 1, 0);
    abort 999
}

#[test]
fun insert_existing_boundary_at_node_cap_succeeds() {
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);
    seed_single_boundary_at_node_cap(&mut tree);

    insert_range(&mut tree, 1, constants::pos_inf_tick!(), 1, 0);

    assert_eq!(tree.debug_node_count(), constants::max_payout_tree_nodes!());
    destroy(tree);
}

#[test]
fun removing_boundary_below_node_cap_allows_new_boundary() {
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);
    seed_single_boundary_at_node_cap(&mut tree);

    remove_range(&mut tree, 1, constants::pos_inf_tick!(), 1, 0);
    assert_eq!(tree.debug_node_count(), constants::max_payout_tree_nodes!() - 1);

    insert_range(
        &mut tree,
        2,
        constants::pos_inf_tick!(),
        1,
        0,
    );
    assert_eq!(tree.debug_node_count(), constants::max_payout_tree_nodes!());
    destroy(tree);
}

// === remove_range ===

#[test]
fun insert_then_remove_restores_empty_state() {
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);

    insert_range(&mut tree, 2, 6, 50, 0);
    assert_reserve_terms(&tree, 50, 50);
    assert!(tree.debug_contains_node(2));
    assert!(tree.debug_contains_node(6));
    assert_eq!(tree.debug_node_count(), 2);

    remove_range(&mut tree, 2, 6, 50, 0);
    assert_reserve_terms(&tree, 0, 0);
    assert!(!tree.debug_contains_node(2));
    assert!(!tree.debug_contains_node(6));
    assert_eq!(tree.debug_node_count(), 0);
    destroy(tree);
}

#[test]
fun insert_two_then_remove_one_leaves_other() {
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);

    insert_range(&mut tree, 1, 6, 40, 0);
    insert_range(&mut tree, 3, 7, 30, 0);
    assert_reserve_terms(&tree, 70, 70);
    assert_eq!(tree.debug_node_count(), 4);

    remove_range(&mut tree, 3, 7, 30, 0);
    assert_reserve_terms(&tree, 40, 40);
    assert!(tree.debug_contains_node(1));
    assert!(tree.debug_contains_node(6));
    assert!(!tree.debug_contains_node(3));
    assert!(!tree.debug_contains_node(7));
    assert_eq!(tree.debug_node_count(), 2);
    destroy(tree);
}

#[test]
fun remove_adjacent_range_preserves_shared_live_boundary() {
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);

    insert_range(&mut tree, 1, 3, 40, 0);
    insert_range(&mut tree, 3, 7, 30, 0);
    assert_eq!(tree.debug_node_count(), 3);

    remove_range(&mut tree, 1, 3, 40, 0);
    assert_reserve_terms(&tree, 30, 30);
    assert!(!tree.debug_contains_node(1));
    assert!(tree.debug_contains_node(3));
    assert!(tree.debug_contains_node(7));
    assert_eq!(tree.debug_node_count(), 2);
    destroy(tree);
}

#[test, expected_failure(abort_code = strike_payout_tree::EInsufficientPayoutTerms)]
fun remove_more_than_inserted_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);
    insert_range(&mut tree, 2, 6, 50, 0);
    remove_range(&mut tree, 2, 6, 51, 0);
    abort 999
}

#[test, expected_failure(abort_code = strike_payout_tree::EInsufficientPayoutTerms)]
fun remove_from_empty_tree_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);
    remove_range(&mut tree, 2, 6, 1, 0);
    abort 999
}

// === settled_payout_liability ===

#[test]
fun settled_liability_zero_below_winning_range() {
    // (tick 2, tick 6] only wins for settlement > tick 2.
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);
    insert_range(&mut tree, 2, 6, 50, 0);

    assert_eq!(tree.settled_payout_liability(settle_at_tick(2), TICK_SIZE), 0);
    assert_eq!(tree.settled_payout_liability(settle_at_tick(1), TICK_SIZE), 0);
    destroy(tree);
}

#[test]
fun settled_liability_owed_inside_winning_range() {
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);
    insert_range(&mut tree, 2, 6, 50, 0);

    // (tick 2, tick 6] wins for settlement in the finite interior up to tick 6.
    assert_eq!(tree.settled_payout_liability(settle_at_tick(3), TICK_SIZE), 50);
    assert_eq!(tree.settled_payout_liability(settle_at_tick(6), TICK_SIZE), 50);
    destroy(tree);
}

#[test]
fun settled_liability_zero_above_winning_range() {
    // (tick 2, tick 6] does not win for settlement > tick 6. The higher boundary
    // closes the range out one unit past tick 6.
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);
    insert_range(&mut tree, 2, 6, 50, 0);

    assert_eq!(tree.settled_payout_liability(settle_at_tick(7), TICK_SIZE), 0);
    assert_eq!(tree.settled_payout_liability(settle_at_tick(HIGH_SETTLEMENT_TICK), TICK_SIZE), 0);
    destroy(tree);
}

#[test]
fun settled_liability_neg_inf_range_owed_until_close() {
    // (neg_inf, tick 5] wins for all settlement <= tick 5.
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);
    insert_range(&mut tree, 0, 5, 100, 0);

    assert_eq!(tree.settled_payout_liability(settle_at_tick(0), TICK_SIZE), 100);
    assert_eq!(tree.settled_payout_liability(settle_at_tick(5), TICK_SIZE), 100);
    assert_eq!(tree.settled_payout_liability(settle_at_tick(6), TICK_SIZE), 0);
    destroy(tree);
}

#[test]
fun settled_liability_pos_inf_range_owed_from_lower() {
    // (tick 5, pos_inf] wins for all settlement > tick 5.
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);
    insert_range(&mut tree, 5, constants::pos_inf_tick!(), 100, 0);

    assert_eq!(tree.settled_payout_liability(settle_at_tick(5), TICK_SIZE), 0);
    assert_eq!(tree.settled_payout_liability(settle_at_tick(6), TICK_SIZE), 100);
    assert_eq!(tree.settled_payout_liability(settle_at_tick(HIGH_SETTLEMENT_TICK), TICK_SIZE), 100);
    destroy(tree);
}

#[test]
fun settled_liability_sums_multiple_winners() {
    // Settlement tick 5 wins for both finite ranges. A settlement strictly above
    // the first range wins only the second.
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);
    insert_range(&mut tree, 2, 6, 50, 0);
    insert_range(&mut tree, 4, 7, 30, 0);

    assert_eq!(tree.settled_payout_liability(settle_at_tick(5), TICK_SIZE), 80);
    assert_eq!(tree.settled_payout_liability(settle_at_tick(7), TICK_SIZE), 30);
    assert_eq!(tree.settled_payout_liability(settle_at_tick(8), TICK_SIZE), 0);
    destroy(tree);
}

#[test]
fun settled_liability_nets_floor_shares() {
    // The tree stores quantity and static floor shares; settled payout is the
    // derived net payout `quantity - floor_shares`.
    let ctx = &mut tx_context::dummy();
    let mut tree = new_tree(ctx);
    insert_range(&mut tree, 2, 6, 50, 20);

    assert_eq!(tree.settled_payout_liability(settle_at_tick(5), TICK_SIZE), 30);
    assert_reserve_terms(&tree, 30, 30);
    destroy(tree);
}

fun seed_single_boundary_at_node_cap(tree: &mut StrikePayoutTree) {
    insert_range(tree, 1, constants::pos_inf_tick!(), 1, 0);
    tree.debug_set_node_count(constants::max_payout_tree_nodes!());
}

fun seed_single_boundary_one_slot_below_node_cap(tree: &mut StrikePayoutTree) {
    insert_range(tree, 1, constants::pos_inf_tick!(), 1, 0);
    tree.debug_set_node_count(constants::max_payout_tree_nodes!() - 1);
}
