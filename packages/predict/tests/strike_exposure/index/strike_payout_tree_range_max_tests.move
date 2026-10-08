// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Exact window/complement peak tests for inventory-impact liability deltas.
/// These reads must agree with the payout surface at half-open range boundaries:
/// an order on `(lower, higher]` starts immediately above `lower` and still wins
/// exactly at `higher`.
#[test_only]
module deepbook_predict::strike_payout_tree_range_max_tests;

use deepbook_predict::{constants, strike_payout_tree};
use std::unit_test::{assert_eq, destroy};
use sui::vec_map;

#[test]
fun empty_tree_has_zero_peaks() {
    let ctx = &mut tx_context::dummy();
    let tree = strike_payout_tree::new(ctx);

    assert_eq!(tree.range_max(0, constants::pos_inf_tick!()), 0);
    assert_eq!(tree.range_max(2, 6), 0);
    assert_eq!(tree.outside_max(2, 6), 0);
    destroy(tree);
}

#[test]
fun range_and_complement_reads_match_mixed_surface() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);

    // Surface by settlement interval:
    // (-inf,1] 10; (1,2] 50; (2,3] 40; (3,5] 70;
    // (5,7] 30; (7,8] 0; (8,9] 20; (9,+inf] 0.
    tree.insert_range(0, 2, 10);
    tree.insert_range(1, 5, 40);
    tree.insert_range(3, 7, 30);
    tree.insert_range(8, 9, 20);

    assert_eq!(tree.range_max(0, constants::pos_inf_tick!()), 70);
    assert_eq!(tree.range_max(0, 2), 50);
    assert_eq!(tree.range_max(1, 5), 70);
    assert_eq!(tree.range_max(5, 7), 30);
    assert_eq!(tree.range_max(7, 8), 0);
    assert_eq!(tree.range_max(8, 9), 20);
    assert_eq!(tree.range_max(7, constants::pos_inf_tick!()), 20);

    assert_eq!(tree.outside_max(0, constants::pos_inf_tick!()), 0);
    assert_eq!(tree.outside_max(0, 2), 70);
    assert_eq!(tree.outside_max(1, 5), 30);
    assert_eq!(tree.outside_max(7, constants::pos_inf_tick!()), 70);

    destroy(tree);
}

#[test]
fun shared_boundaries_and_removal_refresh_peaks() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    tree.insert_range(1, 4, 40);
    tree.insert_range(1, 4, 25); // stacks on the same boundaries
    tree.insert_range(4, 7, 30);

    assert_eq!(tree.range_max(1, 4), 65);
    assert_eq!(tree.outside_max(1, 4), 30);

    tree.remove_range(1, 4, 25, &vec_map::empty());
    assert_eq!(tree.range_max(1, 4), 40);
    assert_eq!(tree.outside_max(1, 4), 30);

    tree.remove_range(1, 4, 40, &vec_map::empty());
    assert_eq!(tree.range_max(1, 4), 0);
    assert_eq!(tree.outside_max(1, 4), 30);
    destroy(tree);
}
