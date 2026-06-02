// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Shared strike-grid boundary for expiry-local exposure indexes.
///
/// `StrikeExposure` owns the grid. Leaf indexes borrow it when they need to
/// validate finite boundaries, convert strikes to dense coordinates, or apply
/// range updates.
module deepbook_predict::strike_grid;

use deepbook_predict::constants;

const EInvalidTickSize: u64 = 0;
const EInvalidStrikeGrid: u64 = 1;

/// Canonical finite oracle strike grid for one expiry exposure book.
public struct StrikeGrid has copy, drop, store {
    min_strike: u64,
    tick_size: u64,
    max_strike: u64,
    total_strikes: u64,
}

public(package) fun new(min_strike: u64, tick_size: u64): StrikeGrid {
    assert!(tick_size > 0, EInvalidTickSize);
    assert!(tick_size % constants::oracle_tick_size_unit!() == 0, EInvalidTickSize);
    assert!(min_strike > 0, EInvalidStrikeGrid);
    assert!(min_strike % tick_size == 0, EInvalidStrikeGrid);
    let ticks = constants::oracle_strike_grid_ticks!();
    assert!(ticks > 0, EInvalidStrikeGrid);
    StrikeGrid {
        min_strike,
        tick_size,
        max_strike: min_strike + tick_size * ticks,
        total_strikes: ticks + 1,
    }
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

public(package) fun total_strikes(grid: &StrikeGrid): u64 {
    grid.total_strikes
}

public(package) fun assert_range_boundaries(grid: &StrikeGrid, lower: u64, higher: u64) {
    assert!(lower < higher, EInvalidStrikeGrid);
    assert!(
        !(lower == constants::neg_inf!() && higher == constants::pos_inf!()),
        EInvalidStrikeGrid,
    );
    if (lower != constants::neg_inf!()) grid.assert_finite_boundary(lower);
    if (higher != constants::pos_inf!()) grid.assert_finite_boundary(higher);
}

public(package) fun assert_finite_boundary(grid: &StrikeGrid, strike: u64) {
    let _ = grid.finite_strike_index(strike);
}

public(package) fun finite_strike_index(grid: &StrikeGrid, strike: u64): u64 {
    assert!(strike >= grid.min_strike && strike <= grid.max_strike, EInvalidStrikeGrid);
    assert!((strike - grid.min_strike) % grid.tick_size == 0, EInvalidStrikeGrid);
    (strike - grid.min_strike) / grid.tick_size
}
