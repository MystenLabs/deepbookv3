// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Exact reserve accounting across payout-range shapes and mutations.
#[test_only]
module deepbook_predict::scope_mechanics__intent_accounting__strike_payout_tree_tests;

use deepbook_predict::{constants, strike_payout_tree};
use std::unit_test::{assert_eq, destroy};

const NEG_INF_TICK: u64 = 0;
const LOW_TICK: u64 = 1;
const MID_LOW_TICK: u64 = 3;
const MID_HIGH_TICK: u64 = 6;
const HIGH_TICK: u64 = 8;
const FIRST_QUANTITY: u64 = 40;
const SECOND_QUANTITY: u64 = 30;
const FLOOR_SHARES: u64 = 7;
const NET_FIRST_QUANTITY: u64 = 33;
const ZERO_AMOUNT: u64 = 0;
const RAW_UNIT: u64 = 1;
const TICK_SIZE: u64 = 10_000;
const ACCUMULATION_NODES: u64 = 64;

fun settle_at_tick(tick: u64): u64 {
    tick * TICK_SIZE
}

#[test]
fun empty_and_zero_terms_have_zero_reserve() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    let (empty_max, empty_total) = tree.net_payout_reserve_terms();
    assert_eq!(empty_max, ZERO_AMOUNT);
    assert_eq!(empty_total, ZERO_AMOUNT);

    tree.insert_range(LOW_TICK, HIGH_TICK, ZERO_AMOUNT, ZERO_AMOUNT);
    let (after_max, after_total) = tree.net_payout_reserve_terms();
    assert_eq!(after_max, ZERO_AMOUNT);
    assert_eq!(after_total, ZERO_AMOUNT);
    destroy(tree);
}

#[test]
fun open_and_finite_ranges_reserve_their_net_payout() {
    let ctx = &mut tx_context::dummy();
    let mut open_low = strike_payout_tree::new(ctx);
    open_low.insert_range(NEG_INF_TICK, MID_HIGH_TICK, FIRST_QUANTITY, FLOOR_SHARES);
    let (open_low_max, open_low_total) = open_low.net_payout_reserve_terms();
    assert_eq!(open_low_max, NET_FIRST_QUANTITY);
    assert_eq!(open_low_total, NET_FIRST_QUANTITY);

    let mut open_high = strike_payout_tree::new(ctx);
    open_high.insert_range(
        MID_LOW_TICK,
        constants::pos_inf_tick!(),
        FIRST_QUANTITY,
        FLOOR_SHARES,
    );
    let (open_high_max, open_high_total) = open_high.net_payout_reserve_terms();
    assert_eq!(open_high_max, NET_FIRST_QUANTITY);
    assert_eq!(open_high_total, NET_FIRST_QUANTITY);

    let mut finite = strike_payout_tree::new(ctx);
    finite.insert_range(MID_LOW_TICK, MID_HIGH_TICK, FIRST_QUANTITY, FLOOR_SHARES);
    let (finite_max, finite_total) = finite.net_payout_reserve_terms();
    assert_eq!(finite_max, NET_FIRST_QUANTITY);
    assert_eq!(finite_total, NET_FIRST_QUANTITY);
    destroy(open_low);
    destroy(open_high);
    destroy(finite);
}

#[test]
fun disjoint_ranges_reserve_peak_while_total_sums_both() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    tree.insert_range(LOW_TICK, MID_LOW_TICK, FIRST_QUANTITY, ZERO_AMOUNT);
    tree.insert_range(MID_HIGH_TICK, HIGH_TICK, SECOND_QUANTITY, ZERO_AMOUNT);

    let (max_net_payout, total_net_payout) = tree.net_payout_reserve_terms();

    assert_eq!(max_net_payout, FIRST_QUANTITY);
    assert_eq!(total_net_payout, FIRST_QUANTITY + SECOND_QUANTITY);
    destroy(tree);
}

#[test]
fun overlapping_ranges_reserve_the_overlap_sum() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    tree.insert_range(LOW_TICK, MID_HIGH_TICK, FIRST_QUANTITY, ZERO_AMOUNT);
    tree.insert_range(MID_LOW_TICK, HIGH_TICK, SECOND_QUANTITY, ZERO_AMOUNT);

    let (max_net_payout, total_net_payout) = tree.net_payout_reserve_terms();

    assert_eq!(max_net_payout, FIRST_QUANTITY + SECOND_QUANTITY);
    assert_eq!(total_net_payout, FIRST_QUANTITY + SECOND_QUANTITY);
    destroy(tree);
}

#[test]
fun accumulation_exact_removal_and_reinsertion_restore_expected_terms() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    tree.insert_range(LOW_TICK, HIGH_TICK, FIRST_QUANTITY, FLOOR_SHARES);
    tree.insert_range(LOW_TICK, HIGH_TICK, SECOND_QUANTITY, ZERO_AMOUNT);
    let (accumulated_max, accumulated_total) = tree.net_payout_reserve_terms();
    assert_eq!(accumulated_max, NET_FIRST_QUANTITY + SECOND_QUANTITY);
    assert_eq!(accumulated_total, NET_FIRST_QUANTITY + SECOND_QUANTITY);

    tree.remove_range(LOW_TICK, HIGH_TICK, SECOND_QUANTITY, ZERO_AMOUNT);
    let (survivor_max, survivor_total) = tree.net_payout_reserve_terms();
    assert_eq!(survivor_max, NET_FIRST_QUANTITY);
    assert_eq!(survivor_total, NET_FIRST_QUANTITY);

    tree.remove_range(LOW_TICK, HIGH_TICK, FIRST_QUANTITY, FLOOR_SHARES);
    let (empty_max, empty_total) = tree.net_payout_reserve_terms();
    assert_eq!(empty_max, ZERO_AMOUNT);
    assert_eq!(empty_total, ZERO_AMOUNT);

    tree.insert_range(LOW_TICK, HIGH_TICK, FIRST_QUANTITY, FLOOR_SHARES);
    let (reinserted_max, reinserted_total) = tree.net_payout_reserve_terms();
    assert_eq!(reinserted_max, NET_FIRST_QUANTITY);
    assert_eq!(reinserted_total, NET_FIRST_QUANTITY);
    destroy(tree);
}

#[test]
fun removing_an_interior_range_leaves_the_survivor_state_sheet() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    tree.insert_range(LOW_TICK, MID_HIGH_TICK, FIRST_QUANTITY, ZERO_AMOUNT);
    tree.insert_range(MID_LOW_TICK, HIGH_TICK, SECOND_QUANTITY, ZERO_AMOUNT);
    tree.remove_range(MID_LOW_TICK, HIGH_TICK, SECOND_QUANTITY, ZERO_AMOUNT);

    let (max_net_payout, total_net_payout) = tree.net_payout_reserve_terms();
    assert_eq!(max_net_payout, FIRST_QUANTITY);
    assert_eq!(total_net_payout, FIRST_QUANTITY);
    destroy(tree);
}

#[test]
fun overlapping_winners_sum_and_stay_within_the_reserve_peak() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    tree.insert_range(LOW_TICK, MID_HIGH_TICK, FIRST_QUANTITY, FLOOR_SHARES);
    tree.insert_range(MID_LOW_TICK, HIGH_TICK, SECOND_QUANTITY, ZERO_AMOUNT);
    let (max_net_payout, total_net_payout) = tree.net_payout_reserve_terms();

    let first_only = tree.settled_payout_liability(settle_at_tick(MID_LOW_TICK), TICK_SIZE);
    let overlap = tree.settled_payout_liability(settle_at_tick(MID_HIGH_TICK), TICK_SIZE);
    let second_only = tree.settled_payout_liability(settle_at_tick(HIGH_TICK), TICK_SIZE);

    assert_eq!(first_only, NET_FIRST_QUANTITY);
    assert_eq!(overlap, NET_FIRST_QUANTITY + SECOND_QUANTITY);
    assert_eq!(second_only, SECOND_QUANTITY);
    assert!(first_only <= max_net_payout);
    assert!(overlap <= max_net_payout);
    assert!(second_only <= max_net_payout);
    assert_eq!(max_net_payout, NET_FIRST_QUANTITY + SECOND_QUANTITY);
    assert_eq!(total_net_payout, NET_FIRST_QUANTITY + SECOND_QUANTITY);
    destroy(tree);
}

#[test]
fun many_real_boundaries_walk_hand_counted_prefixes() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    let mut tick = RAW_UNIT;
    while (tick <= ACCUMULATION_NODES) {
        tree.insert_range(tick, constants::pos_inf_tick!(), RAW_UNIT, ZERO_AMOUNT);
        tick = tick + RAW_UNIT;
    };

    assert_eq!(tree.settled_payout_liability(settle_at_tick(RAW_UNIT), TICK_SIZE), ZERO_AMOUNT);
    assert_eq!(tree.settled_payout_liability(settle_at_tick(10), TICK_SIZE), 9);
    assert_eq!(
        tree.settled_payout_liability(
            settle_at_tick(ACCUMULATION_NODES + RAW_UNIT),
            TICK_SIZE,
        ),
        ACCUMULATION_NODES,
    );
    let (max_net_payout, total_net_payout) = tree.net_payout_reserve_terms();
    assert_eq!(max_net_payout, ACCUMULATION_NODES);
    assert_eq!(total_net_payout, ACCUMULATION_NODES);
    destroy(tree);
}

#[test]
fun gc_mutated_tree_matches_rebuilt_survivors() {
    let ctx = &mut tx_context::dummy();
    let mut mutated = strike_payout_tree::new(ctx);
    mutated.insert_range(2, 8, FIRST_QUANTITY, ZERO_AMOUNT);
    mutated.insert_range(4, 10, SECOND_QUANTITY, ZERO_AMOUNT);
    mutated.insert_range(6, 12, 20, ZERO_AMOUNT);
    mutated.remove_range(4, 10, SECOND_QUANTITY, ZERO_AMOUNT);

    let mut rebuilt = strike_payout_tree::new(ctx);
    rebuilt.insert_range(2, 8, FIRST_QUANTITY, ZERO_AMOUNT);
    rebuilt.insert_range(6, 12, 20, ZERO_AMOUNT);

    let mut settlement_tick = RAW_UNIT;
    while (settlement_tick <= 13) {
        let settlement = settle_at_tick(settlement_tick);
        assert_eq!(
            mutated.settled_payout_liability(settlement, TICK_SIZE),
            rebuilt.settled_payout_liability(settlement, TICK_SIZE),
        );
        settlement_tick = settlement_tick + RAW_UNIT;
    };
    let (mutated_max, mutated_total) = mutated.net_payout_reserve_terms();
    let (rebuilt_max, rebuilt_total) = rebuilt.net_payout_reserve_terms();
    assert_eq!(mutated_max, FIRST_QUANTITY + 20);
    assert_eq!(mutated_total, FIRST_QUANTITY + 20);
    assert_eq!(mutated_max, rebuilt_max);
    assert_eq!(mutated_total, rebuilt_total);
    destroy(mutated);
    destroy(rebuilt);
}

#[test]
fun removing_adjacent_range_preserves_shared_live_boundary() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    tree.insert_range(LOW_TICK, MID_LOW_TICK, FIRST_QUANTITY, ZERO_AMOUNT);
    tree.insert_range(MID_LOW_TICK, HIGH_TICK, SECOND_QUANTITY, ZERO_AMOUNT);

    tree.remove_range(LOW_TICK, MID_LOW_TICK, FIRST_QUANTITY, ZERO_AMOUNT);

    assert_eq!(tree.settled_payout_liability(settle_at_tick(MID_LOW_TICK), TICK_SIZE), ZERO_AMOUNT);
    assert_eq!(
        tree.settled_payout_liability(
            settle_at_tick(MID_LOW_TICK) + RAW_UNIT,
            TICK_SIZE,
        ),
        SECOND_QUANTITY,
    );
    assert_eq!(
        tree.settled_payout_liability(settle_at_tick(HIGH_TICK), TICK_SIZE),
        SECOND_QUANTITY,
    );
    let (max_net_payout, total_net_payout) = tree.net_payout_reserve_terms();
    assert_eq!(max_net_payout, SECOND_QUANTITY);
    assert_eq!(total_net_payout, SECOND_QUANTITY);
    destroy(tree);
}
