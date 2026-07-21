// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit coverage for `strike_payout_tree::walk_linear_cached` — the flush
/// valuation's pruned-tree re-walk that reads boundary prices from the memo the
/// first walk filled, instead of re-pricing. The behavior pin is BIT-IDENTITY:
/// on any tree whose finite boundaries are all cached, the cached walk must
/// reproduce `walk_linear`'s value exactly (same per-node `math::mul` rounding,
/// same equal-quantity skip, same one saturating floor at the top), because the
/// flush's zero-liquidatable mark equality with `current_nav` rides on it.
/// Value-level truth is anchored the same way `payout_tree_walk_tests` anchors
/// it: an independent per-order `Σ mul(range_price, qty)` reference over trees
/// shaped so boundary aggregation introduces no dust.
#[test_only]
module deepbook_predict::payout_tree_walk_cached_tests;

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
/// price close together and smoothly — real distinct boundary prices.
const HIGH_VARIANCE_A: u64 = 100_000_000;
/// Down range `(-inf, T0]`: enters through `tree.base` (the `P(-inf) = 1` anchor).
/// All three quantities are multiples of 1e9 (the price scale), so every
/// boundary product `mul(price, quantity)` is exact and the per-order reference
/// equals the boundary-aggregated walks bit-for-bit with no rounding dust.
const Q_DOWN: u64 = 3_000_000_000;
/// Finite range `(T0, T2]`: start and end boundary products at distinct nodes.
const Q_MID: u64 = 2_000_000_000;
/// Up range `(T1, +inf]`: start-only boundary (`+inf` ends are never stored).
const Q_UP: u64 = 1_000_000_000;
/// A boundary added AFTER the memo was filled, for the miss-abort pin.
const UNCACHED_TICK: u64 = 103;
const UNCACHED_QUANTITY: u64 = 1_000_000_000;
/// Forward far above the grid so low strikes sit in the deep-ITM flat price
/// tail where the boundary-aggregation dust clamp fires (see
/// `payout_tree_walk_tests::walk_linear_clamps_boundary_aggregation_dust`).
const FLAT_REGION_FORWARD: u64 = 435_000_000_000;
/// Tiny quantity whose per-order range value rounds to zero in the flat tail.
const DUST_QUANTITY: u64 = 100_000;

#[test]
fun cached_rewalk_of_unchanged_tree_matches_fresh_walk_and_reference() {
    let (mut fixture, oracle, pricer) = live_pricer();
    let mut tree = strike_payout_tree::new(fixture.scenario_mut().ctx());
    let (t0, t1, t2) = clustered_ticks();
    insert_mixed_book(&mut tree, t0, t1, t2);

    let mut memo = pricing::new_price_memo();
    let fresh = tree.walk_linear(&pricer, &mut memo, tick_size());

    // Each order occupies its own side of its nodes, so the walk equals the
    // independent per-order sum bit-for-bit — no aggregation dust.
    assert_eq!(
        fresh,
        range_reference(
            &pricer,
            vector[0, t0, t1],
            vector[t0, t2, constants::pos_inf_tick!()],
            vector[Q_DOWN, Q_MID, Q_UP],
        ),
    );
    assert_eq!(tree.walk_linear_cached(&memo), fresh);

    destroy(tree);
    cleanup(fixture, oracle);
}

#[test]
fun cached_rewalk_of_pruned_tree_matches_repriced_walk_and_reference() {
    let (mut fixture, oracle, pricer) = live_pricer();
    let mut tree = strike_payout_tree::new(fixture.scenario_mut().ctx());
    let (t0, t1, t2) = clustered_ticks();
    insert_mixed_book(&mut tree, t0, t1, t2);

    let mut memo = pricing::new_price_memo();
    tree.walk_linear(&pricer, &mut memo, tick_size());

    // Prune the finite range the way a valuation-pass kill does: its end node
    // T2 goes empty and is GC'd from the tree, while its start node T0 remains
    // for the down range. The stale T2 entry left in the memo must be inert.
    tree.remove_range(t0, t2, Q_MID, 0);

    let cached = tree.walk_linear_cached(&memo);
    let mut repriced_memo = pricing::new_price_memo();
    let repriced = tree.walk_linear(&pricer, &mut repriced_memo, tick_size());
    assert_eq!(cached, repriced);
    assert_eq!(
        cached,
        range_reference(
            &pricer,
            vector[0, t1],
            vector[t0, constants::pos_inf_tick!()],
            vector[Q_DOWN, Q_UP],
        ),
    );

    destroy(tree);
    cleanup(fixture, oracle);
}

#[test, expected_failure(abort_code = pricing::ETickNotInPriceMemo)]
fun cached_rewalk_with_uncached_node_tick_aborts() {
    let (mut fixture, oracle, pricer) = live_pricer();
    let mut tree = strike_payout_tree::new(fixture.scenario_mut().ctx());
    let (t0, t1, t2) = clustered_ticks();
    insert_mixed_book(&mut tree, t0, t1, t2);

    let mut memo = pricing::new_price_memo();
    tree.walk_linear(&pricer, &mut memo, tick_size());

    // A boundary the first walk never priced is a broken-index state for the
    // re-walk: it must abort, never silently misprice the node.
    tree.insert_range(UNCACHED_TICK, constants::pos_inf_tick!(), UNCACHED_QUANTITY, 0);
    tree.walk_linear_cached(&memo);
    abort 999
}

#[test]
fun cached_rewalk_clamps_boundary_aggregation_dust() {
    let (mut fixture, oracle, pricer) = live_pricer_at(FLAT_REGION_FORWARD);
    let mut tree = strike_payout_tree::new(fixture.scenario_mut().ctx());

    // Same dust shape as `walk_linear_clamps_boundary_aggregation_dust`: the
    // end-side floor at the shared boundary aggregates 1 ulp above the two
    // start-side floors, so the raw base+start-end is -1. True liability is 0
    // (both per-order values round to 0); the cached walk must clamp too.
    let t0 = test_constants::default_strike_tick();
    tree.insert_range(t0, t0 + 2, DUST_QUANTITY, 0);
    tree.insert_range(t0 + 1, t0 + 2, DUST_QUANTITY, 0);

    let mut memo = pricing::new_price_memo();
    assert_eq!(tree.walk_linear(&pricer, &mut memo, tick_size()), 0);
    assert_eq!(tree.walk_linear_cached(&memo), 0);

    destroy(tree);
    cleanup(fixture, oracle);
}

// === Helpers ===

/// The walk's `tick_size`: the default (1e9), so tick `t` maps to raw strike `t * 1e9`.
fun tick_size(): u64 { test_constants::default_tick_size() }

/// Strike for a tick under the default `tick_size` (tick 0 and `pos_inf_tick`
/// map to the open-ended sentinels).
fun raw(tick: u64): Strike { range_codec::strike_from_tick(tick, tick_size()) }

/// Three adjacent finite ticks around the canonical finite strike (100, 101, 102).
fun clustered_ticks(): (u64, u64, u64) {
    let t0 = test_constants::default_strike_tick();
    (t0, t0 + 1, t0 + 2)
}

/// One base-anchored down range, one finite range, one up range: covers the
/// `base` anchor, paired start/end nodes, and a start-only node.
fun insert_mixed_book(tree: &mut StrikePayoutTree, t0: u64, t1: u64, t2: u64) {
    tree.insert_range(0, t0, Q_DOWN, 0);
    tree.insert_range(t0, t2, Q_MID, 0);
    tree.insert_range(t1, constants::pos_inf_tick!(), Q_UP, 0);
}

/// Independent per-order reference: `Σ mul(range_price(lower·ts, higher·ts), quantity)`.
/// Uses `range_price` (a different pricer path than the walks' `up_price`).
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
/// adjacent strikes carry distinct smooth prices, plus a `Pricer` snapshot.
fun live_pricer(): (OracleFixture, OracleBundle, Pricer) {
    live_pricer_at(test_constants::default_live_price())
}

/// `live_pricer` with an explicit forward (used to reach the deep-ITM flat tail).
fun live_pricer_at(forward: u64): (OracleFixture, OracleBundle, Pricer) {
    let mut fixture = oracle_fixture::setup_oracle_default();
    let mut oracle = fixture.take_oracle_bundle();
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
