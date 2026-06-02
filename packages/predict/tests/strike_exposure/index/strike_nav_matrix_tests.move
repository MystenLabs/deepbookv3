// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::strike_nav_matrix_tests;

use deepbook_predict::{
    constants::{Self, float_scaling as float},
    pricing,
    strike_grid::{Self, StrikeGrid},
    strike_nav_matrix::{Self, StrikeNavMatrix}
};
use std::unit_test::{assert_eq, destroy};

// Grid: 11 ticks 100..200 with tick=10. Small enough to keep math by hand
// straightforward while spanning more than one matrix page boundary for
// large stress cases.
const MIN_STRIKE: u64 = 100;
const TICK_SIZE: u64 = 10;
const MAX_STRIKE: u64 = 200;
const FULL_PREALLOCATED_TICKS: u64 = 10;
const TOO_MANY_PREALLOCATED_TICKS: u64 = 11;

const WIDE_MIN_STRIKE: u64 = 10;
const WIDE_MAX_STRIKE: u64 = 3_010;
const PARTIAL_PREALLOCATED_TICKS: u64 = 10;
const PARTIAL_PREALLOCATED_PAGE_COUNT: u64 = 1;
const OUTER_LOWER_STRIKE: u64 = 20;
const OUTER_HIGHER_STRIKE: u64 = 30;

const QTY_ONE: u64 = 1;
const QTY_BIG: u64 = 1_000_000;

fun grid(): StrikeGrid {
    strike_grid::new_for_testing(MIN_STRIKE, TICK_SIZE, MAX_STRIKE)
}

fun wide_grid(): StrikeGrid {
    strike_grid::new_for_testing(WIDE_MIN_STRIKE, TICK_SIZE, WIDE_MAX_STRIKE)
}

fun new_nav(ctx: &mut TxContext): (StrikeGrid, StrikeNavMatrix) {
    let grid = grid();
    let nav = strike_nav_matrix::new(&grid, FULL_PREALLOCATED_TICKS, ctx);
    (grid, nav)
}

fun new_wide_nav(ctx: &mut TxContext): (StrikeGrid, StrikeNavMatrix) {
    let grid = wide_grid();
    let nav = strike_nav_matrix::new(&grid, PARTIAL_PREALLOCATED_TICKS, ctx);
    (grid, nav)
}

// === Constructor (new + grid validation) ===

#[test]
fun new_returns_empty_matrix() {
    let ctx = &mut tx_context::dummy();
    let (_grid, nav) = new_nav(ctx);
    nav.destroy();
}

#[test]
fun live_value_treats_missing_preallocated_pages_as_empty() {
    let ctx = &mut tx_context::dummy();
    let (grid, nav) = new_wide_nav(ctx);
    assert_eq!(nav.materialized_page_count_for_testing(), PARTIAL_PREALLOCATED_PAGE_COUNT);
    let curve = vector[
        pricing::new_curve_point_for_testing(WIDE_MIN_STRIKE, float!()),
        pricing::new_curve_point_for_testing(WIDE_MAX_STRIKE, float!()),
    ];
    assert_eq!(nav.live_value(&grid, &curve, WIDE_MIN_STRIKE, WIDE_MAX_STRIKE, float!()), 0);
    nav.destroy();
}

#[test]
fun insert_outside_preallocated_span_materializes_page() {
    let ctx = &mut tx_context::dummy();
    let (grid, mut nav) = new_wide_nav(ctx);
    assert_eq!(nav.materialized_page_count_for_testing(), PARTIAL_PREALLOCATED_PAGE_COUNT);
    nav.insert_range(&grid, OUTER_LOWER_STRIKE, OUTER_HIGHER_STRIKE, QTY_BIG, 0);
    assert_eq!(nav.materialized_page_count_for_testing(), PARTIAL_PREALLOCATED_PAGE_COUNT + 1);
    nav.remove_range(&grid, OUTER_LOWER_STRIKE, OUTER_HIGHER_STRIKE, QTY_BIG, 0);
    let curve = vector[
        pricing::new_curve_point_for_testing(WIDE_MIN_STRIKE, float!()),
        pricing::new_curve_point_for_testing(WIDE_MAX_STRIKE, float!()),
    ];
    assert_eq!(nav.live_value(&grid, &curve, WIDE_MIN_STRIKE, WIDE_MAX_STRIKE, float!()), 0);
    nav.destroy();
}

#[test, expected_failure(abort_code = strike_nav_matrix::EInvalidPreallocatedTicks)]
fun new_preallocated_ticks_above_grid_aborts() {
    let ctx = &mut tx_context::dummy();
    let grid = grid();
    destroy(strike_nav_matrix::new(&grid, TOO_MANY_PREALLOCATED_TICKS, ctx));
    abort 999
}

// === insert_range / remove_range abort cases ===

#[test, expected_failure(abort_code = strike_nav_matrix::EZeroQuantity)]
fun insert_zero_quantity_aborts() {
    let ctx = &mut tx_context::dummy();
    let (grid, mut nav) = new_nav(ctx);
    nav.insert_range(&grid, 120, 160, 0, 0);
    abort 999
}

#[test, expected_failure(abort_code = strike_grid::EInvalidStrikeGrid)]
fun insert_lower_equal_higher_aborts() {
    let ctx = &mut tx_context::dummy();
    let (grid, mut nav) = new_nav(ctx);
    nav.insert_range(&grid, 150, 150, QTY_ONE, 0);
    abort 999
}

#[test, expected_failure(abort_code = strike_grid::EInvalidStrikeGrid)]
fun insert_full_open_range_aborts() {
    // (neg_inf, pos_inf] would always-back the entire base quantity bucket.
    let ctx = &mut tx_context::dummy();
    let (grid, mut nav) = new_nav(ctx);
    nav.insert_range(&grid, constants::neg_inf!(), constants::pos_inf!(), QTY_ONE, 0);
    abort 999
}

#[test, expected_failure(abort_code = strike_grid::EInvalidStrikeGrid)]
fun insert_finite_above_grid_aborts() {
    let ctx = &mut tx_context::dummy();
    let (grid, mut nav) = new_nav(ctx);
    nav.insert_range(&grid, 150, MAX_STRIKE + TICK_SIZE, QTY_ONE, 0);
    abort 999
}

#[test, expected_failure(abort_code = strike_grid::EInvalidStrikeGrid)]
fun insert_unaligned_strike_aborts() {
    let ctx = &mut tx_context::dummy();
    let (grid, mut nav) = new_nav(ctx);
    nav.insert_range(&grid, 125, 160, QTY_ONE, 0);
    abort 999
}

#[test, expected_failure(abort_code = strike_nav_matrix::EInsufficientQuantity)]
fun remove_with_no_floor_underflows_floor_shares_aborts() {
    // Remove asks the matrix to subtract floor_shares = QTY_ONE, but base
    // floor_shares = 0. The shared decrement path aborts with EInsufficientQuantity.
    let ctx = &mut tx_context::dummy();
    let (grid, mut nav) = new_nav(ctx);
    nav.insert_range(&grid, 120, 160, QTY_ONE, 0);
    nav.remove_range(&grid, 120, 160, QTY_ONE, QTY_ONE);
    abort 999
}

#[test, expected_failure(abort_code = strike_nav_matrix::EInsufficientQuantity)]
fun remove_more_quantity_than_inserted_aborts() {
    let ctx = &mut tx_context::dummy();
    let (grid, mut nav) = new_nav(ctx);
    nav.insert_range(&grid, constants::neg_inf!(), 150, QTY_BIG, 0);
    nav.remove_range(&grid, constants::neg_inf!(), 150, QTY_BIG + 1, 0);
    abort 999
}

// === live_value ===
//
// live_value integrates the up-price curve against per-boundary weighted
// quantities; full exact-value coverage requires hand-rolled segment math
// against realistic 1e9-scaled strikes and is deferred to a later PR with
// scipy-anchored snapshots. Here we cover the contract-edge cases that don't
// depend on the integration math: empty curve, curve does not span the
// minted range, and the floor-exceeds-value invariant.

#[test, expected_failure(abort_code = strike_nav_matrix::EInvalidCurveRange)]
fun live_value_empty_curve_aborts() {
    let ctx = &mut tx_context::dummy();
    let (grid, nav) = new_nav(ctx);
    let curve: vector<pricing::CurvePoint> = vector[];
    let _ = nav.live_value(&grid, &curve, MIN_STRIKE, MAX_STRIKE, float!());
    abort 999
}

#[test, expected_failure(abort_code = strike_nav_matrix::EInvalidCurveRange)]
fun live_value_curve_does_not_span_minted_range_aborts() {
    // Curve covers [110, 140] but minted_max_strike = 180 — the curve must
    // span the entire minted range or live_value cannot evaluate the right tail.
    let ctx = &mut tx_context::dummy();
    let (grid, nav) = new_nav(ctx);
    let curve = vector[
        pricing::new_curve_point_for_testing(110, float!()),
        pricing::new_curve_point_for_testing(140, float!()),
    ];
    let _ = nav.live_value(&grid, &curve, 110, 180, float!());
    abort 999
}

#[test, expected_failure(abort_code = strike_nav_matrix::EFloorExceedsLiveValue)]
fun live_value_floor_above_value_aborts() {
    // Build floor_shares without any live quantity (insert (neg_inf, X] with
    // floor, then remove the quantity but leave floor behind). With base_qty=0
    // and floor_index=1.0, the floor amount exceeds the zero live value.
    let ctx = &mut tx_context::dummy();
    let (grid, mut nav) = new_nav(ctx);
    nav.insert_range(&grid, constants::neg_inf!(), 150, QTY_BIG, QTY_BIG);
    nav.remove_range(&grid, constants::neg_inf!(), 150, QTY_BIG, 0);
    let curve = vector[
        pricing::new_curve_point_for_testing(MIN_STRIKE, float!()),
        pricing::new_curve_point_for_testing(MAX_STRIKE, float!()),
    ];
    let _ = nav.live_value(&grid, &curve, MIN_STRIKE, MAX_STRIKE, float!());
    abort 999
}

// === destroy ===

#[test]
fun destroy_after_inserts_and_removes() {
    let ctx = &mut tx_context::dummy();
    let (grid, mut nav) = new_nav(ctx);
    nav.insert_range(&grid, 120, 160, QTY_BIG, 0);
    nav.insert_range(&grid, constants::neg_inf!(), 150, QTY_BIG, 0);
    nav.insert_range(&grid, 150, constants::pos_inf!(), QTY_BIG, 0);
    nav.remove_range(&grid, 120, 160, QTY_BIG, 0);
    nav.destroy();
}
