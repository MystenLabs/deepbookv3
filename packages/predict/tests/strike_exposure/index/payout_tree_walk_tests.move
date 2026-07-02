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
/// Forward far above the grid so low strikes sit in the deep-ITM flat price tail
/// where adjacent ticks price within a floor bucket — the dust-underflow regime.
const FLAT_REGION_FORWARD: u64 = 435_000_000_000;
/// Tiny quantity (a partial-close survivor) whose per-order range value rounds to
/// zero, so only boundary-aggregation rounding remains.
const DUST_QUANTITY: u64 = 100_000;

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
    let walk = tree.walk_linear(&pricer, tick_size(), &mut memo);
    assert_eq!(walk, up_reference(&pricer, vector[t0, t1, t2], vector[Q0, Q1, Q2]));
    assert_eq!(memo.cached_range_price(t0, t2), pricer.range_price(raw(t0), raw(t2)));
    assert_eq!(memo.cached_range_price(0, t0), pricer.range_price(constants::neg_inf!(), raw(t0)));
    assert_eq!(
        memo.cached_range_price(t2, constants::pos_inf_tick!()),
        pricer.range_price(raw(t2), constants::pos_inf!()),
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
    let walk = tree.walk_linear(&pricer, tick_size(), &mut memo);
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
    assert_eq!(memo.cached_range_price(t0, t1), pricer.range_price(raw(t0), raw(t1)));
    assert_eq!(memo.cached_range_price(t1, t2), pricer.range_price(raw(t1), raw(t2)));

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

// === Helpers ===

/// The walk's `tick_size`: the default (1e9), so tick `t` maps to raw strike
/// `t * 1e9`.
fun tick_size(): u64 { test_constants::default_tick_size() }

/// Raw strike for a tick under the default `tick_size`.
fun raw(tick: u64): u64 { tick * tick_size() }

/// Run the exact linear walk with the production price memo.
fun walk_linear(tree: &StrikePayoutTree, pricer: &Pricer): u64 {
    let mut memo = pricing::new_price_memo();
    tree.walk_linear(pricer, tick_size(), &mut memo)
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
            total + math::mul(pricer.range_price(raw(ticks[i]), constants::pos_inf!()), quantities[i]);
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
