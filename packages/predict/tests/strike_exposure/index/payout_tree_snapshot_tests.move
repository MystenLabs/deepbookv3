// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit coverage for the payout tree's valuation snapshot: lazy per-node capture,
/// husk retention and release, generation supersession, and the view each walk
/// prices. Frozen-walk references are rebuilt trees holding the snapshot-instant
/// state, walked live — the frozen walk must equal them bit-for-bit because it is
/// the same walk over the same terms (unit-tests rule 1: the reference never
/// touches the snapshot machinery under test).
#[test_only]
module deepbook_predict::payout_tree_snapshot_tests;

use deepbook_predict::{
    constants,
    oracle_fixture::{Self, OracleBundle, OracleFixture},
    pricing::Pricer,
    strike_payout_tree::{Self, StrikePayoutTree},
    test_constants
};
use std::unit_test::{assert_eq, destroy};

/// Inflated SVI base variance (0.1 in 1e9 fixed point), as in the walk tests, so
/// adjacent-tick strikes price close together and smoothly.
const HIGH_VARIANCE_A: u64 = 100_000_000;
const Q_A: u64 = 5_000_000_000;
const Q_B: u64 = 2_000_000_000;
const Q_C: u64 = 3_000_000_000;
const RANGE_A_LOWER: u64 = 96;
const RANGE_A_HIGHER: u64 = 100;
const RANGE_B_LOWER: u64 = 100;
const RANGE_B_HIGHER: u64 = 104;
const RANGE_C_LOWER: u64 = 98;
const RANGE_C_HIGHER: u64 = 106;
/// One finite range whose two boundaries an inverted surface prices in rising
/// order, so any walk that observes both must abort.
const INVERTED_LOWER_TICK: u64 = 90;
const INVERTED_HIGHER_TICK: u64 = 100;
const INVERTED_QUANTITY: u64 = 3_000_000;

#[test]
fun frozen_walk_returns_the_snapshot_instant_through_mutations() {
    let (mut fixture, oracle, pricer) = live_pricer();
    let ctx = fixture.scenario_mut().ctx();
    let mut tree = strike_payout_tree::new(ctx);
    let mut snapshot_reference = strike_payout_tree::new(ctx);
    let mut live_reference = strike_payout_tree::new(ctx);

    tree.insert_range(RANGE_A_LOWER, RANGE_A_HIGHER, Q_A);
    tree.insert_range(RANGE_B_LOWER, RANGE_B_HIGHER, Q_B);
    snapshot_reference.insert_range(RANGE_A_LOWER, RANGE_A_HIGHER, Q_A);
    snapshot_reference.insert_range(RANGE_B_LOWER, RANGE_B_HIGHER, Q_B);

    tree.activate_snapshot(1);
    // Every mutation class after the instant: a new range at fresh ticks, a
    // partial remove at captured ticks, and a stack onto a captured tick.
    tree.insert_range(RANGE_C_LOWER, RANGE_C_HIGHER, Q_C);
    tree.remove_range(RANGE_A_LOWER, RANGE_A_HIGHER, Q_A / 2);
    tree.insert_range(RANGE_B_LOWER, RANGE_B_HIGHER, Q_B);
    live_reference.insert_range(RANGE_C_LOWER, RANGE_C_HIGHER, Q_C);
    live_reference.insert_range(RANGE_A_LOWER, RANGE_A_HIGHER, Q_A - Q_A / 2);
    live_reference.insert_range(RANGE_B_LOWER, RANGE_B_HIGHER, 2 * Q_B);

    let frozen = tree.walk_linear_frozen(&pricer, tick_size(), 1);
    assert_eq!(frozen, snapshot_reference.walk_linear(&pricer, tick_size()));
    assert_eq!(
        tree.walk_linear(&pricer, tick_size()),
        live_reference.walk_linear(&pricer, tick_size()),
    );
    // The frozen read is repeatable until released.
    assert_eq!(tree.walk_linear_frozen(&pricer, tick_size(), 1), frozen);

    destroy(tree);
    destroy(snapshot_reference);
    destroy(live_reference);
    cleanup(fixture, oracle);
}

#[test]
fun an_emptied_boundary_is_retained_for_the_frozen_walk_then_released() {
    let (mut fixture, oracle, pricer) = live_pricer();
    let ctx = fixture.scenario_mut().ctx();
    let mut tree = strike_payout_tree::new(ctx);
    let mut snapshot_reference = strike_payout_tree::new(ctx);

    tree.insert_range(RANGE_A_LOWER, RANGE_A_HIGHER, Q_A);
    snapshot_reference.insert_range(RANGE_A_LOWER, RANGE_A_HIGHER, Q_A);
    assert_eq!(tree.node_count_for_testing(), 2);

    tree.activate_snapshot(1);
    tree.remove_range(RANGE_A_LOWER, RANGE_A_HIGHER, Q_A);
    // Both boundaries emptied but retained as husks: the frozen walk still owns
    // their shadows, and the live walk prices an empty book.
    assert_eq!(tree.node_count_for_testing(), 2);
    assert_eq!(
        tree.walk_linear_frozen(&pricer, tick_size(), 1),
        snapshot_reference.walk_linear(&pricer, tick_size()),
    );
    assert_eq!(tree.walk_linear(&pricer, tick_size()), 0);

    // Consumption removes exactly the husks and restores the plain-removal shape.
    tree.release_snapshot();
    assert_eq!(tree.node_count_for_testing(), 0);
    tree.assert_tree_invariant_for_testing();
    assert_eq!(tree.walk_linear(&pricer, tick_size()), 0);

    destroy(tree);
    destroy(snapshot_reference);
    cleanup(fixture, oracle);
}

#[test]
fun a_boundary_created_after_the_snapshot_is_excluded_from_the_frozen_walk() {
    let (mut fixture, oracle, pricer) = live_pricer();
    let ctx = fixture.scenario_mut().ctx();
    let mut tree = strike_payout_tree::new(ctx);
    let mut live_reference = strike_payout_tree::new(ctx);

    tree.activate_snapshot(1);
    tree.insert_range(RANGE_A_LOWER, RANGE_A_HIGHER, Q_A);
    live_reference.insert_range(RANGE_A_LOWER, RANGE_A_HIGHER, Q_A);

    // The book was empty at the instant; the post-snapshot mint is live-only.
    assert_eq!(tree.walk_linear_frozen(&pricer, tick_size(), 1), 0);
    assert_eq!(
        tree.walk_linear(&pricer, tick_size()),
        live_reference.walk_linear(&pricer, tick_size()),
    );

    destroy(tree);
    destroy(live_reference);
    cleanup(fixture, oracle);
}

#[test]
fun a_revived_husk_keeps_its_shadow_through_the_generation() {
    let (mut fixture, oracle, pricer) = live_pricer();
    let ctx = fixture.scenario_mut().ctx();
    let mut tree = strike_payout_tree::new(ctx);
    let mut snapshot_reference = strike_payout_tree::new(ctx);

    tree.insert_range(RANGE_A_LOWER, RANGE_A_HIGHER, Q_A);
    snapshot_reference.insert_range(RANGE_A_LOWER, RANGE_A_HIGHER, Q_A);
    tree.activate_snapshot(1);

    // Empty to husks, revive at the same ticks, empty again: the shadow must
    // survive every round-trip until the generation is consumed.
    tree.remove_range(RANGE_A_LOWER, RANGE_A_HIGHER, Q_A);
    tree.insert_range(RANGE_A_LOWER, RANGE_A_HIGHER, Q_B);
    tree.remove_range(RANGE_A_LOWER, RANGE_A_HIGHER, Q_B);
    assert_eq!(
        tree.walk_linear_frozen(&pricer, tick_size(), 1),
        snapshot_reference.walk_linear(&pricer, tick_size()),
    );

    destroy(tree);
    destroy(snapshot_reference);
    cleanup(fixture, oracle);
}

#[test]
fun a_new_generation_supersedes_a_stale_snapshot_and_release_purges_its_husks() {
    let (mut fixture, oracle, pricer) = live_pricer();
    let ctx = fixture.scenario_mut().ctx();
    let mut tree = strike_payout_tree::new(ctx);
    let mut second_instant_reference = strike_payout_tree::new(ctx);

    tree.insert_range(RANGE_A_LOWER, RANGE_A_HIGHER, Q_A);
    tree.activate_snapshot(1);
    // Generation 1's flush aborts after this range is emptied to husks.
    tree.remove_range(RANGE_A_LOWER, RANGE_A_HIGHER, Q_A);
    tree.deactivate_snapshot();

    tree.insert_range(RANGE_B_LOWER, RANGE_B_HIGHER, Q_B);
    second_instant_reference.insert_range(RANGE_B_LOWER, RANGE_B_HIGHER, Q_B);
    tree.activate_snapshot(2);
    tree.insert_range(RANGE_C_LOWER, RANGE_C_HIGHER, Q_C);

    // Generation 2 sees exactly its own instant: generation 1's husks read as
    // their live zeros, and untouched nodes read live.
    assert_eq!(
        tree.walk_linear_frozen(&pricer, tick_size(), 2),
        second_instant_reference.walk_linear(&pricer, tick_size()),
    );

    // Consuming generation 2 also removes generation 1's never-consumed husks.
    // Tick 96 is the only husk left: the B range revived tick 100, and C's
    // boundaries (98, 106) plus B's (100, 104) are live.
    let husk_ticks = 1;
    let live_boundary_ticks = 4;
    assert_eq!(tree.node_count_for_testing(), husk_ticks + live_boundary_ticks);
    tree.release_snapshot();
    assert_eq!(tree.node_count_for_testing(), live_boundary_ticks);
    tree.assert_tree_invariant_for_testing();

    destroy(tree);
    destroy(second_instant_reference);
    cleanup(fixture, oracle);
}

#[test, expected_failure(abort_code = strike_payout_tree::EStaleValuationSnapshot)]
fun a_superseded_generations_frozen_walk_aborts() {
    let (mut fixture, _oracle, pricer) = live_pricer();
    let mut tree = strike_payout_tree::new(fixture.scenario_mut().ctx());
    tree.insert_range(RANGE_A_LOWER, RANGE_A_HIGHER, Q_A);
    tree.activate_snapshot(1);
    tree.activate_snapshot(2);
    tree.walk_linear_frozen(&pricer, tick_size(), 1);
    abort 999
}

#[test, expected_failure(abort_code = strike_payout_tree::EStaleValuationSnapshot)]
fun a_released_snapshots_frozen_walk_aborts() {
    let (mut fixture, _oracle, pricer) = live_pricer();
    let mut tree = strike_payout_tree::new(fixture.scenario_mut().ctx());
    tree.insert_range(RANGE_A_LOWER, RANGE_A_HIGHER, Q_A);
    tree.activate_snapshot(1);
    tree.release_snapshot();
    tree.walk_linear_frozen(&pricer, tick_size(), 1);
    abort 999
}

#[test, expected_failure(abort_code = strike_payout_tree::ESnapshotSeqNotIncreasing)]
fun activation_at_the_current_generation_aborts() {
    let (mut fixture, _oracle, _pricer) = live_pricer();
    let mut tree = strike_payout_tree::new(fixture.scenario_mut().ctx());
    tree.activate_snapshot(2);
    tree.activate_snapshot(2);
    abort 999
}

#[test]
fun releasing_a_root_husk_with_two_children_rejoins_the_survivors() {
    let (mut fixture, oracle, pricer) = live_pricer();
    let ctx = fixture.scenario_mut().ctx();
    let mut tree = strike_payout_tree::new(ctx);
    let mut survivor_reference = strike_payout_tree::new(ctx);

    // Ascending one-sided inserts at three ticks balance to the middle tick as
    // root; husking it forces `detach_tick` through the two-children rejoin
    // (`join_subtrees`/`take_min`), not the leaf shortcut.
    tree.insert_range(RANGE_A_LOWER, pos_inf_tick(), Q_A);
    tree.insert_range(RANGE_A_HIGHER, pos_inf_tick(), Q_B);
    tree.insert_range(RANGE_C_HIGHER, pos_inf_tick(), Q_C);
    survivor_reference.insert_range(RANGE_A_LOWER, pos_inf_tick(), Q_A);
    survivor_reference.insert_range(RANGE_C_HIGHER, pos_inf_tick(), Q_C);

    tree.activate_snapshot(1);
    tree.remove_range(RANGE_A_HIGHER, pos_inf_tick(), Q_B);
    assert_eq!(tree.node_count_for_testing(), 3);

    tree.release_snapshot();
    assert_eq!(tree.node_count_for_testing(), 2);
    tree.assert_tree_invariant_for_testing();
    assert_eq!(
        tree.walk_linear(&pricer, tick_size()),
        survivor_reference.walk_linear(&pricer, tick_size()),
    );

    destroy(tree);
    destroy(survivor_reference);
    cleanup(fixture, oracle);
}

/// A husk is not a live-order edge, so the live walk must not observe an
/// inversion parked on it — but the frozen walk, whose surface the husk still
/// belongs to, must. After the full close, the husk ticks are the only nodes,
/// so nothing else would observe the inversion in either view.
#[test]
fun an_inversion_on_a_husk_is_invisible_to_the_live_walk() {
    let (mut fixture, oracle, pricer) = non_monotone_pricer();
    let mut tree = strike_payout_tree::new(fixture.scenario_mut().ctx());
    tree.insert_range(INVERTED_LOWER_TICK, INVERTED_HIGHER_TICK, INVERTED_QUANTITY);
    tree.activate_snapshot(1);
    tree.remove_range(INVERTED_LOWER_TICK, INVERTED_HIGHER_TICK, INVERTED_QUANTITY);

    assert_eq!(tree.walk_linear(&pricer, tick_size()), 0);

    destroy(tree);
    cleanup(fixture, oracle);
}

#[test, expected_failure(abort_code = strike_payout_tree::ENonMonotonePrice)]
fun an_inversion_on_a_husk_still_aborts_the_frozen_walk() {
    let (mut fixture, _oracle, pricer) = non_monotone_pricer();
    let mut tree = strike_payout_tree::new(fixture.scenario_mut().ctx());
    tree.insert_range(INVERTED_LOWER_TICK, INVERTED_HIGHER_TICK, INVERTED_QUANTITY);
    tree.activate_snapshot(1);
    tree.remove_range(INVERTED_LOWER_TICK, INVERTED_HIGHER_TICK, INVERTED_QUANTITY);

    tree.walk_linear_frozen(&pricer, tick_size(), 1);
    abort 999
}

fun tick_size(): u64 { test_constants::default_tick_size() }

fun pos_inf_tick(): u64 { constants::pos_inf_tick!() }

/// A live market at the default ATM forward with an inflated base variance, as
/// in the walk tests.
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

/// A surface whose UP price RISES with strike over the active ticks, as in the
/// walk tests' monotonicity regressions.
fun non_monotone_pricer(): (OracleFixture, OracleBundle, Pricer) {
    let mut fixture = oracle_fixture::setup_oracle_default();
    let mut oracle = fixture.take_oracle_bundle();
    fixture.prepare_real_oracle_bundle(
        &mut oracle,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        1,
        false,
        test_constants::pricing_max_svi_input(),
        test_constants::pricing_min_svi_sigma(),
        test_constants::float(),
        true,
        0,
        false,
    );
    let pricer = fixture.load_pricer_bundle(&oracle);
    (fixture, oracle, pricer)
}

fun cleanup(fixture: OracleFixture, oracle: OracleBundle) {
    oracle_fixture::return_oracle_bundle(oracle);
    fixture.finish();
}
