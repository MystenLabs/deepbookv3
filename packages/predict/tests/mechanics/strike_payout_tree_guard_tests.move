// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Insufficient-term and node-cap guards of the sparse payout index.
#[test_only]
module deepbook_predict::scope_mechanics__intent_guard__strike_payout_tree_tests;

use deepbook_predict::{constants, strike_payout_tree};

const LOWER_TICK: u64 = 2;
const HIGHER_TICK: u64 = 6;
const EXISTING_TICK: u64 = 1;
const QUANTITY: u64 = 50;
const EXCESS_QUANTITY: u64 = 51;
const ZERO_FLOOR: u64 = 0;
const RAW_UNIT: u64 = 1;

#[test, expected_failure(abort_code = strike_payout_tree::EInsufficientPayoutTerms)]
fun removal_from_empty_tree_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    tree.remove_range(LOWER_TICK, HIGHER_TICK, QUANTITY, ZERO_FLOOR);
    abort 999
}

#[test, expected_failure(abort_code = strike_payout_tree::EInsufficientPayoutTerms)]
fun removal_above_accumulated_terms_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    tree.insert_range(LOWER_TICK, HIGHER_TICK, QUANTITY, ZERO_FLOOR);
    tree.remove_range(LOWER_TICK, HIGHER_TICK, EXCESS_QUANTITY, ZERO_FLOOR);
    abort 999
}

#[test, expected_failure(abort_code = strike_payout_tree::EMaxPayoutTreeNodes)]
fun one_new_boundary_above_node_cap_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    tree.insert_range(EXISTING_TICK, constants::pos_inf_tick!(), QUANTITY, ZERO_FLOOR);
    tree.set_node_count_for_testing(constants::max_payout_tree_nodes!());
    tree.insert_range(LOWER_TICK, constants::pos_inf_tick!(), QUANTITY, ZERO_FLOOR);
    abort 999
}

#[test, expected_failure(abort_code = strike_payout_tree::EMaxPayoutTreeNodes)]
fun two_new_boundaries_with_one_slot_remaining_abort() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    tree.insert_range(EXISTING_TICK, constants::pos_inf_tick!(), QUANTITY, ZERO_FLOOR);
    tree.set_node_count_for_testing(constants::max_payout_tree_nodes!() - 1);
    tree.insert_range(LOWER_TICK, HIGHER_TICK, QUANTITY, ZERO_FLOOR);
    abort 999
}

#[test, expected_failure(abort_code = strike_payout_tree::EMaxPayoutTreeNodes)]
fun real_insertions_feed_the_node_cap_counter() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    tree.insert_range(EXISTING_TICK, constants::pos_inf_tick!(), RAW_UNIT, ZERO_FLOOR);
    tree.set_node_count_for_testing(constants::max_payout_tree_nodes!() - 5);

    let mut tick = 2;
    while (tick <= 6) {
        tree.insert_range(tick, constants::pos_inf_tick!(), RAW_UNIT, ZERO_FLOOR);
        tick = tick + RAW_UNIT;
    };
    tree.insert_range(7, constants::pos_inf_tick!(), RAW_UNIT, ZERO_FLOOR);
    abort 999
}
