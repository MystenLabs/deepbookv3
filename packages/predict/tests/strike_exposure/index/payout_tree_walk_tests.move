// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit coverage for `strike_payout_tree::walk_linear` — the NAV linear walk —
/// driven by a real live `Pricer` over standalone trees. These exercise paths
/// `current_nav` cannot reach directly: the bounded-interpolation gate (the
/// production `nav_interpolation_price_tolerance` is 0, so `current_nav` always
/// walks exactly), the skip-zero-delta path over a dead (fully-removed) boundary
/// that the treap never garbage-collects, and the boundary-aggregation dust clamp
/// — the flat-price-tail integer underflow the ATM `current_nav` fixtures miss.
///
/// The oracle uses an inflated base variance so three adjacent strikes carry
/// genuinely clustered (close, smoothly decreasing, nonzero) prices — the regime
/// where interpolation is meant to help.
///
/// References are independent of the walk (unit-tests rule 1): the exact walk is
/// checked against a per-order `Σ mul(range_price, qty)` sum, and the interpolated
/// walk against that same sum within the gate's own `tolerance · quantity` bound.
#[test_only]
module deepbook_predict::payout_tree_walk_tests;

use deepbook_predict::{
    constants,
    market_oracle::{Self, MarketOracle},
    oracle_fixture::{Self, OracleFixture},
    pricing::{Self, Pricer},
    protocol_config::ProtocolConfig,
    pyth_source::PythSource,
    strike_grid::{Self, StrikeGrid},
    strike_payout_tree::{Self, StrikePayoutTree},
    test_constants,
    test_helpers
};
use fixed_math::{i64, math};
use std::unit_test::assert_eq;

/// Inflated SVI base variance (0.1 in 1e9 fixed point) so adjacent-tick strikes
/// price close together and smoothly — a real clustered-price regime.
const HIGH_VARIANCE_A: u64 = 100_000_000;
/// Dominant high-price quantity so the midpoint collapse visibly moves the mark.
const Q0: u64 = 10_000_000_000;
const Q1: u64 = 2_000_000_000;
const Q2: u64 = 2_000_000_000;
const DEAD_QUANTITY: u64 = 3_000_000_000;
const LIVE_QUANTITY: u64 = 5_000_000_000;
/// Forward far above the grid so low strikes sit in the deep-ITM flat price tail
/// where adjacent ticks price within a floor bucket — the dust-underflow regime.
const FLAT_REGION_FORWARD: u64 = 435_000_000_000;
/// Tiny quantity (a partial-close survivor) whose per-order range value rounds to
/// zero, so only boundary-aggregation rounding remains.
const DUST_QUANTITY: u64 = 100_000;

#[test]
fun exact_walk_matches_per_order_reference() {
    let (mut fixture, pyth, oracle, config, pricer) = live_pricer();
    let grid = standalone_grid();
    let mut tree = strike_payout_tree::new(fixture.scenario_mut().ctx());

    let (s0, s1, s2) = clustered_strikes();
    insert_up(&mut tree, &grid, s0, Q0);
    insert_up(&mut tree, &grid, s1, Q1);
    insert_up(&mut tree, &grid, s2, Q2);

    // Exact walk (tolerance 0) equals the independent per-order sum bit-for-bit:
    // each one-sided order is its own node, so there is no aggregation dust.
    let exact = tree.walk_linear(&pricer, 0);
    assert_eq!(exact, up_reference(&pricer, vector[s0, s1, s2], vector[Q0, Q1, Q2]));

    tree.destroy();
    cleanup(fixture, pyth, oracle, config);
}

#[test]
fun interpolation_collapses_subtree_within_bound() {
    let (mut fixture, pyth, oracle, config, pricer) = live_pricer();
    let grid = standalone_grid();
    let mut tree = strike_payout_tree::new(fixture.scenario_mut().ctx());

    let (s0, s1, s2) = clustered_strikes();
    insert_up(&mut tree, &grid, s0, Q0);
    insert_up(&mut tree, &grid, s1, Q1);
    insert_up(&mut tree, &grid, s2, Q2);

    let reference = up_reference(&pricer, vector[s0, s1, s2], vector[Q0, Q1, Q2]);
    let total_quantity = Q0 + Q1 + Q2;

    // Tolerance == the whole tree's exact price span, so the root subtree collapses
    // to one midpoint price applied to the aggregate quantity.
    let high_price = pricer.up_price(s0); // lowest strike -> highest price
    let low_price = pricer.up_price(s2);
    let span = high_price - low_price;
    let interpolated = tree.walk_linear(&pricer, span);

    // Engagement: the result is exactly the midpoint-collapsed value (the gate
    // fired over the whole tree) and differs from the exact walk.
    let midpoint = (high_price + low_price) / 2;
    assert_eq!(interpolated, math::mul(midpoint, total_quantity));
    assert!(interpolated != tree.walk_linear(&pricer, 0));

    // Bound: within `tolerance · total_quantity` of the true per-order value, a
    // bound derived from the gate inputs (span, quantities), never from output.
    test_helpers::assert_within(interpolated, reference, math::mul(span, total_quantity));

    tree.destroy();
    cleanup(fixture, pyth, oracle, config);
}

#[test]
fun skip_zero_delta_ignores_dead_boundaries() {
    let (mut fixture, pyth, oracle, config, pricer) = live_pricer();
    let grid = standalone_grid();
    let mut tree = strike_payout_tree::new(fixture.scenario_mut().ctx());

    let (s0, s1, s2) = clustered_strikes();
    // Insert then fully remove a finite range: its boundary nodes persist (the
    // treap never GCs) with zeroed local quantity -> skip-zero-delta must skip them.
    tree.insert_range(&grid, s1, s2, DEAD_QUANTITY, DEAD_QUANTITY, DEAD_QUANTITY);
    tree.remove_range(&grid, s1, s2, DEAD_QUANTITY, DEAD_QUANTITY, DEAD_QUANTITY);
    insert_up(&mut tree, &grid, s0, LIVE_QUANTITY);

    // Only the live order is valued; the dead s1/s2 nodes contribute nothing.
    let walk = tree.walk_linear(&pricer, 0);
    assert_eq!(walk, up_reference(&pricer, vector[s0], vector[LIVE_QUANTITY]));

    tree.destroy();
    cleanup(fixture, pyth, oracle, config);
}

#[test]
fun walk_linear_clamps_boundary_aggregation_dust() {
    let (mut fixture, pyth, oracle, config, pricer) = live_pricer_at(FLAT_REGION_FORWARD);
    let grid = standalone_grid();
    let mut tree = strike_payout_tree::new(fixture.scenario_mut().ctx());

    let s0 = test_constants::min_finite_strike();
    let tick = test_constants::default_tick_size();
    let lower_a = s0; // 100e9, up ~999_996_456
    let lower_b = s0 + tick; // 101e9, up ~999_995_893
    let higher = s0 + 2 * tick; // 102e9, up ~999_995_253, shared upper boundary

    // Two thin ITM ranges sharing the higher boundary, each one dust lot. In this
    // flat tail the end-side floor at the shared boundary aggregates 1 ulp above the
    // two start-side floors (199_999 vs 99_999+99_999), so the raw
    // base+start-end would underflow to -1 and abort. The clamp returns 0.
    tree.insert_range(&grid, lower_a, higher, DUST_QUANTITY, DUST_QUANTITY, DUST_QUANTITY);
    tree.insert_range(&grid, lower_b, higher, DUST_QUANTITY, DUST_QUANTITY, DUST_QUANTITY);

    // Independent per-order reference: both ranges' values round to 0, so true
    // linear liability is 0 — the clamped walk agrees (the floored dust was spurious).
    let reference =
        math::mul(pricer.range_price(lower_a, higher), DUST_QUANTITY) +
        math::mul(pricer.range_price(lower_b, higher), DUST_QUANTITY);
    assert_eq!(reference, 0);
    assert_eq!(tree.walk_linear(&pricer, 0), 0);

    tree.destroy();
    cleanup(fixture, pyth, oracle, config);
}

// === Helpers ===

fun clustered_strikes(): (u64, u64, u64) {
    let s0 = test_constants::min_finite_strike();
    let tick = test_constants::default_tick_size();
    (s0, s0 + tick, s0 + 2 * tick)
}

fun standalone_grid(): StrikeGrid {
    strike_grid::new_centered(
        test_constants::default_creation_spot(),
        test_constants::default_tick_size(),
    )
}

/// Insert a one-sided up range `(strike, +inf]` carrying `quantity` (1x-shaped
/// terms; `walk_linear` reads only the quantity).
fun insert_up(tree: &mut StrikePayoutTree, grid: &StrikeGrid, strike: u64, quantity: u64) {
    tree.insert_range(grid, strike, constants::pos_inf!(), quantity, quantity, quantity);
}

/// Independent linear reference: `Σ mul(range_price(strike, +inf), quantity)`.
fun up_reference(pricer: &Pricer, strikes: vector<u64>, quantities: vector<u64>): u64 {
    let mut total = 0;
    strikes.length().do!(|i| {
        total =
            total + math::mul(pricer.range_price(strikes[i], constants::pos_inf!()), quantities[i]);
    });
    total
}

/// A live market at the default ATM forward with an inflated base variance so
/// adjacent strikes are clustered in price, plus a `Pricer` snapshot over it.
fun live_pricer(): (OracleFixture, PythSource, MarketOracle, ProtocolConfig, Pricer) {
    live_pricer_at(test_constants::default_live_price())
}

/// `live_pricer` with an explicit forward (used to reach the deep-ITM flat tail).
fun live_pricer_at(
    forward: u64,
): (OracleFixture, PythSource, MarketOracle, ProtocolConfig, Pricer) {
    let mut fixture = oracle_fixture::setup_oracle_default();
    let (mut pyth, mut oracle, config) = fixture.take_oracle();
    let svi = market_oracle::new_svi_params(
        HIGH_VARIANCE_A,
        test_constants::default_svi_b(),
        i64::from_u64(test_constants::default_svi_rho_magnitude()),
        i64::from_u64(test_constants::default_svi_m()),
        constants::svi_sigma_min!(),
    );
    fixture.prepare_real_oracle(&config, &mut oracle, &mut pyth, forward, forward, svi);
    let pricer = pricing::pricer(config.pricing_config(), &oracle, &pyth, fixture.clock());
    (fixture, pyth, oracle, config, pricer)
}

fun cleanup(
    fixture: OracleFixture,
    pyth: PythSource,
    oracle: MarketOracle,
    config: ProtocolConfig,
) {
    oracle_fixture::return_oracle(pyth, oracle, config);
    fixture.finish();
}
