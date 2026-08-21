// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Coverage for `range_weighted_payout_sum` and the frozen boundary weights.
/// Every expectation is derived by hand from the per-position identity
/// `read(Q) = sum(q_i * (U(max(lo_i, lo_Q)) - U(min(hi_i, hi_Q))))` over the
/// positions intersecting `Q` — never from the tree's own arithmetic.
#[test_only]
module deepbook_predict::strike_payout_tree_weighted_sum_tests;

use deepbook_predict::{constants, strike_payout_tree::{Self, StrikePayoutTree}};
use std::unit_test::assert_eq;
use sui::{test_scenario, tx_context::TxContext};

/// Total mass at the open-lower sentinel.
const TOTAL: u64 = 1_000_000_000;

/// A strictly decreasing weight per tick, standing in for a frozen survival
/// function: monotone, positive across every tick these tests touch.
fun w(tick: u64): u64 {
    TOTAL - tick * 1_000_000
}

fun mass(lower_tick: u64, higher_tick: u64): u128 {
    ((w(lower_tick) - w(higher_tick)) as u128)
}

fun new_tree(ctx: &mut TxContext): StrikePayoutTree {
    strike_payout_tree::new(ctx)
}

fun insert(tree: &mut StrikePayoutTree, lower_tick: u64, higher_tick: u64, quantity: u64) {
    let higher_weight = if (higher_tick == constants::pos_inf_tick!()) {
        0
    } else {
        w(higher_tick)
    };
    tree.insert_range(lower_tick, higher_tick, quantity, w(lower_tick), higher_weight);
}

fun read(tree: &StrikePayoutTree, lower_tick: u64, higher_tick: u64): u128 {
    let higher_weight = if (higher_tick == constants::pos_inf_tick!()) {
        0
    } else {
        w(higher_tick)
    };
    tree.range_weighted_payout_sum(lower_tick, higher_tick, w(lower_tick), higher_weight)
}

#[test]
fun an_empty_tree_reads_zero() {
    let mut scenario = test_scenario::begin(@0xA);
    let tree = new_tree(scenario.ctx());
    assert_eq!(read(&tree, 2, 9), 0);
    sui::test_utils::destroy(tree);
    scenario.end();
}

#[test]
fun a_single_range_reads_its_own_weighted_mass() {
    let mut scenario = test_scenario::begin(@0xA);
    let mut tree = new_tree(scenario.ctx());
    insert(&mut tree, 2, 6, 100);

    assert_eq!(read(&tree, 2, 6), 100 * mass(2, 6));
    // A sub-range sees only the mass between its own bounds.
    assert_eq!(read(&tree, 3, 5), 100 * mass(3, 5));
    // A range past the position sees nothing.
    assert_eq!(read(&tree, 6, 9), 0);

    sui::test_utils::destroy(tree);
    scenario.end();
}

#[test]
fun overlapping_ranges_sum_their_clipped_masses() {
    let mut scenario = test_scenario::begin(@0xA);
    let mut tree = new_tree(scenario.ctx());
    insert(&mut tree, 1, 4, 40);
    insert(&mut tree, 3, 8, 30);

    // Position one overlaps `(2, 4]`, position two `(3, 6]`.
    assert_eq!(read(&tree, 2, 6), 40 * mass(2, 4) + 30 * mass(3, 6));
    // The full span reads both positions whole.
    assert_eq!(read(&tree, 0, 9), 40 * mass(1, 4) + 30 * mass(3, 8));

    sui::test_utils::destroy(tree);
    scenario.end();
}

#[test]
fun open_ended_ranges_read_through_the_sentinels() {
    let mut scenario = test_scenario::begin(@0xA);
    let mut tree = new_tree(scenario.ctx());
    // Open-lower quantity lands in `base`; an unterminated upper leg stores no
    // end boundary at all.
    insert(&mut tree, 0, 5, 70);
    insert(&mut tree, 9, constants::pos_inf_tick!(), 20);

    assert_eq!(read(&tree, 0, 5), 70 * mass(0, 5));
    assert_eq!(read(&tree, 2, 5), 70 * mass(2, 5));
    // `U` at the top sentinel is zero, so the upper leg's mass is all of `w(9)`.
    assert_eq!(read(&tree, 9, constants::pos_inf_tick!()), 20 * (w(9) as u128));
    assert_eq!(read(&tree, 0, constants::pos_inf_tick!()), 70 * mass(0, 5) + 20 * (w(9) as u128));

    sui::test_utils::destroy(tree);
    scenario.end();
}

/// The linearity the fold's exact reversal stands on: inserting a range moves the
/// read over that same range by exactly `quantity * (U(lower) - U(higher))`, on a
/// book already carrying overlapping positions and interior boundaries.
#[test]
fun an_insert_moves_the_read_by_exactly_its_own_weighted_mass() {
    let mut scenario = test_scenario::begin(@0xA);
    let mut tree = new_tree(scenario.ctx());
    insert(&mut tree, 0, 7, 15);
    insert(&mut tree, 2, 11, 25);
    insert(&mut tree, 4, 6, 35);

    let before = read(&tree, 3, 9);
    insert(&mut tree, 3, 9, 50);
    assert_eq!(read(&tree, 3, 9), before + 50 * mass(3, 9));

    tree.remove_range(3, 9, 50);
    assert_eq!(read(&tree, 3, 9), before);

    sui::test_utils::destroy(tree);
    scenario.end();
}

/// Rotations and boundary garbage collection preserve the weighted moments: a
/// ladder of inserts deep enough to rebalance, partially drained, still reads
/// exactly what the surviving positions imply.
#[test]
fun a_rebalanced_partially_drained_book_reads_exactly() {
    let mut scenario = test_scenario::begin(@0xA);
    let mut tree = new_tree(scenario.ctx());
    let mut tick = 1;
    while (tick <= 12) {
        insert(&mut tree, tick, tick + 3, 10);
        tick = tick + 1;
    };
    tree.remove_range(4, 7, 10);
    tree.remove_range(9, 12, 10);

    let mut expected = 0u128;
    let mut lower = 1;
    while (lower <= 12) {
        if (lower != 4 && lower != 9) {
            expected = expected + 10 * mass(lower, lower + 3);
        };
        lower = lower + 1;
    };
    assert_eq!(read(&tree, 0, 16), expected);

    sui::test_utils::destroy(tree);
    scenario.end();
}

/// A reused boundary must arrive with the weight it already stores: the weight is
/// a pure function of tick under one frozen measure, so a mismatch is a caller
/// pricing against a different measure.
#[test, expected_failure(abort_code = strike_payout_tree::EBoundaryWeightMismatch)]
fun a_reused_boundary_with_a_different_weight_aborts() {
    let mut scenario = test_scenario::begin(@0xA);
    let mut tree = new_tree(scenario.ctx());
    insert(&mut tree, 2, 6, 100);
    tree.insert_range(2, 9, 100, w(2) + 1, w(9));
    abort 999
}

#[test, expected_failure(abort_code = strike_payout_tree::EInvertedWeights)]
fun inverted_weights_abort_the_read() {
    let mut scenario = test_scenario::begin(@0xA);
    let mut tree = new_tree(scenario.ctx());
    insert(&mut tree, 2, 6, 100);
    let _ = tree.range_weighted_payout_sum(2, 6, w(6), w(2));
    abort 999
}

#[test, expected_failure(abort_code = strike_payout_tree::EInvertedRange)]
fun an_inverted_range_aborts_the_read() {
    let mut scenario = test_scenario::begin(@0xA);
    let mut tree = new_tree(scenario.ctx());
    insert(&mut tree, 2, 6, 100);
    let _ = tree.range_weighted_payout_sum(6, 2, w(2), w(2));
    abort 999
}
