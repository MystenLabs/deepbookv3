// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Half-open settlement and exact payout-tree node-cap boundaries.
#[test_only]
module deepbook_predict::scope_mechanics__intent_boundary__strike_payout_tree_tests;

use deepbook_predict::{constants, strike_payout_tree};
use std::unit_test::{assert_eq, destroy};

const NEG_INF_TICK: u64 = 0;
const LOWER_TICK: u64 = 2;
const HIGHER_TICK: u64 = 6;
const NEW_TICK: u64 = 9;
const TICK_SIZE: u64 = 10_000;
const RAW_UNIT: u64 = 1;
const QUANTITY: u64 = 50;
const FLOOR_SHARES: u64 = 20;
const NET_PAYOUT: u64 = 30;
const DOUBLE_NET_PAYOUT: u64 = 60;
const ZERO_AMOUNT: u64 = 0;

fun settle_at_tick(tick: u64): u64 {
    tick * TICK_SIZE
}

fun settle_above_tick(tick: u64): u64 {
    tick * TICK_SIZE + RAW_UNIT
}

#[test]
fun finite_range_is_open_lower_and_closed_higher() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    tree.insert_range(LOWER_TICK, HIGHER_TICK, QUANTITY, FLOOR_SHARES);

    assert_eq!(tree.settled_payout_liability(settle_at_tick(LOWER_TICK), TICK_SIZE), ZERO_AMOUNT);
    assert_eq!(tree.settled_payout_liability(settle_above_tick(LOWER_TICK), TICK_SIZE), NET_PAYOUT);
    assert_eq!(tree.settled_payout_liability(settle_at_tick(HIGHER_TICK), TICK_SIZE), NET_PAYOUT);
    assert_eq!(
        tree.settled_payout_liability(settle_above_tick(HIGHER_TICK), TICK_SIZE),
        ZERO_AMOUNT,
    );
    destroy(tree);
}

#[test]
fun open_lower_range_pays_through_its_closed_boundary() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    tree.insert_range(NEG_INF_TICK, HIGHER_TICK, QUANTITY, FLOOR_SHARES);

    assert_eq!(tree.settled_payout_liability(RAW_UNIT, TICK_SIZE), NET_PAYOUT);
    assert_eq!(tree.settled_payout_liability(settle_at_tick(HIGHER_TICK), TICK_SIZE), NET_PAYOUT);
    assert_eq!(
        tree.settled_payout_liability(settle_above_tick(HIGHER_TICK), TICK_SIZE),
        ZERO_AMOUNT,
    );
    destroy(tree);
}

#[test]
fun open_upper_range_pays_only_above_its_lower_boundary() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    tree.insert_range(
        LOWER_TICK,
        constants::pos_inf_tick!(),
        QUANTITY,
        FLOOR_SHARES,
    );

    assert_eq!(tree.settled_payout_liability(settle_at_tick(LOWER_TICK), TICK_SIZE), ZERO_AMOUNT);
    assert_eq!(tree.settled_payout_liability(settle_above_tick(LOWER_TICK), TICK_SIZE), NET_PAYOUT);
    assert_eq!(tree.settled_payout_liability(std::u64::max_value!(), TICK_SIZE), NET_PAYOUT);
    destroy(tree);
}

#[test]
fun existing_boundary_at_node_cap_accumulates_without_new_capacity() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    tree.insert_range(LOWER_TICK, constants::pos_inf_tick!(), QUANTITY, FLOOR_SHARES);
    tree.set_node_count_for_testing(constants::max_payout_tree_nodes!());

    tree.insert_range(LOWER_TICK, constants::pos_inf_tick!(), QUANTITY, FLOOR_SHARES);
    let (max_net_payout, total_net_payout) = tree.net_payout_reserve_terms();

    assert_eq!(max_net_payout, DOUBLE_NET_PAYOUT);
    assert_eq!(total_net_payout, DOUBLE_NET_PAYOUT);
    destroy(tree);
}

#[test]
fun removing_a_boundary_at_cap_frees_one_slot_for_a_new_boundary() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    tree.insert_range(LOWER_TICK, constants::pos_inf_tick!(), QUANTITY, FLOOR_SHARES);
    tree.set_node_count_for_testing(constants::max_payout_tree_nodes!());

    tree.remove_range(LOWER_TICK, constants::pos_inf_tick!(), QUANTITY, FLOOR_SHARES);
    tree.insert_range(NEW_TICK, constants::pos_inf_tick!(), QUANTITY, FLOOR_SHARES);
    let (max_net_payout, total_net_payout) = tree.net_payout_reserve_terms();

    assert_eq!(max_net_payout, NET_PAYOUT);
    assert_eq!(total_net_payout, NET_PAYOUT);
    destroy(tree);
}
