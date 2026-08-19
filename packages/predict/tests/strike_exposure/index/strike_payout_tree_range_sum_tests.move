// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Area-under-the-payout-profile reads for inventory-skew accounting.
/// `range_payout_sum` must equal the tick-by-tick sum of the settled payout
/// surface, and must not depend on the order boundaries were inserted in.
#[test_only]
module deepbook_predict::strike_payout_tree_range_sum_tests;

use deepbook_predict::{constants, strike_payout_tree::{Self, StrikePayoutTree}};
use std::unit_test::{assert_eq, destroy};

const TICK_SIZE: u64 = 1_000;

/// Sum `W(S)` one settlement tick at a time over `(lower, higher]`, the reference
/// the logarithmic read must reproduce.
fun brute_force_sum(tree: &StrikePayoutTree, lower: u64, higher: u64): u128 {
    let mut total = 0u128;
    let mut tick = lower + 1;
    while (tick <= higher) {
        total = total + (tree.settled_payout_liability(tick * TICK_SIZE, TICK_SIZE) as u128);
        tick = tick + 1;
    };
    total
}

/// (-inf,1] 10; (1,2] 50; (2,3] 40; (3,5] 70; (5,7] 30; (7,8] 0; (8,9] 20.
fun mixed_surface(ctx: &mut TxContext): StrikePayoutTree {
    let mut tree = strike_payout_tree::new(ctx);
    tree.insert_range(0, 2, 10);
    tree.insert_range(1, 5, 40);
    tree.insert_range(3, 7, 30);
    tree.insert_range(8, 9, 20);
    tree
}

#[test]
fun empty_tree_has_zero_area() {
    let ctx = &mut tx_context::dummy();
    let tree = strike_payout_tree::new(ctx);

    assert_eq!(tree.range_payout_sum(0, constants::pos_inf_tick!()), 0);
    assert_eq!(tree.range_payout_sum(2, 6), 0);
    destroy(tree);
}

#[test]
fun empty_or_inverted_range_is_zero() {
    let ctx = &mut tx_context::dummy();
    let tree = mixed_surface(ctx);

    assert_eq!(tree.range_payout_sum(5, 5), 0);
    assert_eq!(tree.range_payout_sum(9, 4), 0);
    destroy(tree);
}

/// The read the plain boundary totals cannot make. Both books carry one order of
/// quantity 1, so `start` and `end` are identical; only the tick-weighted terms
/// separate an eighty-tick span from a one-tick span.
#[test]
fun equal_quantity_orders_are_separated_by_span() {
    let ctx = &mut tx_context::dummy();

    let mut narrow = strike_payout_tree::new(ctx);
    narrow.insert_range(10, 11, 1);

    let mut wide = strike_payout_tree::new(ctx);
    wide.insert_range(10, 90, 1);

    let (narrow_max, narrow_total) = narrow.payout_reserve_terms();
    let (wide_max, wide_total) = wide.payout_reserve_terms();
    assert_eq!(narrow_max, wide_max);
    assert_eq!(narrow_total, wide_total);

    assert_eq!(narrow.range_payout_sum(0, constants::pos_inf_tick!()), 1);
    assert_eq!(wide.range_payout_sum(0, constants::pos_inf_tick!()), 80);

    destroy(narrow);
    destroy(wide);
}

#[test]
fun area_matches_hand_computed_surface() {
    let ctx = &mut tx_context::dummy();
    let tree = mixed_surface(ctx);

    // 10 + 50 + 40 + 70 + 70 + 30 + 30 + 0 + 20 + 0
    assert_eq!(tree.range_payout_sum(0, 10), 320);
    // The open-lower prefix alone.
    assert_eq!(tree.range_payout_sum(0, 1), 10);
    // A window whose interior holds no boundary at all.
    assert_eq!(tree.range_payout_sum(3, 5), 140);
    destroy(tree);
}

#[test]
fun area_matches_brute_force_over_every_window() {
    let ctx = &mut tx_context::dummy();
    let tree = mixed_surface(ctx);

    let mut lower = 0;
    while (lower <= 11) {
        let mut higher = lower;
        while (higher <= 12) {
            assert_eq!(tree.range_payout_sum(lower, higher), brute_force_sum(&tree, lower, higher));
            higher = higher + 1;
        };
        lower = lower + 1;
    };
    destroy(tree);
}

/// Rotations relink nodes but never re-key them, so the tick-weighted terms must
/// be invariant to insertion order. Ascending inserts force left-heavy rebalances
/// that a shape-dependent aggregate would not survive.
#[test]
fun area_is_independent_of_insertion_order() {
    let ctx = &mut tx_context::dummy();

    let mut ascending = strike_payout_tree::new(ctx);
    ascending.insert_range(1, 5, 40);
    ascending.insert_range(3, 7, 30);
    ascending.insert_range(8, 9, 20);
    ascending.insert_range(0, 2, 10);

    let mut descending = strike_payout_tree::new(ctx);
    descending.insert_range(8, 9, 20);
    descending.insert_range(3, 7, 30);
    descending.insert_range(1, 5, 40);
    descending.insert_range(0, 2, 10);

    assert_eq!(
        ascending.range_payout_sum(0, constants::pos_inf_tick!()),
        descending.range_payout_sum(0, constants::pos_inf_tick!()),
    );
    assert_eq!(ascending.range_payout_sum(0, 10), 320);
    assert_eq!(descending.range_payout_sum(0, 10), 320);

    destroy(ascending);
    destroy(descending);
}

/// Removing an order must return the area to exactly where it started, the same
/// exactness the charge/rebate accounting depends on.
#[test]
fun removing_an_order_restores_the_prior_area() {
    let ctx = &mut tx_context::dummy();
    let mut tree = mixed_surface(ctx);

    let before = tree.range_payout_sum(0, 20);
    tree.insert_range(4, 12, 55);
    assert!(tree.range_payout_sum(0, 20) > before);
    tree.remove_range(4, 12, 55);
    assert_eq!(tree.range_payout_sum(0, 20), before);

    destroy(tree);
}

/// An unbounded upper end contributes across the whole finite ladder, which is why
/// a skew window has to clip before calling this.
#[test]
fun open_upper_range_spans_the_finite_ladder() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    tree.insert_range(10, constants::pos_inf_tick!(), 1);

    assert_eq!(tree.range_payout_sum(10, 20), 10);
    assert_eq!(
        tree.range_payout_sum(0, constants::pos_inf_tick!()),
        ((constants::pos_inf_tick!() - 10) as u128),
    );

    destroy(tree);
}
