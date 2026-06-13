// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Validated finite strike grid for one Predict expiry.
///
/// The grid owns geometry validation, raw boundary checks, and strike boundary
/// indexing. It does not know about orders, pricing, exposure mutation, or cash.
module deepbook_predict::strike_grid;

use deepbook_predict::constants;

const EInvalidTickSize: u64 = 0;
const EInvalidStrikeGrid: u64 = 1;
const EOracleTickSizeTooSmallForSpot: u64 = 2;
const EInvalidOracleSpot: u64 = 3;
const EOracleTickSizeTooLargeForSpot: u64 = 4;

/// Validated strike grid for one expiry.
public struct StrikeGrid has copy, drop, store {
    min_strike: u64,
    tick_size: u64,
    max_strike: u64,
    total_strikes: u64,
}

/// Create a fixed-width oracle grid centered on tick-floored spot.
public(package) fun new_centered(spot: u64, tick_size: u64): StrikeGrid {
    assert!(spot > 0, EInvalidOracleSpot);
    assert_tick_size(tick_size);
    let ticks = constants::oracle_strike_grid_ticks!();
    assert!(ticks > 0, EInvalidStrikeGrid);
    let spot_ticks = spot / tick_size;
    assert!(spot_ticks > ticks / 2, EOracleTickSizeTooLargeForSpot);
    assert!(spot_ticks <= ticks, EOracleTickSizeTooSmallForSpot);

    let center_ticks = ticks / 2;
    let min_strike = (spot_ticks - center_ticks) * tick_size;
    assert!(min_strike > 0, EInvalidStrikeGrid);
    assert!(min_strike % tick_size == 0, EInvalidStrikeGrid);
    let max_strike = min_strike + tick_size * ticks;

    StrikeGrid {
        min_strike,
        tick_size,
        max_strike,
        total_strikes: ticks + 1,
    }
}

fun assert_tick_size(tick_size: u64) {
    assert!(tick_size > 0, EInvalidTickSize);
    assert!(tick_size % constants::oracle_tick_size_unit!() == 0, EInvalidTickSize);
}

public(package) fun min_strike(grid: &StrikeGrid): u64 {
    grid.min_strike
}

public(package) fun tick_size(grid: &StrikeGrid): u64 {
    grid.tick_size
}

public(package) fun max_strike(grid: &StrikeGrid): u64 {
    grid.max_strike
}

/// Assert that `(lower, higher]` is a valid non-empty range on this grid.
public(package) fun assert_range_boundaries(grid: &StrikeGrid, lower: u64, higher: u64) {
    assert!(lower < higher, EInvalidStrikeGrid);
    assert!(
        !(lower == constants::neg_inf!() && higher == constants::pos_inf!()),
        EInvalidStrikeGrid,
    );
    if (lower != constants::neg_inf!()) grid.assert_finite_boundary(lower);
    if (higher != constants::pos_inf!()) grid.assert_finite_boundary(higher);
}

/// Return the boundary index for a raw strike boundary.
public(package) fun boundary_index(grid: &StrikeGrid, boundary: u64): u64 {
    if (boundary == constants::neg_inf!()) {
        0
    } else if (boundary == constants::pos_inf!()) {
        grid.total_strikes + 1
    } else {
        grid.finite_strike_index(boundary) + 1
    }
}

/// Return the raw strike boundary at `boundary_index`.
public(package) fun boundary_at_index(grid: &StrikeGrid, boundary_index: u64): u64 {
    if (boundary_index == 0) {
        constants::neg_inf!()
    } else if (boundary_index == grid.total_strikes + 1) {
        constants::pos_inf!()
    } else {
        grid.finite_strike_at_index(boundary_index - 1)
    }
}

/// Assert that `strike` is finite, in-bounds, and grid-aligned.
fun assert_finite_boundary(grid: &StrikeGrid, strike: u64) {
    assert!(strike >= grid.min_strike && strike <= grid.max_strike, EInvalidStrikeGrid);
    assert!((strike - grid.min_strike) % grid.tick_size == 0, EInvalidStrikeGrid);
}

/// Return the grid index for a finite strike.
fun finite_strike_index(grid: &StrikeGrid, strike: u64): u64 {
    grid.assert_finite_boundary(strike);
    (strike - grid.min_strike) / grid.tick_size
}

/// Return the finite strike at `index` on this grid.
fun finite_strike_at_index(grid: &StrikeGrid, index: u64): u64 {
    assert!(index < grid.total_strikes, EInvalidStrikeGrid);
    grid.min_strike + index * grid.tick_size
}
