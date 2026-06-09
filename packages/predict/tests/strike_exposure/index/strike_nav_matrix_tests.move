// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit tests for the `strike_nav_matrix` range-accounting guards. The matrix is
/// a pure data structure over a `StrikeGrid`, so it is constructed directly with
/// production grid geometry (`strike_grid::new_centered`) and exercised through
/// its package API.
#[test_only]
module deepbook_predict::strike_nav_matrix_tests;

use deepbook_predict::{pricing::CurvePoint, strike_grid, strike_nav_matrix};
use sui::test_utils::destroy;

const BTC_SPOT: u64 = 100_000_000_000_000; // $100,000 in 1e9 price scaling
const TICK_SIZE: u64 = 1_000_000_000; // $1.00; spot spans 100,000 ticks

const QTY: u64 = 10_000; // one position lot
const NO_FLOOR: u64 = 0;

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
