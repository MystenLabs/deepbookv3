// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit coverage for `strike_payout_tree::walk_linear` — the NAV linear walk —
/// driven by a real live `Pricer` over standalone trees. These exercise paths
/// `current_nav` cannot reach directly: the per-flush price memo populated for
/// the correction walk, the skip-zero-delta path over an equal live start/end
/// boundary, and the boundary-aggregation dust clamp — the flat-price-tail integer
/// underflow the ATM `current_nav` fixtures miss.
///
/// The tree keys boundaries by absolute tick; the walk recovers each raw strike as
/// `tick * tick_size`. These tests use the default `tick_size` (1e9) so tick `100`
/// is raw strike `100e9`.
///
/// References are independent of the walk (unit-tests rule 1): the exact walk is
/// checked against a per-order `Σ mul(range_price, qty)` sum (a different pricer
/// path than the walk's `up_price`). Memo lookup checks compare the cached boundary
/// prices against `range_price` so a stale or missing memo entry is visible.
#[test_only]
module deepbook_predict::payout_tree_walk_tests;

use deepbook_predict::{
    constants,
    oracle_fixture::{Self, OracleBundle, OracleFixture},
    pricing::{Self, Pricer},
    range_codec::{Self, Strike},
    strike_payout_tree::{Self, StrikePayoutTree},
    test_constants
};
use fixed_math::math;
use std::unit_test::{assert_eq, destroy};

/// Inflated SVI base variance (0.1 in 1e9 fixed point) so adjacent-tick strikes
/// price close together and smoothly — a real clustered-price regime.
const HIGH_VARIANCE_A: u64 = 100_000_000;
/// Dominant high-price quantity so the midpoint collapse visibly moves the mark.
const Q0: u64 = 10_000_000_000;
const Q1: u64 = 2_000_000_000;
const Q2: u64 = 2_000_000_000;
const ADJACENT_QUANTITY: u64 = 5_000_000_000;
const CORRELATED_LEFT_QUANTITY: u64 = 5_000_000_000;
const CORRELATED_RIGHT_QUANTITY: u64 = 4_000_000_000;
/// Forward far above the grid so low strikes sit in the deep-ITM flat price tail
/// where adjacent ticks price within a floor bucket — the dust-underflow regime.
const FLAT_REGION_FORWARD: u64 = 435_000_000_000;
/// Tiny quantity (a partial-close survivor) whose per-order range value rounds to
/// zero, so only boundary-aggregation rounding remains.
const DUST_QUANTITY: u64 = 100_000;
const GC_SURVIVOR_A_LOWER: u64 = 98;
const GC_REMOVED_LOWER: u64 = 100;
const GC_SURVIVOR_C_LOWER: u64 = 102;
const GC_SURVIVOR_A_HIGHER: u64 = 104;
const GC_REMOVED_HIGHER: u64 = 106;
const GC_SURVIVOR_C_HIGHER: u64 = 108;
const GC_SURVIVOR_A_QUANTITY: u64 = 1_000_000_000;
const GC_REMOVED_QUANTITY: u64 = 500_000_000;
const GC_SURVIVOR_C_QUANTITY: u64 = 300_000_000;
const GC_SETTLEMENT_A_ONLY_TICK: u64 = 100;
const GC_SETTLEMENT_OVERLAP_TICK: u64 = 103;
const GC_SETTLEMENT_C_ONLY_TICK: u64 = 106;

#[test]
fun exact_walk_matches_per_order_reference() {
    let (mut fixture, oracle, pricer) = live_pricer();
    let mut tree = strike_payout_tree::new(fixture.scenario_mut().ctx());

    let (t0, t1, t2) = clustered_ticks();
    insert_up(&mut tree, t0, Q0);
    insert_up(&mut tree, t1, Q1);
    insert_up(&mut tree, t2, Q2);

    // The exact walk equals the independent per-order sum bit-for-bit: each
    // one-sided order is its own node, so there is no aggregation dust.
    let exact = walk_linear(&tree, &pricer);
    assert_eq!(exact, up_reference(&pricer, vector[t0, t1, t2], vector[Q0, Q1, Q2]));

    destroy(tree);
    cleanup(fixture, oracle);
}

#[test]
fun walk_linear_caches_boundaries_in_tick_order_for_range_lookup() {
    let (mut fixture, oracle, pricer) = live_pricer();
    let mut tree = strike_payout_tree::new(fixture.scenario_mut().ctx());

    let (t0, t1, t2) = clustered_ticks();
    insert_up(&mut tree, t2, Q2);
    insert_up(&mut tree, t0, Q0);
    insert_up(&mut tree, t1, Q1);

    // Insertion order is intentionally not sorted. The in-order walk must still
    // cache ascending ticks, because `cached_range_price` uses binary search.
    let mut memo = pricing::new_price_memo();
    let walk = tree.walk_linear(&pricer, &mut memo, tick_size()).magnitude();
    assert_eq!(walk, up_reference(&pricer, vector[t0, t1, t2], vector[Q0, Q1, Q2]));
    assert_eq!(memo.cached_range_price(t0, t2).magnitude(), pricer.range_price(raw(t0), raw(t2)));
    assert_eq!(memo.cached_range_price(0, t0).magnitude(), pricer.range_price(raw(0), raw(t0)));
    assert_eq!(
        memo.cached_range_price(t2, constants::pos_inf_tick!()).magnitude(),
        pricer.range_price(raw(t2), raw(constants::pos_inf_tick!())),
    );

    destroy(tree);
    cleanup(fixture, oracle);
}

#[test]
fun skip_zero_delta_keeps_adjacent_live_ranges_exact() {
    let (mut fixture, oracle, pricer) = live_pricer();
    let mut tree = strike_payout_tree::new(fixture.scenario_mut().ctx());

    let (t0, t1, t2) = clustered_ticks();
    // Adjacent live ranges with the same quantity leave an equal nonzero start/end
    // at the shared boundary. The exact walk may skip pricing that boundary because
    // the two sides cancel.
    tree.insert_range(t0, t1, ADJACENT_QUANTITY, 0);
    tree.insert_range(t1, t2, ADJACENT_QUANTITY, 0);

    let mut memo = pricing::new_price_memo();
    let walk = tree.walk_linear(&pricer, &mut memo, tick_size()).magnitude();
    assert_eq!(
        walk,
        range_reference(
            &pricer,
            vector[t0, t1],
            vector[t1, t2],
            vector[ADJACENT_QUANTITY, ADJACENT_QUANTITY],
        ),
    );
    // The shared boundary has equal start/end quantity and contributes no net
    // linear value, but it must still be cached for leveraged correction lookups.
    assert_eq!(memo.cached_range_price(t0, t1).magnitude(), pricer.range_price(raw(t0), raw(t1)));
    assert_eq!(memo.cached_range_price(t1, t2).magnitude(), pricer.range_price(raw(t1), raw(t2)));

    destroy(tree);
    cleanup(fixture, oracle);
}

#[test]
fun shared_boundary_error_scales_with_net_not_gross_quantity() {
    let (mut fixture, oracle, pricer) = live_pricer();
    let mut tree = strike_payout_tree::new(fixture.scenario_mut().ctx());
    let (t0, t1, t2) = clustered_ticks();
    tree.insert_range(t0, t1, CORRELATED_LEFT_QUANTITY, 0);
    tree.insert_range(t1, t2, CORRELATED_RIGHT_QUANTITY, 0);

    let mut memo = pricing::new_price_memo();
    let approximate = tree.walk_linear(&pricer, &mut memo, tick_size());
    assert_eq!(
        approximate.magnitude(),
        range_reference(
            &pricer,
            vector[t0, t1],
            vector[t1, t2],
            vector[CORRELATED_LEFT_QUANTITY, CORRELATED_RIGHT_QUANTITY],
        ),
    );

    let shared_net = CORRELATED_LEFT_QUANTITY - CORRELATED_RIGHT_QUANTITY;
    let expected_shared = expected_boundary_error(&memo, t1, shared_net);
    let uncorrelated_shared = expected_boundary_error(
        &memo,
        t1,
        CORRELATED_LEFT_QUANTITY + CORRELATED_RIGHT_QUANTITY,
    );
    assert!(expected_shared < uncorrelated_shared);
    assert_eq!(
        approximate.error(),
        expected_boundary_error(&memo, t0, CORRELATED_LEFT_QUANTITY)
            + expected_shared
            + expected_boundary_error(&memo, t2, CORRELATED_RIGHT_QUANTITY),
    );

    destroy(tree);
    cleanup(fixture, oracle);
}

#[test]
fun walk_linear_clamps_boundary_aggregation_dust() {
    let (mut fixture, oracle, pricer) = live_pricer_at(FLAT_REGION_FORWARD);
    let mut tree = strike_payout_tree::new(fixture.scenario_mut().ctx());

    let t0 = test_constants::default_strike_tick();
    let lower_a = t0; // raw 100e9, up ~999_996_456
    let lower_b = t0 + 1; // raw 101e9, up ~999_995_893
    let higher = t0 + 2; // raw 102e9, up ~999_995_253, shared upper boundary

    // Two thin ITM ranges sharing the higher boundary, each one dust lot. In this
    // flat tail the end-side floor at the shared boundary aggregates 1 ulp above the
    // two start-side floors (199_999 vs 99_999+99_999), so the raw
    // base+start-end would underflow to -1 and abort. The clamp returns 0.
    tree.insert_range(lower_a, higher, DUST_QUANTITY, 0);
    tree.insert_range(lower_b, higher, DUST_QUANTITY, 0);

    // Independent per-order reference: both ranges' values round to 0, so true
    // linear liability is 0 — the clamped walk agrees (the floored dust was spurious).
    let reference =
        math::mul(pricer.range_price(raw(lower_a), raw(higher)), DUST_QUANTITY) +
        math::mul(pricer.range_price(raw(lower_b), raw(higher)), DUST_QUANTITY);
    assert_eq!(reference, 0);
    assert_eq!(walk_linear(&tree, &pricer), 0);

    destroy(tree);
    cleanup(fixture, oracle);
}

#[test]
fun gc_mutated_tree_walk_matches_rebuilt_survivor_tree() {
    let (mut fixture, oracle, pricer) = live_pricer();
    let mut tree = strike_payout_tree::new(fixture.scenario_mut().ctx());

    tree.insert_range(GC_SURVIVOR_A_LOWER, GC_SURVIVOR_A_HIGHER, GC_SURVIVOR_A_QUANTITY, 0);
    tree.insert_range(GC_REMOVED_LOWER, GC_REMOVED_HIGHER, GC_REMOVED_QUANTITY, 0);
    tree.insert_range(GC_SURVIVOR_C_LOWER, GC_SURVIVOR_C_HIGHER, GC_SURVIVOR_C_QUANTITY, 0);

    // Removing the middle range deletes two interior boundary nodes through GC; the walk, settlement,
    // and rebuilt-tree assertions below prove those boundaries left no trace.
    tree.remove_range(GC_REMOVED_LOWER, GC_REMOVED_HIGHER, GC_REMOVED_QUANTITY, 0);

    let mut rebuilt = strike_payout_tree::new(fixture.scenario_mut().ctx());
    rebuilt.insert_range(GC_SURVIVOR_A_LOWER, GC_SURVIVOR_A_HIGHER, GC_SURVIVOR_A_QUANTITY, 0);
    rebuilt.insert_range(GC_SURVIVOR_C_LOWER, GC_SURVIVOR_C_HIGHER, GC_SURVIVOR_C_QUANTITY, 0);

    let settlement_a_only = GC_SETTLEMENT_A_ONLY_TICK * tick_size();
    let settled_a_only = tree.settled_payout_liability(settlement_a_only, tick_size());
    assert_eq!(settled_a_only, rebuilt.settled_payout_liability(settlement_a_only, tick_size()));
    assert_eq!(settled_a_only, GC_SURVIVOR_A_QUANTITY);
    let settlement_overlap = GC_SETTLEMENT_OVERLAP_TICK * tick_size();
    let settled_overlap = tree.settled_payout_liability(settlement_overlap, tick_size());
    assert_eq!(settled_overlap, rebuilt.settled_payout_liability(settlement_overlap, tick_size()));
    assert_eq!(settled_overlap, GC_SURVIVOR_A_QUANTITY + GC_SURVIVOR_C_QUANTITY);
    let settlement_c_only = GC_SETTLEMENT_C_ONLY_TICK * tick_size();
    let settled_c_only = tree.settled_payout_liability(settlement_c_only, tick_size());
    assert_eq!(settled_c_only, rebuilt.settled_payout_liability(settlement_c_only, tick_size()));
    assert_eq!(settled_c_only, GC_SURVIVOR_C_QUANTITY);

    let mutated_walk = walk_linear(&tree, &pricer);
    let rebuilt_walk = walk_linear(&rebuilt, &pricer);
    let reference = range_reference(
        &pricer,
        vector[GC_SURVIVOR_A_LOWER, GC_SURVIVOR_C_LOWER],
        vector[GC_SURVIVOR_A_HIGHER, GC_SURVIVOR_C_HIGHER],
        vector[GC_SURVIVOR_A_QUANTITY, GC_SURVIVOR_C_QUANTITY],
    );
    assert_eq!(mutated_walk, rebuilt_walk);
    assert_eq!(mutated_walk, reference);

    destroy(tree);
    destroy(rebuilt);
    cleanup(fixture, oracle);
}

// === Helpers ===

/// The walk's `tick_size`: the default (1e9), so tick `t` maps to raw strike
/// `t * 1e9`.
fun tick_size(): u64 { test_constants::default_tick_size() }

/// Strike for a tick under the default `tick_size` (tick 0 and `pos_inf_tick`
/// map to the open-ended sentinels).
fun raw(tick: u64): Strike { range_codec::strike_from_tick(tick, tick_size()) }

/// Run the exact linear walk with the production price memo.
fun walk_linear(tree: &StrikePayoutTree, pricer: &Pricer): u64 {
    let mut memo = pricing::new_price_memo();
    tree.walk_linear(pricer, &mut memo, tick_size()).magnitude()
}

/// Independent error budget for one boundary with one shared uncertain UP price:
/// `ceil(price_error * |start-end| / 1e9)` plus two product-floor units.
fun expected_boundary_error(memo: &pricing::PriceMemo, tick: u64, net_quantity: u64): u64 {
    let price = memo.cached_range_price(tick, constants::pos_inf_tick!());
    math::mul_div_up(price.error(), net_quantity, math::float_scaling!()) + 2
}

/// Three adjacent finite ticks around the canonical finite strike (100, 101, 102).
fun clustered_ticks(): (u64, u64, u64) {
    let t0 = test_constants::default_strike_tick();
    (t0, t0 + 1, t0 + 2)
}

/// Insert a one-sided up range `(tick, pos_inf]` carrying `quantity` (1x-shaped
/// terms; `walk_linear` reads only the quantity).
fun insert_up(tree: &mut StrikePayoutTree, tick: u64, quantity: u64) {
    tree.insert_range(tick, constants::pos_inf_tick!(), quantity, 0);
}

/// Independent linear reference: `Σ mul(range_price(tick·ts, +inf), quantity)`.
/// Uses `range_price` (a different pricer path than the walk's `up_price`).
fun up_reference(pricer: &Pricer, ticks: vector<u64>, quantities: vector<u64>): u64 {
    let mut total = 0;
    ticks.length().do!(|i| {
        total =
            total + math::mul(
                pricer.range_price(raw(ticks[i]), raw(constants::pos_inf_tick!())),
                quantities[i],
            );
    });
    total
}

/// Independent finite-range reference: `Σ mul(range_price(lower·ts, higher·ts), quantity)`.
/// Uses `range_price` (a different pricer path than the walk's `up_price`).
fun range_reference(
    pricer: &Pricer,
    lower_ticks: vector<u64>,
    higher_ticks: vector<u64>,
    quantities: vector<u64>,
): u64 {
    let mut total = 0;
    lower_ticks.length().do!(|i| {
        let range_price = pricer.range_price(raw(lower_ticks[i]), raw(higher_ticks[i]));
        total = total + math::mul(range_price, quantities[i]);
    });
    total
}

/// A live market at the default ATM forward with an inflated base variance so
/// adjacent strikes are clustered in price, plus a `Pricer` snapshot over it.
fun live_pricer(): (OracleFixture, OracleBundle, Pricer) {
    live_pricer_at(test_constants::default_live_price())
}

/// `live_pricer` with an explicit forward (used to reach the deep-ITM flat tail).
fun live_pricer_at(forward: u64): (OracleFixture, OracleBundle, Pricer) {
    let mut fixture = oracle_fixture::setup_oracle_default();
    let mut oracle = fixture.take_oracle_bundle();
    // Inflated base variance, otherwise the default (positive) SVI shape; spot ==
    // forward gives basis 1.0. sigma == the propbook floor (default_svi_sigma).
    fixture.prepare_real_oracle_bundle(
        &mut oracle,
        forward,
        forward,
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
