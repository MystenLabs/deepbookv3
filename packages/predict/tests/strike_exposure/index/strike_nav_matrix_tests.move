// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit tests for the `strike_nav_matrix` range-accounting guards. The matrix is
/// a pure data structure over a `StrikeGrid`, so it is constructed directly with
/// production grid geometry (`strike_grid::new_centered`) and exercised through
/// its package API.
#[test_only]
module deepbook_predict::strike_nav_matrix_tests;

use deepbook_predict::{pricing::{Self, CurvePoint}, strike_grid, strike_nav_matrix};
use std::unit_test::{assert_eq, destroy};

const BTC_SPOT: u64 = 100_000_000_000_000; // $100,000 in 1e9 price scaling
const TICK_SIZE: u64 = 1_000_000_000; // $1.00; spot spans 100,000 ticks

const QTY: u64 = 10_000; // one position lot
const NO_FLOOR: u64 = 0;

/// The largest production-mintable order: u32::MAX lots x 10_000 lot size
/// (`order::assert_valid_quantity`), $42.95M DUSDC.
const MAX_ORDER_QTY: u64 = 42_949_672_950_000;
/// $600,000 spot with a $6 tick (the fixed 100k-tick grid requires
/// spot / tick in (50_000, 100_000]): the centered grid tops out at $900,000,
/// where one max-size order's strike-weighted quantity
/// (qty * strike / 1e9 ~ 3.87e19) alone exceeds u64::MAX.
const HIGH_SPOT: u64 = 600_000_000_000_000;
const HIGH_TICK_SIZE: u64 = 6_000_000_000;
/// Hand-built sloped curve: UP = 0.6 at the range's lower boundary, 0.4 at the
/// higher, so a (lower, higher] range is worth exactly 0.2x its quantity.
const UP_AT_LOWER: u64 = 600_000_000;
const UP_AT_HIGHER: u64 = 400_000_000;
/// 3 max orders: floor(3Q * 0.6) - floor(3Q * 0.4)
/// = 77_309_411_310_000 - 51_539_607_540_000 (both products exact).
const THREE_MAX_RANGE_VALUE: u64 = 25_769_803_770_000;
/// 1 max order: floor(Q * 0.6) - floor(Q * 0.4)
/// = 25_769_803_770_000 - 17_179_869_180_000 (both products exact).
const SINGLE_MAX_RANGE_VALUE: u64 = 8_589_934_590_000;

#[test, expected_failure(abort_code = strike_nav_matrix::EInvalidPreallocatedTicks)]
fun new_with_preallocated_ticks_above_tick_count_aborts() {
    let ctx = &mut tx_context::dummy();
    let grid = strike_grid::new_centered(BTC_SPOT, TICK_SIZE);
    // The grid has total_strikes() boundaries and total_strikes() - 1 ticks;
    // asking for one more tick than exists is rejected.
    let nav = strike_nav_matrix::new(&grid, grid.total_strikes(), ctx);
    destroy(nav);

    abort 999
}

#[test, expected_failure(abort_code = strike_nav_matrix::EZeroQuantity)]
fun insert_range_with_zero_quantity_aborts() {
    let ctx = &mut tx_context::dummy();
    let grid = strike_grid::new_centered(BTC_SPOT, TICK_SIZE);
    let mut nav = strike_nav_matrix::new(&grid, 0, ctx);
    let lower = grid.min_strike() + TICK_SIZE;
    nav.insert_range(&grid, lower, lower + TICK_SIZE, 0, NO_FLOOR);
    abort 999
}

#[test, expected_failure(abort_code = strike_nav_matrix::EInsufficientQuantity)]
fun remove_range_above_inserted_quantity_aborts() {
    let ctx = &mut tx_context::dummy();
    let grid = strike_grid::new_centered(BTC_SPOT, TICK_SIZE);
    let mut nav = strike_nav_matrix::new(&grid, 0, ctx);
    let lower = grid.min_strike() + TICK_SIZE;
    let higher = lower + TICK_SIZE;
    nav.insert_range(&grid, lower, higher, QTY, NO_FLOOR);
    nav.remove_range(&grid, lower, higher, 2 * QTY, NO_FLOOR);
    abort 999
}

#[test, expected_failure(abort_code = strike_nav_matrix::EInsufficientQuantity)]
fun remove_more_floor_shares_than_inserted_aborts() {
    let ctx = &mut tx_context::dummy();
    let grid = strike_grid::new_centered(BTC_SPOT, TICK_SIZE);
    let mut nav = strike_nav_matrix::new(&grid, 0, ctx);
    let lower = grid.min_strike() + TICK_SIZE;
    let higher = lower + TICK_SIZE;
    nav.insert_range(&grid, lower, higher, QTY, QTY / 2);
    nav.remove_range(&grid, lower, higher, QTY, QTY);
    abort 999
}

/// Aggregate open interest at one high strike must not be capped by the
/// accumulator width: three max-size orders at the top of the $100k grid push
/// the strike-weighted quantity sum to ~1.93e19, above u64::MAX. The inserts,
/// the exact segment valuation, and the full drain must all succeed.
#[test]
fun three_max_orders_at_grid_top_value_and_drain_exactly() {
    let ctx = &mut tx_context::dummy();
    let grid = strike_grid::new_centered(BTC_SPOT, TICK_SIZE);
    let mut nav = strike_nav_matrix::new(&grid, 0, ctx);
    let lower = grid.max_strike() - 2 * TICK_SIZE;
    let higher = lower + TICK_SIZE;
    let curve = vector[
        pricing::curve_point_for_testing(lower, UP_AT_LOWER),
        pricing::curve_point_for_testing(higher, UP_AT_HIGHER),
    ];

    nav.insert_range(&grid, lower, higher, MAX_ORDER_QTY, NO_FLOOR);
    nav.insert_range(&grid, lower, higher, MAX_ORDER_QTY, NO_FLOOR);
    nav.insert_range(&grid, lower, higher, MAX_ORDER_QTY, NO_FLOOR);

    let (value, floor_value) = nav.live_value(&grid, &curve, lower, higher, 0);
    assert_eq!(value, THREE_MAX_RANGE_VALUE);
    assert_eq!(floor_value, 0);

    nav.remove_range(&grid, lower, higher, MAX_ORDER_QTY, NO_FLOOR);
    nav.remove_range(&grid, lower, higher, MAX_ORDER_QTY, NO_FLOOR);
    nav.remove_range(&grid, lower, higher, MAX_ORDER_QTY, NO_FLOOR);

    let (drained_value, drained_floor) = nav.live_value(&grid, &curve, lower, higher, 0);
    assert_eq!(drained_value, 0);
    assert_eq!(drained_floor, 0);
    destroy(nav);
}

/// On a high-priced grid ($900k top strike) even a SINGLE max-size order's
/// strike weight (qty * strike / 1e9 ~ 3.87e19) exceeds u64::MAX, so the
/// weighting itself must be computed wide, not just the aggregate sum.
#[test]
fun single_max_order_at_high_strike_values_exactly() {
    let ctx = &mut tx_context::dummy();
    let grid = strike_grid::new_centered(HIGH_SPOT, HIGH_TICK_SIZE);
    let mut nav = strike_nav_matrix::new(&grid, 0, ctx);
    let lower = grid.max_strike() - 2 * HIGH_TICK_SIZE;
    let higher = lower + HIGH_TICK_SIZE;
    let curve = vector[
        pricing::curve_point_for_testing(lower, UP_AT_LOWER),
        pricing::curve_point_for_testing(higher, UP_AT_HIGHER),
    ];

    nav.insert_range(&grid, lower, higher, MAX_ORDER_QTY, NO_FLOOR);

    let (value, floor_value) = nav.live_value(&grid, &curve, lower, higher, 0);
    assert_eq!(value, SINGLE_MAX_RANGE_VALUE);
    assert_eq!(floor_value, 0);

    nav.remove_range(&grid, lower, higher, MAX_ORDER_QTY, NO_FLOOR);
    destroy(nav);
}

#[test, expected_failure(abort_code = strike_nav_matrix::EInvalidCurveRange)]
fun live_value_with_empty_curve_aborts() {
    let ctx = &mut tx_context::dummy();
    let grid = strike_grid::new_centered(BTC_SPOT, TICK_SIZE);
    let nav = strike_nav_matrix::new(&grid, 0, ctx);
    let curve: vector<CurvePoint> = vector[];
    let lower = grid.min_strike() + TICK_SIZE;
    nav.live_value(&grid, &curve, lower, lower + TICK_SIZE, 0);
    abort 999
}
