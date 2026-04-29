// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::strike_matrix_tests;

use deepbook_predict::{constants, oracle_config, strike_matrix};
use std::unit_test::assert_eq;
use sui::clock;

const MIN_STRIKE: u64 = 60_000;
const MID_STRIKE: u64 = 70_000;
const MAX_STRIKE: u64 = 80_000;
const TICK_SIZE: u64 = 10_000;
const QTY: u64 = 1_000_000;
const DOUBLE_QTY: u64 = 2_000_000;
const UP_25C: u64 = 250_000_000;
const UP_30C: u64 = 300_000_000;
const UP_40C: u64 = 400_000_000;
const LOWER_SETTLEMENT: u64 = 60_000;
const IN_RANGE_SETTLEMENT: u64 = 70_000;
const ABOVE_RANGE_SETTLEMENT: u64 = 70_001;
const BETWEEN_STRIKES_SETTLEMENT: u64 = 65_000;
const LOWER_SENTINEL_MTM: u64 = 700_000; // 1 contract * (1.0 - 30c).
const UPPER_SENTINEL_MTM: u64 = 400_000; // 1 contract * 40c.
const FINITE_RANGE_MTM: u64 = 150_000; // 1 contract * (40c - 25c).

fun setup(): (strike_matrix::StrikeMatrix, clock::Clock) {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    let matrix = strike_matrix::new(ctx, TICK_SIZE, MIN_STRIKE, MAX_STRIKE, &clock);
    (matrix, clock)
}

#[test]
fun lower_sentinel_range_is_active_until_upper_boundary() {
    let (mut matrix, clock) = setup();
    matrix.insert_range(constants::neg_inf!(), MID_STRIKE, QTY);

    assert_eq!(matrix.evaluate_settled(LOWER_SETTLEMENT), QTY);
    assert_eq!(matrix.evaluate_settled(IN_RANGE_SETTLEMENT), QTY);
    assert_eq!(matrix.evaluate_settled(ABOVE_RANGE_SETTLEMENT), 0);
    assert_eq!(matrix.max_payout(), QTY);

    let curve = vector[oracle_config::new_curve_point(MID_STRIKE, UP_30C)];
    assert_eq!(matrix.evaluate(&curve), LOWER_SENTINEL_MTM);

    let (remaining_quantity, remaining_liability) = matrix.into_settled_totals(IN_RANGE_SETTLEMENT);
    assert_eq!(remaining_quantity, QTY);
    assert_eq!(remaining_liability, QTY);
    clock.destroy_for_testing();
}

#[test]
fun upper_sentinel_range_is_active_above_lower_boundary() {
    let (mut matrix, clock) = setup();
    matrix.insert_range(MIN_STRIKE, constants::pos_inf!(), QTY);

    assert_eq!(matrix.evaluate_settled(LOWER_SETTLEMENT), 0);
    assert_eq!(matrix.evaluate_settled(BETWEEN_STRIKES_SETTLEMENT), QTY);
    assert_eq!(matrix.max_payout(), QTY);

    let curve = vector[oracle_config::new_curve_point(MIN_STRIKE, UP_40C)];
    assert_eq!(matrix.evaluate(&curve), UPPER_SENTINEL_MTM);

    let (remaining_quantity, remaining_liability) = matrix.into_settled_totals(
        BETWEEN_STRIKES_SETTLEMENT,
    );
    assert_eq!(remaining_quantity, QTY);
    assert_eq!(remaining_liability, QTY);
    clock.destroy_for_testing();
}

#[test]
fun finite_range_uses_start_and_end_boundaries() {
    let (mut matrix, clock) = setup();
    matrix.insert_range(MIN_STRIKE, MID_STRIKE, QTY);

    assert_eq!(matrix.evaluate_settled(LOWER_SETTLEMENT), 0);
    assert_eq!(matrix.evaluate_settled(IN_RANGE_SETTLEMENT), QTY);
    assert_eq!(matrix.evaluate_settled(ABOVE_RANGE_SETTLEMENT), 0);
    assert_eq!(matrix.max_payout(), QTY);

    let curve = vector[
        oracle_config::new_curve_point(MIN_STRIKE, UP_40C),
        oracle_config::new_curve_point(MID_STRIKE, UP_25C),
    ];
    assert_eq!(matrix.evaluate(&curve), FINITE_RANGE_MTM);

    let (remaining_quantity, remaining_liability) = matrix.into_settled_totals(IN_RANGE_SETTLEMENT);
    assert_eq!(remaining_quantity, QTY);
    assert_eq!(remaining_liability, QTY);
    clock.destroy_for_testing();
}

#[test]
fun mixed_sentinel_ranges_compact_to_interval_quantity() {
    let (mut matrix, clock) = setup();
    matrix.insert_range(constants::neg_inf!(), MID_STRIKE, QTY);
    matrix.insert_range(MIN_STRIKE, constants::pos_inf!(), DOUBLE_QTY);

    let (remaining_quantity, remaining_liability) = matrix.into_settled_totals(
        BETWEEN_STRIKES_SETTLEMENT,
    );

    assert_eq!(remaining_quantity, QTY + DOUBLE_QTY);
    assert_eq!(remaining_liability, QTY + DOUBLE_QTY);
    clock.destroy_for_testing();
}
