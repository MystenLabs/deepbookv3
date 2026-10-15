// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Delayed-execution paths of the payout tree: `ensure_node` creates a waiting
/// order's zero leaves at enqueue, `insert_exist` fills over them at
/// resolve without ever creating a node, and pins keep those nodes alive through
/// every deletion path (`remove_range`, `snap_done`, `prune_node`).
///
/// Expected payouts are hand-derived from the `(lower, higher]` payoff: a
/// settlement at `t * TICK_SIZE` pays every range whose lower tick is below `t`
/// and whose higher tick is at least `t`. Frozen-walk references are separate
/// trees rebuilt with plain `insert_range` and walked live, as in
/// `payout_tree_snapshot_tests`, so no expected value comes from the path under
/// test.
#[test_only]
module deepbook_predict::payout_tree_pin_tests;

use deepbook_predict::{
    constants,
    oracle_fixture::{Self, OracleBundle, OracleFixture},
    pricing::Pricer,
    strike_payout_tree::{Self, StrikePayoutTree},
    test_constants
};
use std::unit_test::{assert_eq, destroy};
use sui::vec_map::{Self, VecMap};

/// Raw-strike scale for the pure tree tests; only settlement prices read it.
const TICK_SIZE: u64 = 10_000;
const LOWER: u64 = 10;
const MIDDLE: u64 = 15;
const HIGHER: u64 = 20;
const OTHER: u64 = 30;
const ABOVE_ALL: u64 = 40;
const Q: u64 = 7_000;
const Q2: u64 = 3_000;
/// Ascending distinct ticks for the balance check, and its height: the minimum
/// for 100 nodes is `ceil(log2(101)) = 7`, which ascending inserts into a
/// height-balanced tree always reach (`strike_payout_tree_balance_tests`).
const BALANCE_NODES: u64 = 100;
const BALANCE_HEIGHT: u64 = 7;

/// Inflated SVI base variance for the frozen-walk tests, as in
/// `payout_tree_snapshot_tests`, so strikes near the forward price smoothly.
const HIGH_VARIANCE_A: u64 = 100_000_000;
const Q_A: u64 = 5_000_000_000;
const Q_B: u64 = 2_000_000_000;
const Q_C: u64 = 3_000_000_000;
const RANGE_A_LOWER: u64 = 96;
const RANGE_A_HIGHER: u64 = 100;
const RANGE_B_HIGHER: u64 = 104;
const RANGE_C_LOWER: u64 = 98;
const RANGE_C_HIGHER: u64 = 106;

// === ensure_node ===

#[test]
fun ensure_node_inserts_one_zero_leaf_and_is_idempotent() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);

    assert!(tree.ensure_node(LOWER));
    assert_eq!(tree.node_count(), 1);
    // A zero leaf carries no payout anywhere.
    assert_reserve_terms(&tree, 0, 0);
    assert_eq!(tree.settled_liab(settle_at(MIDDLE), TICK_SIZE), 0);

    assert!(!tree.ensure_node(LOWER));
    assert_eq!(tree.node_count(), 1);
    assert_eq!(tree.assert_tree_invariant_for_testing(), 1);
    destroy(tree);
}

#[test]
fun ensure_node_skips_the_open_sentinels() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);

    assert!(!tree.ensure_node(0));
    assert!(!tree.ensure_node(constants::pos_inf_tick!()));
    assert_eq!(tree.node_count(), 0);
    assert_eq!(tree.assert_tree_invariant_for_testing(), 0);
    destroy(tree);
}

#[test]
fun ensure_node_on_a_live_boundary_changes_nothing() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    tree.insert_range(LOWER, HIGHER, Q);

    assert!(!tree.ensure_node(LOWER));
    assert!(!tree.ensure_node(HIGHER));
    assert_eq!(tree.node_count(), 2);
    assert_reserve_terms(&tree, Q, Q);
    assert_eq!(tree.settled_liab(settle_at(MIDDLE), TICK_SIZE), Q);
    tree.assert_tree_invariant_for_testing();
    destroy(tree);
}

#[test]
fun ensure_node_one_slot_below_the_cap_fills_it() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    tree.insert_range(LOWER, constants::pos_inf_tick!(), Q);
    tree.set_node_count_for_testing(constants::max_payout_tree_nodes!() - 1);

    assert!(tree.ensure_node(HIGHER));
    assert_eq!(tree.node_count(), constants::max_payout_tree_nodes!());
    destroy(tree);
}

#[test, expected_failure(abort_code = strike_payout_tree::EMaxPayoutTreeNodes)]
fun ensure_node_at_the_cap_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    tree.insert_range(LOWER, constants::pos_inf_tick!(), Q);
    tree.set_node_count_for_testing(constants::max_payout_tree_nodes!());

    tree.ensure_node(HIGHER);
    abort 999
}

#[test]
fun ensure_node_at_the_cap_on_an_existing_node_succeeds() {
    // An existing node needs no new slot, so a full tree still accepts it.
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    tree.insert_range(LOWER, constants::pos_inf_tick!(), Q);
    tree.set_node_count_for_testing(constants::max_payout_tree_nodes!());

    assert!(!tree.ensure_node(LOWER));
    assert_eq!(tree.node_count(), constants::max_payout_tree_nodes!());
    destroy(tree);
}

#[test]
fun ensure_node_keeps_the_tree_balanced() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    let mut tick = 1;
    while (tick <= BALANCE_NODES) {
        assert!(tree.ensure_node(tick));
        tree.assert_tree_invariant_for_testing();
        tick = tick + 1;
    };

    assert_eq!(tree.node_count(), BALANCE_NODES);
    assert_eq!(tree.assert_tree_invariant_for_testing(), BALANCE_HEIGHT);
    destroy(tree);
}

// === has_nodes ===

#[test]
fun has_nodes_requires_both_finite_boundaries() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    let pos_inf = constants::pos_inf_tick!();

    // The sentinels never need a node.
    assert!(tree.has_nodes(0, pos_inf));
    assert!(!tree.has_nodes(LOWER, pos_inf));
    assert!(!tree.has_nodes(0, HIGHER));
    assert!(!tree.has_nodes(LOWER, HIGHER));

    tree.ensure_node(LOWER);
    assert!(tree.has_nodes(LOWER, pos_inf));
    assert!(!tree.has_nodes(LOWER, HIGHER));
    assert!(!tree.has_nodes(0, HIGHER));

    tree.ensure_node(HIGHER);
    assert!(tree.has_nodes(LOWER, HIGHER));
    assert!(tree.has_nodes(0, HIGHER));
    destroy(tree);
}

// === insert_range_existing ===

#[test]
fun insert_range_existing_fills_zero_leaves_without_adding_nodes() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    tree.ensure_node(LOWER);
    tree.ensure_node(HIGHER);

    tree.insert_exist(LOWER, HIGHER, Q);

    assert_eq!(tree.node_count(), 2);
    assert_reserve_terms(&tree, Q, Q);
    // (10, 20] pays Q at 15 and at exactly 20; nothing at 10 or above 20.
    assert_eq!(tree.settled_liab(settle_at(LOWER), TICK_SIZE), 0);
    assert_eq!(tree.settled_liab(settle_at(MIDDLE), TICK_SIZE), Q);
    assert_eq!(tree.settled_liab(settle_at(HIGHER), TICK_SIZE), Q);
    assert_eq!(tree.settled_liab(settle_at(ABOVE_ALL), TICK_SIZE), 0);
    tree.assert_tree_invariant_for_testing();
    destroy(tree);
}

#[test]
fun insert_range_existing_with_an_open_lower_credits_the_base() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    tree.ensure_node(HIGHER);

    tree.insert_exist(0, HIGHER, Q);

    assert_eq!(tree.node_count(), 1);
    assert_reserve_terms(&tree, Q, Q);
    assert_eq!(tree.settled_liab(settle_at(LOWER), TICK_SIZE), Q);
    assert_eq!(tree.settled_liab(settle_at(ABOVE_ALL), TICK_SIZE), 0);
    tree.assert_tree_invariant_for_testing();
    destroy(tree);
}

#[test]
fun insert_range_existing_with_an_open_higher_touches_one_node() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    tree.ensure_node(LOWER);

    tree.insert_exist(LOWER, constants::pos_inf_tick!(), Q);

    assert_eq!(tree.node_count(), 1);
    assert_reserve_terms(&tree, Q, Q);
    assert_eq!(tree.settled_liab(settle_at(LOWER), TICK_SIZE), 0);
    assert_eq!(tree.settled_liab(settle_at(ABOVE_ALL), TICK_SIZE), Q);
    tree.assert_tree_invariant_for_testing();
    destroy(tree);
}

#[test]
fun insert_range_existing_stacks_onto_a_live_boundary() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    tree.insert_range(LOWER, HIGHER, Q);
    tree.ensure_node(OTHER);

    // HIGHER is already the live end of (10, 20]; it also becomes the start of (20, 30].
    tree.insert_exist(HIGHER, OTHER, Q2);

    assert_eq!(tree.node_count(), 3);
    // Disjoint ranges: the point max is the larger order, the total is both.
    assert_reserve_terms(&tree, Q, Q + Q2);
    assert_eq!(tree.settled_liab(settle_at(MIDDLE), TICK_SIZE), Q);
    assert_eq!(tree.settled_liab(settle_at(OTHER), TICK_SIZE), Q2);
    tree.assert_tree_invariant_for_testing();
    destroy(tree);
}

#[test]
fun insert_range_existing_with_zero_quantity_changes_nothing() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    tree.ensure_node(LOWER);
    tree.ensure_node(HIGHER);

    tree.insert_exist(LOWER, HIGHER, 0);

    assert_eq!(tree.node_count(), 2);
    assert_reserve_terms(&tree, 0, 0);
    destroy(tree);
}

#[test, expected_failure(abort_code = strike_payout_tree::ENodeMissing)]
fun insert_range_existing_with_a_missing_higher_boundary_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    tree.ensure_node(LOWER);

    tree.insert_exist(LOWER, HIGHER, Q);
    abort 999
}

#[test, expected_failure(abort_code = strike_payout_tree::ENodeMissing)]
fun insert_range_existing_on_an_empty_tree_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);

    tree.insert_exist(LOWER, constants::pos_inf_tick!(), Q);
    abort 999
}

#[test, expected_failure(abort_code = strike_payout_tree::ENodeMissing)]
fun insert_range_existing_over_the_whole_line_aborts() {
    // Both ends are sentinels, so the precondition passes, but no order spans the
    // whole line and the descent finds no node at `pos_inf_tick`.
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    tree.ensure_node(LOWER);

    tree.insert_exist(0, constants::pos_inf_tick!(), Q);
    abort 999
}

// === pins on remove_range ===

#[test]
fun a_pinned_boundary_survives_the_close_that_empties_it() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    tree.insert_range(LOWER, HIGHER, Q);

    tree.remove_range(LOWER, HIGHER, Q, &pins(vector[LOWER]));

    // LOWER stays as a zero leaf for the waiting order; unpinned HIGHER is pruned.
    assert_eq!(tree.node_count(), 1);
    assert!(tree.has_nodes(LOWER, constants::pos_inf_tick!()));
    assert!(!tree.has_nodes(HIGHER, constants::pos_inf_tick!()));
    assert_reserve_terms(&tree, 0, 0);
    tree.assert_tree_invariant_for_testing();

    // The waiting order then fills over the kept node.
    tree.insert_exist(LOWER, constants::pos_inf_tick!(), Q2);
    assert_eq!(tree.node_count(), 1);
    assert_eq!(tree.settled_liab(settle_at(ABOVE_ALL), TICK_SIZE), Q2);
    destroy(tree);
}

#[test]
fun pinning_both_boundaries_keeps_both_after_a_full_close() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    tree.insert_range(LOWER, HIGHER, Q);

    tree.remove_range(LOWER, HIGHER, Q, &pins(vector[LOWER, HIGHER]));

    assert_eq!(tree.node_count(), 2);
    assert!(tree.has_nodes(LOWER, HIGHER));
    assert_reserve_terms(&tree, 0, 0);
    tree.assert_tree_invariant_for_testing();
    destroy(tree);
}

// === pins on release_snapshot ===

#[test]
fun a_pinned_zero_leaf_survives_release_snapshot() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    tree.ensure_node(LOWER);
    tree.ensure_node(HIGHER);

    tree.snap_on(1);
    tree.snap_done(&pins(vector[LOWER]));

    // Release collects every live-zero node except the pinned one.
    assert_eq!(tree.node_count(), 1);
    assert!(tree.has_nodes(LOWER, constants::pos_inf_tick!()));
    tree.assert_tree_invariant_for_testing();

    // Once the order finishes and unpins, the next release collects it.
    tree.snap_on(2);
    tree.snap_done(&vec_map::empty());
    assert_eq!(tree.node_count(), 0);
    destroy(tree);
}

#[test]
fun a_pinned_husk_survives_release_while_unpinned_husks_go() {
    let (mut fixture, oracle, pricer) = live_pricer();
    let ctx = fixture.scenario_mut().ctx();
    let mut tree = strike_payout_tree::new(ctx);
    let mut snapshot_reference = strike_payout_tree::new(ctx);
    tree.insert_range(RANGE_A_LOWER, RANGE_A_HIGHER, Q_A);
    snapshot_reference.insert_range(RANGE_A_LOWER, RANGE_A_HIGHER, Q_A);

    tree.snap_on(1);
    let pinned = pins(vector[RANGE_A_LOWER]);
    tree.remove_range(RANGE_A_LOWER, RANGE_A_HIGHER, Q_A, &pinned);
    // Both kept: the lower one is pinned, the higher one is a husk the snapshot holds.
    assert_eq!(tree.node_count(), 2);
    assert_eq!(
        tree.walk_frozen(&pricer, tick_size(), 1),
        snapshot_reference.walk_linear(&pricer, tick_size()),
    );

    tree.snap_done(&pinned);
    assert_eq!(tree.node_count(), 1);
    assert!(tree.has_nodes(RANGE_A_LOWER, constants::pos_inf_tick!()));
    assert_eq!(tree.walk_linear(&pricer, tick_size()), 0);
    tree.assert_tree_invariant_for_testing();

    destroy(tree);
    destroy(snapshot_reference);
    cleanup(fixture, oracle);
}

// === prune_if_unpinned ===

#[test]
fun prune_skips_missing_ticks_and_sentinels() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    tree.ensure_node(LOWER);
    let none = vec_map::empty();

    assert!(!tree.prune_node(HIGHER, &none));
    assert!(!tree.prune_node(0, &none));
    assert!(!tree.prune_node(constants::pos_inf_tick!(), &none));
    assert_eq!(tree.node_count(), 1);
    destroy(tree);
}

#[test]
fun prune_removes_an_empty_unpinned_node() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    tree.ensure_node(LOWER);

    assert!(tree.prune_node(LOWER, &pins(vector[HIGHER])));

    assert_eq!(tree.node_count(), 0);
    assert!(!tree.has_nodes(LOWER, constants::pos_inf_tick!()));
    assert_eq!(tree.assert_tree_invariant_for_testing(), 0);
    destroy(tree);
}

#[test]
fun prune_keeps_a_pinned_empty_node() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    tree.ensure_node(LOWER);

    assert!(!tree.prune_node(LOWER, &pins(vector[LOWER])));

    assert_eq!(tree.node_count(), 1);
    assert!(tree.has_nodes(LOWER, constants::pos_inf_tick!()));
    destroy(tree);
}

#[test]
fun prune_keeps_a_node_that_holds_quantity() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    tree.insert_range(LOWER, HIGHER, Q);
    let none = vec_map::empty();

    assert!(!tree.prune_node(LOWER, &none));
    assert!(!tree.prune_node(HIGHER, &none));

    assert_eq!(tree.node_count(), 2);
    assert_reserve_terms(&tree, Q, Q);
    destroy(tree);
}

#[test]
fun prune_removes_a_zero_leaf_created_under_the_active_snapshot() {
    // Created after the instant with zero shadows, so the snapshot does not need it.
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    tree.snap_on(1);
    tree.ensure_node(LOWER);

    assert!(tree.prune_node(LOWER, &vec_map::empty()));
    assert_eq!(tree.node_count(), 0);
    destroy(tree);
}

#[test]
fun prune_removes_an_empty_node_untouched_by_the_active_generation() {
    // Its live terms are its snapshot terms, both zero, so neither walk prices it.
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    tree.ensure_node(LOWER);
    tree.snap_on(1);

    assert!(tree.prune_node(LOWER, &vec_map::empty()));
    assert_eq!(tree.node_count(), 0);
    destroy(tree);
}

#[test]
fun prune_removes_a_stale_generations_husk() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    tree.insert_range(LOWER, HIGHER, Q);
    tree.snap_on(1);
    tree.remove_range(LOWER, HIGHER, Q, &vec_map::empty());
    assert_eq!(tree.node_count(), 2);
    // The flush aborted: generation 1 is discarded and its husks need nothing.
    tree.snap_off();

    assert!(tree.prune_node(LOWER, &vec_map::empty()));
    assert!(tree.prune_node(HIGHER, &vec_map::empty()));
    assert_eq!(tree.node_count(), 0);
    assert_eq!(tree.assert_tree_invariant_for_testing(), 0);
    destroy(tree);
}

#[test]
fun prune_of_a_root_with_two_children_rejoins_the_survivors() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(ctx);
    // Ascending inserts balance to the middle tick as root.
    tree.ensure_node(LOWER);
    tree.ensure_node(HIGHER);
    tree.ensure_node(OTHER);

    assert!(tree.prune_node(HIGHER, &vec_map::empty()));

    assert_eq!(tree.node_count(), 2);
    assert!(tree.has_nodes(LOWER, OTHER));
    assert!(!tree.has_nodes(HIGHER, constants::pos_inf_tick!()));
    assert_eq!(tree.assert_tree_invariant_for_testing(), 2);
    destroy(tree);
}

#[test]
fun a_husk_the_snapshot_retains_is_never_pruned() {
    let (mut fixture, oracle, pricer) = live_pricer();
    let ctx = fixture.scenario_mut().ctx();
    let mut tree = strike_payout_tree::new(ctx);
    let mut snapshot_reference = strike_payout_tree::new(ctx);
    tree.insert_range(RANGE_A_LOWER, RANGE_A_HIGHER, Q_A);
    snapshot_reference.insert_range(RANGE_A_LOWER, RANGE_A_HIGHER, Q_A);

    tree.snap_on(1);
    tree.remove_range(RANGE_A_LOWER, RANGE_A_HIGHER, Q_A, &vec_map::empty());

    // Unpinned and empty, but the frozen walk still owns their shadows.
    assert!(!tree.prune_node(RANGE_A_LOWER, &vec_map::empty()));
    assert!(!tree.prune_node(RANGE_A_HIGHER, &vec_map::empty()));
    assert_eq!(tree.node_count(), 2);
    assert_eq!(
        tree.walk_frozen(&pricer, tick_size(), 1),
        snapshot_reference.walk_linear(&pricer, tick_size()),
    );

    // Consuming the snapshot is what removes them.
    tree.snap_done(&vec_map::empty());
    assert_eq!(tree.node_count(), 0);

    destroy(tree);
    destroy(snapshot_reference);
    cleanup(fixture, oracle);
}

// === insert_range_existing under a snapshot ===

#[test]
fun insert_range_existing_under_a_snapshot_captures_before_mutating() {
    let (mut fixture, oracle, pricer) = live_pricer();
    let ctx = fixture.scenario_mut().ctx();
    let mut tree = strike_payout_tree::new(ctx);
    let mut snapshot_reference = strike_payout_tree::new(ctx);
    let mut live_reference = strike_payout_tree::new(ctx);

    // A live range plus two zero leaves a waiting order pinned before the instant.
    tree.insert_range(RANGE_A_LOWER, RANGE_A_HIGHER, Q_A);
    tree.ensure_node(RANGE_C_LOWER);
    tree.ensure_node(RANGE_C_HIGHER);
    snapshot_reference.insert_range(RANGE_A_LOWER, RANGE_A_HIGHER, Q_A);

    tree.snap_on(1);
    // Fills after the instant: one stacks on captured live nodes, one fills the
    // zero leaves.
    tree.insert_exist(RANGE_A_LOWER, RANGE_A_HIGHER, Q_B);
    tree.insert_exist(RANGE_C_LOWER, RANGE_C_HIGHER, Q_C);
    live_reference.insert_range(RANGE_A_LOWER, RANGE_A_HIGHER, Q_A + Q_B);
    live_reference.insert_range(RANGE_C_LOWER, RANGE_C_HIGHER, Q_C);

    assert_eq!(tree.node_count(), 4);
    assert_eq!(
        tree.walk_frozen(&pricer, tick_size(), 1),
        snapshot_reference.walk_linear(&pricer, tick_size()),
    );
    assert_eq!(
        tree.walk_linear(&pricer, tick_size()),
        live_reference.walk_linear(&pricer, tick_size()),
    );
    tree.assert_tree_invariant_for_testing();

    destroy(tree);
    destroy(snapshot_reference);
    destroy(live_reference);
    cleanup(fixture, oracle);
}

#[test]
fun a_zero_leaf_created_under_the_snapshot_stays_out_of_the_frozen_walk() {
    let (mut fixture, oracle, pricer) = live_pricer();
    let ctx = fixture.scenario_mut().ctx();
    let mut tree = strike_payout_tree::new(ctx);
    let mut snapshot_reference = strike_payout_tree::new(ctx);
    let mut live_reference = strike_payout_tree::new(ctx);
    tree.insert_range(RANGE_A_LOWER, RANGE_A_HIGHER, Q_A);
    snapshot_reference.insert_range(RANGE_A_LOWER, RANGE_A_HIGHER, Q_A);

    tree.snap_on(1);
    // Enqueue pins a new tick during the flush; resolve fills over it.
    assert!(tree.ensure_node(RANGE_B_HIGHER));
    tree.insert_exist(RANGE_A_HIGHER, RANGE_B_HIGHER, Q_B);
    live_reference.insert_range(RANGE_A_LOWER, RANGE_A_HIGHER, Q_A);
    live_reference.insert_range(RANGE_A_HIGHER, RANGE_B_HIGHER, Q_B);

    assert_eq!(
        tree.walk_frozen(&pricer, tick_size(), 1),
        snapshot_reference.walk_linear(&pricer, tick_size()),
    );
    assert_eq!(
        tree.walk_linear(&pricer, tick_size()),
        live_reference.walk_linear(&pricer, tick_size()),
    );

    destroy(tree);
    destroy(snapshot_reference);
    destroy(live_reference);
    cleanup(fixture, oracle);
}

// === Helpers ===

fun settle_at(tick: u64): u64 {
    tick * TICK_SIZE
}

/// One waiting order per tick.
fun pins(ticks: vector<u64>): VecMap<u64, u64> {
    let mut pin_counts = vec_map::empty();
    ticks.do!(|tick| pin_counts.insert(tick, 1));
    pin_counts
}

fun assert_reserve_terms(tree: &StrikePayoutTree, expected_max: u64, expected_total: u64) {
    let (max_payout, total_payout) = tree.rsv_terms();
    assert_eq!(max_payout, expected_max);
    assert_eq!(total_payout, expected_total);
}

fun tick_size(): u64 { test_constants::default_tick_size() }

/// A live market at the default ATM forward with an inflated base variance, as
/// in the snapshot tests.
fun live_pricer(): (OracleFixture, OracleBundle, Pricer) {
    let mut fixture = oracle_fixture::setup_oracle_default();
    let mut oracle = fixture.take_oracle_bundle();
    fixture.prepare_real_oracle_bundle(
        &mut oracle,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        HIGH_VARIANCE_A,
        false,
        test_constants::default_svi_b(),
        test_constants::default_svi_sigma(),
        test_constants::default_svi_rho_magnitude(),
        false,
        test_constants::default_svi_m(),
        false,
    );
    let pricer = fixture.load_pricer_bundle(&oracle);
    (fixture, oracle, pricer)
}

fun cleanup(fixture: OracleFixture, oracle: OracleBundle) {
    oracle_fixture::return_oracle_bundle(oracle);
    fixture.finish();
}
