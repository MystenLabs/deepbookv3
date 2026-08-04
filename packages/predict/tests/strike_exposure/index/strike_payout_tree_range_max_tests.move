// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit tests for `strike_payout_tree::range_max_net_payout` — the peak of the
/// existing payout profile inside one order's tick range, which the inventory-skew
/// charge prices its marginal reserve consumption against.
///
/// Every expectation is derived from the step profile by hand rather than from the
/// tree: `P(limit)` is `base` plus the net delta of every boundary strictly below
/// `limit`, and the answer for `(lower, higher]` is the largest `P(limit)` over
/// `limit` in `[lower + 1, higher]`.
#[test_only]
module deepbook_predict::strike_payout_tree_range_max_tests;

use deepbook_predict::{constants, strike_payout_tree::{Self, StrikePayoutTree}};
use std::unit_test::{assert_eq, destroy};

/// Three overlapping ranges, chosen so the profile rises, falls, and peaks strictly
/// inside one of them:
///
/// - `OPEN` over `(-inf, 3]` at 50 — anchors `base`, so the profile starts nonzero
/// - `LOW` over `(2, 6]` at 100
/// - `HIGH` over `(4, 8]` at 300
///
/// Boundary deltas: `+100 @2`, `-50 @3`, `+300 @4`, `-100 @6`, `-300 @8`, giving
/// the profile `P(1..9) = 50, 50, 150, 100, 400, 400, 300, 300, 0`. Total net
/// payout is 450 and the max point is 400, reached on `(4, 6]`.
const OPEN_HIGHER_TICK: u64 = 3;
const OPEN_QUANTITY: u64 = 50;
const LOW_LOWER_TICK: u64 = 2;
const LOW_HIGHER_TICK: u64 = 6;
const LOW_QUANTITY: u64 = 100;
const HIGH_LOWER_TICK: u64 = 4;
const HIGH_HIGHER_TICK: u64 = 8;
const HIGH_QUANTITY: u64 = 300;

const BOOK_MAX_NET_PAYOUT: u64 = 400;
const BOOK_TOTAL_NET_PAYOUT: u64 = 450;

/// Floors are exercised by the reserve-terms tests; every range here is unfloored
/// so `net_payout == quantity` and the profile arithmetic stays hand-checkable.
const NO_FLOOR: u64 = 0;

fun new_book(ctx: &mut TxContext): StrikePayoutTree {
    let mut tree = strike_payout_tree::new(ctx);
    tree.insert_range(0, OPEN_HIGHER_TICK, OPEN_QUANTITY, NO_FLOOR);
    tree.insert_range(LOW_LOWER_TICK, LOW_HIGHER_TICK, LOW_QUANTITY, NO_FLOOR);
    tree.insert_range(HIGH_LOWER_TICK, HIGH_HIGHER_TICK, HIGH_QUANTITY, NO_FLOOR);
    tree
}

#[test]
fun empty_tree_has_no_range_peak() {
    let ctx = &mut tx_context::dummy();
    let tree = strike_payout_tree::new(ctx);
    assert_eq!(tree.range_max_net_payout(0, constants::pos_inf_tick!()), 0);
    assert_eq!(tree.range_max_net_payout(LOW_LOWER_TICK, LOW_HIGHER_TICK), 0);
    destroy(tree);
}

#[test]
fun whole_line_range_peak_equals_book_max_point() {
    let ctx = &mut tx_context::dummy();
    let tree = new_book(ctx);
    let (max_net_payout, total_net_payout) = tree.net_payout_reserve_terms();
    assert_eq!(max_net_payout, BOOK_MAX_NET_PAYOUT);
    assert_eq!(total_net_payout, BOOK_TOTAL_NET_PAYOUT);
    // The whole line contains every step, so its peak is the book's max point.
    assert_eq!(tree.range_max_net_payout(0, constants::pos_inf_tick!()), BOOK_MAX_NET_PAYOUT);
    destroy(tree);
}

#[test]
fun open_lower_range_peak_starts_at_base() {
    let ctx = &mut tx_context::dummy();
    let tree = new_book(ctx);
    // `(-inf, 3]` spans limits 1..3: max(50, 50, 150) = 150. The `-inf` end has no
    // stored key, so the walk must fall back to `base` rather than skipping it.
    assert_eq!(tree.range_max_net_payout(0, OPEN_HIGHER_TICK), 150);
    // `(-inf, 2]` stops one step earlier, before `+100 @2` enters any prefix.
    assert_eq!(tree.range_max_net_payout(0, LOW_LOWER_TICK), OPEN_QUANTITY);
    destroy(tree);
}

#[test]
fun range_peak_reads_the_step_strictly_inside_it() {
    let ctx = &mut tx_context::dummy();
    let tree = new_book(ctx);
    // `(2, 6]` spans limits 3..6: max(150, 100, 400, 400) = 400. The peak comes
    // from `+300 @4`, a boundary strictly inside the range — an implementation
    // that only read the prefix at the range edges would return 150.
    assert_eq!(tree.range_max_net_payout(LOW_LOWER_TICK, LOW_HIGHER_TICK), BOOK_MAX_NET_PAYOUT);
    destroy(tree);
}

#[test]
fun range_peak_excludes_the_boundary_that_closes_it() {
    let ctx = &mut tx_context::dummy();
    let tree = new_book(ctx);
    // `(4, 8]` spans limits 5..8: max(400, 400, 300, 300) = 400. The step down at
    // 8 closes the range and must not enter any prefix; a walk that folded it in
    // would report 100.
    assert_eq!(tree.range_max_net_payout(HIGH_LOWER_TICK, HIGH_HIGHER_TICK), BOOK_MAX_NET_PAYOUT);
    // `(6, 8]` starts after the `-100 @6` step: max(300, 300) = 300.
    assert_eq!(tree.range_max_net_payout(LOW_HIGHER_TICK, HIGH_HIGHER_TICK), 300);
    destroy(tree);
}

#[test]
fun single_step_range_peak_is_its_own_prefix() {
    let ctx = &mut tx_context::dummy();
    let tree = new_book(ctx);
    // `(3, 4]` spans the single limit 4, after `-50 @3` and before `+300 @4`.
    assert_eq!(tree.range_max_net_payout(OPEN_HIGHER_TICK, HIGH_LOWER_TICK), 100);
    destroy(tree);
}

#[test]
fun range_above_the_whole_book_has_no_peak() {
    let ctx = &mut tx_context::dummy();
    let tree = new_book(ctx);
    // Past the last boundary every range has expired: `P(9) = 0`.
    assert_eq!(tree.range_max_net_payout(HIGH_HIGHER_TICK, constants::pos_inf_tick!()), 0);
    destroy(tree);
}

#[test]
fun removed_range_leaves_the_remaining_profile_peak() {
    let ctx = &mut tx_context::dummy();
    let mut tree = new_book(ctx);
    tree.remove_range(HIGH_LOWER_TICK, HIGH_HIGHER_TICK, HIGH_QUANTITY, NO_FLOOR);
    // Without `HIGH` the deltas are `+100 @2`, `-50 @3`, `-100 @6`, so the profile
    // is `P(1..7) = 50, 50, 150, 100, 100, 100, 0` and the peak of `(2, 6]` drops
    // from 400 to 150.
    assert_eq!(tree.range_max_net_payout(LOW_LOWER_TICK, LOW_HIGHER_TICK), 150);
    assert_eq!(tree.range_max_net_payout(HIGH_LOWER_TICK, HIGH_HIGHER_TICK), 100);
    destroy(tree);
}
