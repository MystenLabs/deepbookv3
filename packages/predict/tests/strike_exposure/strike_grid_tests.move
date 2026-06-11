// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::strike_grid_tests;

use deepbook_predict::{constants, strike_grid};
use std::unit_test::assert_eq;

const BTC_SPOT: u64 = 100_000_000_000_000; // $100,000 in 1e9 price scaling
const VALID_BTC_TICK_SIZE: u64 = 1_000_000_000; // $1.00; spot spans 100,000 ticks
const TOO_SMALL_BTC_TICK_SIZE: u64 = 10_000; // $0.00001; spot spans far above the max tick budget
const TOO_LARGE_BTC_TICK_SIZE: u64 = 3_000_000_000; // $3.00; spot spans fewer than grid_ticks/2 ticks

const CENTERED_MIN_STRIKE: u64 = 50_000_000_000_000; // $50,000 in 1e9 price scaling
const CENTERED_MAX_STRIKE: u64 = 150_000_000_000_000; // $150,000 in 1e9 price scaling

#[test]
fun new_centered_accepts_boundary_tick_size() {
    let grid = strike_grid::new_centered(BTC_SPOT, VALID_BTC_TICK_SIZE);
    let expected_min = BTC_SPOT / 2;
    let expected_max = BTC_SPOT + BTC_SPOT / 2;

    assert_eq!(grid.min_strike(), expected_min);
    assert_eq!(grid.tick_size(), VALID_BTC_TICK_SIZE);
    assert_eq!(grid.max_strike(), expected_max);
    assert_eq!(grid.total_strikes(), constants::oracle_strike_grid_ticks!() + 1);
}

#[test, expected_failure(abort_code = strike_grid::EInvalidTickSize)]
fun new_centered_aborts_with_zero_tick_size() {
    strike_grid::new_centered(BTC_SPOT, 0);
    abort 999
}

#[test, expected_failure(abort_code = strike_grid::EInvalidTickSize)]
fun new_centered_aborts_with_unaligned_tick_size() {
    // One above a multiple of constants::oracle_tick_size_unit!() (10_000).
    strike_grid::new_centered(BTC_SPOT, VALID_BTC_TICK_SIZE + 1);
    abort 999
}

#[test, expected_failure(abort_code = strike_grid::EOracleTickSizeTooSmallForSpot)]
fun new_centered_aborts_when_tick_size_too_small_for_spot() {
    strike_grid::new_centered(BTC_SPOT, TOO_SMALL_BTC_TICK_SIZE);
    abort 999
}

#[test, expected_failure(abort_code = strike_grid::EOracleTickSizeTooLargeForSpot)]
fun new_centered_aborts_when_tick_size_too_large_for_spot() {
    strike_grid::new_centered(BTC_SPOT, TOO_LARGE_BTC_TICK_SIZE);
    abort 999
}

#[test, expected_failure(abort_code = strike_grid::EInvalidOracleSpot)]
fun new_centered_aborts_without_spot() {
    strike_grid::new_centered(0, VALID_BTC_TICK_SIZE);
    abort 999
}

#[test]
fun boundary_indexes_round_trip_raw_boundaries() {
    let grid = strike_grid::new_centered(BTC_SPOT, VALID_BTC_TICK_SIZE);
    let max_boundary_index = grid.total_strikes() + 1;

    assert_eq!(grid.boundary_index(constants::neg_inf!()), 0);
    assert_eq!(grid.boundary_index(CENTERED_MIN_STRIKE), 1);
    assert_eq!(grid.boundary_index(CENTERED_MAX_STRIKE), grid.total_strikes());
    assert_eq!(grid.boundary_index(constants::pos_inf!()), max_boundary_index);

    assert_eq!(grid.boundary_at_index(0), constants::neg_inf!());
    assert_eq!(grid.boundary_at_index(1), CENTERED_MIN_STRIKE);
    assert_eq!(grid.boundary_at_index(grid.total_strikes()), CENTERED_MAX_STRIKE);
    assert_eq!(grid.boundary_at_index(max_boundary_index), constants::pos_inf!());
}
