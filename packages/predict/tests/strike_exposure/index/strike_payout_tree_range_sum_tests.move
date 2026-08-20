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
/// Hand-summed W(1..10) for each fixture; the derivations sit above each surface.
const MIXED_SURFACE_AREA: u128 = 320;
const OPEN_UPPER_SURFACE_AREA: u128 = 395;
const SHARED_BOUNDARY_SURFACE_AREA: u128 = 240;

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
fun empty_range_is_zero() {
    let ctx = &mut tx_context::dummy();
    let tree = mixed_surface(ctx);

    assert_eq!(tree.range_payout_sum(5, 5), 0);
    destroy(tree);
}

#[test, expected_failure(abort_code = strike_payout_tree::EInvertedRange)]
fun inverted_range_aborts() {
    let ctx = &mut tx_context::dummy();
    let tree = mixed_surface(ctx);
    tree.range_payout_sum(9, 4);
    abort 0
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
    assert_eq!(tree.range_payout_sum(0, 10), MIXED_SURFACE_AREA);
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

/// The same final book reached by two construction paths must report the same
/// area: rotation and node-reclaim history must not be observable. Shape-difference
/// over a churned 66-node tree is covered by `strike_payout_tree_balance_tests`.
#[test]
fun area_is_independent_of_construction_path() {
    let ctx = &mut tx_context::dummy();

    let mut churned = mixed_surface(ctx);
    churned.insert_range(2, 11, 77);
    churned.insert_range(6, 13, 44);
    churned.remove_range(2, 11, 77);
    churned.remove_range(6, 13, 44);

    let direct = mixed_surface(ctx);

    assert_eq!(churned.range_payout_sum(0, 20), direct.range_payout_sum(0, 20));
    assert_eq!(churned.range_payout_sum(0, 20), MIXED_SURFACE_AREA);

    destroy(churned);
    destroy(direct);
}

/// Removing an order must return the area to exactly where it started, the same
/// exactness the charge/rebate accounting depends on.
#[test]
fun removing_an_order_restores_the_prior_area() {
    let ctx = &mut tx_context::dummy();
    let mut tree = mixed_surface(ctx);

    let before = tree.range_payout_sum(0, 20);
    assert_eq!(before, MIXED_SURFACE_AREA);
    // `(4,12]` covers settlement ticks 5..12, so the area rises by 8 * 55.
    tree.insert_range(4, 12, 55);
    assert_eq!(tree.range_payout_sum(0, 20), 760);
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

/// An open-upper leg over a nonzero open-lower prefix: a start boundary with no
/// stored end, which `mixed_surface` never produces.
/// (-inf,2] 10; (2,3] 50; (3,5] 40; (5,8] 65; (8,+inf] 25.
fun open_upper_surface(ctx: &mut TxContext): StrikePayoutTree {
    let mut tree = strike_payout_tree::new(ctx);
    tree.insert_range(0, 3, 10);
    tree.insert_range(2, 8, 40);
    tree.insert_range(5, constants::pos_inf_tick!(), 25);
    tree
}

/// Adjacent orders sharing one boundary tick, so a single node carries both a
/// `local_start` and a `local_end` weighted by the same tick.
fun shared_boundary_surface(ctx: &mut TxContext): StrikePayoutTree {
    let mut tree = strike_payout_tree::new(ctx);
    tree.insert_range(1, 4, 30);
    tree.insert_range(4, 7, 50);
    tree
}

fun assert_matches_brute_force_over_windows(tree: &StrikePayoutTree, limit: u64) {
    let mut lower = 0;
    while (lower <= limit) {
        let mut higher = lower;
        while (higher <= limit) {
            assert_eq!(tree.range_payout_sum(lower, higher), brute_force_sum(tree, lower, higher));
            higher = higher + 1;
        };
        lower = lower + 1;
    };
}

#[test]
fun open_upper_area_matches_brute_force_over_every_window() {
    let ctx = &mut tx_context::dummy();
    let tree = open_upper_surface(ctx);

    assert_matches_brute_force_over_windows(&tree, 12);
    // 10 + 10 + 50 + 40 + 40 + 65 + 65 + 65 + 25 + 25
    assert_eq!(tree.range_payout_sum(0, 10), OPEN_UPPER_SURFACE_AREA);
    destroy(tree);
}

#[test]
fun shared_boundary_area_matches_brute_force_over_every_window() {
    let ctx = &mut tx_context::dummy();
    let tree = shared_boundary_surface(ctx);

    assert_matches_brute_force_over_windows(&tree, 10);
    // (1,4] 30 over ticks 2..4, (4,7] 50 over ticks 5..7.
    assert_eq!(tree.range_payout_sum(0, 10), SHARED_BOUNDARY_SURFACE_AREA);
    destroy(tree);
}

/// Pins the width of the stored weighted terms. The boundary sits at the TOP of the
/// ladder carrying the largest quantity one order may hold, so the stored term is
/// `(pos_inf_tick - 1) * quantity ~= 4.6e22` — past `u64`, which would abort in
/// `boundary_summary`. Placing the same order at a low tick does not pin anything:
/// the returned sum is built in `u128` regardless of what the fields hold.
#[test]
fun ladder_top_boundary_term_exceeds_u64() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);

    let top_tick = constants::pos_inf_tick!() - 1;
    let quantity = (std::u32::max_value!() as u64) * constants::position_lot_size!();
    assert!((top_tick as u128) * (quantity as u128) > (std::u64::max_value!() as u128));

    tree.insert_range(top_tick, constants::pos_inf_tick!(), quantity);

    // Only settlement tick `pos_inf_tick` is covered by the order.
    assert_eq!(tree.range_payout_sum(0, constants::pos_inf_tick!()), (quantity as u128));

    destroy(tree);
}
