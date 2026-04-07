// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit tests for strike-matrix live interpolation, settled payout, and page-spanning aggregation.
#[test_only]
module deepbook_predict::strike_matrix_tests;

use deepbook_predict::{
    constants::float_scaling as float,
    oracle_config::{Self as oracle_config, CurvePoint},
    strike_matrix
};
use std::unit_test::{assert_eq, destroy};

fun test_curve(k0: u64, k1: u64, k2: u64): vector<CurvePoint> {
    vector[
        oracle_config::new_curve_point(k0, float!(), 0),
        oracle_config::new_curve_point(k1, 500_000_000, 500_000_000),
        oracle_config::new_curve_point(k2, 0, float!()),
    ]
}

#[test]
fun evaluate_settled_exact_strike_boundary_dn_owns_boundary() {
    let scale = float!();
    let min_strike = 50 * scale;
    let tick_size = 10 * scale;
    let boundary_strike = 70 * scale;
    let below_strike = 60 * scale;
    let above_strike = 80 * scale;
    let settlement = boundary_strike;
    let qty_up_below = 3 * scale;
    let qty_up_boundary = 7 * scale;
    let qty_dn_boundary = 5 * scale;
    let qty_dn_above = 2 * scale;
    // settlement == 70:
    //   UP at 60 wins  -> 3
    //   UP at 70 loses -> 0
    //   DN at 70 wins  -> 5
    //   DN at 80 wins  -> 2
    let expected = 10 * scale;

    let ctx = &mut tx_context::dummy();
    let mut matrix = strike_matrix::new(ctx, tick_size, min_strike, above_strike);
    matrix.insert(below_strike, qty_up_below, true);
    matrix.insert(boundary_strike, qty_up_boundary, true);
    matrix.insert(boundary_strike, qty_dn_boundary, false);
    matrix.insert(above_strike, qty_dn_above, false);

    assert_eq!(matrix.evaluate_settled(settlement), expected);

    destroy(matrix);
}

#[test]
fun evaluate_settled_off_grid_between_two_strikes_splits_correctly() {
    let scale = float!();
    let min_strike = 50 * scale;
    let tick_size = 10 * scale;
    let low_strike = 60 * scale;
    let high_strike = 70 * scale;
    let settlement = 65 * scale;
    let qty_up_low = 4 * scale;
    let qty_dn_low = 2 * scale;
    let qty_up_high = 3 * scale;
    let qty_dn_high = 6 * scale;
    // settlement == 65:
    //   UP at 60 wins  -> 4
    //   DN at 60 loses -> 0
    //   UP at 70 loses -> 0
    //   DN at 70 wins  -> 6
    let expected = 10 * scale;

    let ctx = &mut tx_context::dummy();
    let mut matrix = strike_matrix::new(ctx, tick_size, min_strike, high_strike);
    matrix.insert(low_strike, qty_up_low, true);
    matrix.insert(low_strike, qty_dn_low, false);
    matrix.insert(high_strike, qty_up_high, true);
    matrix.insert(high_strike, qty_dn_high, false);

    assert_eq!(matrix.evaluate_settled(settlement), expected);

    destroy(matrix);
}

#[test]
fun evaluate_settled_multi_page_sparse_book() {
    let scale = float!();
    let min_strike = 100 * scale;
    let tick_size = scale;
    let page_slots = 512 * scale;
    let first_strike = min_strike;
    let last_strike_page_zero = min_strike + page_slots - tick_size;
    let first_strike_page_one = min_strike + page_slots;
    let next_strike_page_one = first_strike_page_one + tick_size;
    let qty_up_first = 2 * scale;
    let qty_up_last_page_zero = 5 * scale;
    let qty_dn_first_page_one = 7 * scale;
    let qty_dn_next_page_one = 11 * scale;
    // settlement == first strike on page one:
    //   UP below settlement: 2 + 5 = 7
    //   DN at/above settlement: 7 + 11 = 18
    let expected = 25 * scale;

    let ctx = &mut tx_context::dummy();
    let mut matrix = strike_matrix::new(ctx, tick_size, min_strike, next_strike_page_one);
    matrix.insert(first_strike, qty_up_first, true);
    matrix.insert(last_strike_page_zero, qty_up_last_page_zero, true);
    matrix.insert(first_strike_page_one, qty_dn_first_page_one, false);
    matrix.insert(next_strike_page_one, qty_dn_next_page_one, false);

    assert_eq!(matrix.evaluate_settled(first_strike_page_one), expected);

    destroy(matrix);
}

#[test]
fun evaluate_live_same_page_manual_curve() {
    let scale = float!();
    let min_strike = 100 * scale;
    let tick_size = 10 * scale;
    let strike0 = 100 * scale;
    let strike1 = 110 * scale;
    let strike2 = 120 * scale;
    let qty_up_at_first = 10 * scale;
    let qty_up_at_mid = 8 * scale;
    let qty_dn_at_mid = 6 * scale;
    let qty_dn_at_last = 4 * scale;
    // Manual curve:
    //   strike 100 -> UP 1.0, DN 0.0
    //   strike 110 -> UP 0.5, DN 0.5
    //   strike 120 -> UP 0.0, DN 1.0
    // Payout contributions:
    //   UP@100 -> 10 * 1.0 = 10
    //   UP@110 -> 8 * 0.5 = 4
    //   DN@110 -> 6 * 0.5 = 3
    //   DN@120 -> 4 * 1.0 = 4
    let expected = 21 * scale;

    let ctx = &mut tx_context::dummy();
    let mut matrix = strike_matrix::new(ctx, tick_size, min_strike, strike2);
    let curve = test_curve(strike0, strike1, strike2);
    matrix.insert(strike0, qty_up_at_first, true);
    matrix.insert(strike1, qty_up_at_mid, true);
    matrix.insert(strike1, qty_dn_at_mid, false);
    matrix.insert(strike2, qty_dn_at_last, false);

    assert_eq!(matrix.evaluate(&curve), expected);

    destroy(matrix);
}

#[test, expected_failure(abort_code = strike_matrix::ENonMonotoneCurve)]
fun evaluate_live_non_monotone_curve_aborts() {
    let scale = float!();
    let min_strike = 100 * scale;
    let tick_size = 10 * scale;
    let strike0 = 100 * scale;
    let strike1 = 110 * scale;
    let strike2 = 120 * scale;
    let qty_up_at_mid = 8 * scale;
    let bad_curve = vector[
        oracle_config::new_curve_point(strike0, 400_000_000, 600_000_000),
        oracle_config::new_curve_point(strike1, 500_000_000, 500_000_000),
        oracle_config::new_curve_point(strike2, 0, float!()),
    ];

    let ctx = &mut tx_context::dummy();
    let mut matrix = strike_matrix::new(ctx, tick_size, min_strike, strike2);
    matrix.insert(strike1, qty_up_at_mid, true);

    matrix.evaluate(&bad_curve);

    abort 999
}

#[test, expected_failure(abort_code = strike_matrix::EInvalidCurveRange)]
fun evaluate_live_curve_must_cover_minted_range() {
    let scale = float!();
    let min_strike = 100 * scale;
    let tick_size = 10 * scale;
    let strike0 = 100 * scale;
    let strike1 = 110 * scale;
    let strike2 = 120 * scale;
    let qty_up_at_first = 10 * scale;
    let qty_dn_at_last = 4 * scale;
    let narrow_curve = vector[
        oracle_config::new_curve_point(strike1, 500_000_000, 500_000_000),
        oracle_config::new_curve_point(strike2, 0, float!()),
    ];

    let ctx = &mut tx_context::dummy();
    let mut matrix = strike_matrix::new(ctx, tick_size, min_strike, strike2);
    matrix.insert(strike0, qty_up_at_first, true);
    matrix.insert(strike2, qty_dn_at_last, false);

    matrix.evaluate(&narrow_curve);

    abort 999
}

#[test]
fun evaluate_live_multi_page_manual_curve_and_remove_to_zero() {
    let scale = float!();
    let min_strike = 100 * scale;
    let tick_size = scale;
    let page_slots = 512 * scale;
    let strike_left = min_strike + page_slots - tick_size;
    let strike_right = min_strike + page_slots;
    let strike_far = strike_right + tick_size;
    let qty_up_left = 2 * scale;
    let qty_up_right = 8 * scale;
    let qty_dn_right = 6 * scale;
    let qty_dn_far = 4 * scale;
    // Same manual curve shape as the single-page test, but split across pages:
    //   UP@left  -> 2 * 1.0 = 2
    //   UP@right -> 8 * 0.5 = 4
    //   DN@right -> 6 * 0.5 = 3
    //   DN@far   -> 4 * 1.0 = 4
    let expected_live = 13 * scale;

    let ctx = &mut tx_context::dummy();
    let mut matrix = strike_matrix::new(ctx, tick_size, min_strike, strike_far);
    let curve = test_curve(strike_left, strike_right, strike_far);
    matrix.insert(strike_left, qty_up_left, true);
    matrix.insert(strike_right, qty_up_right, true);
    matrix.insert(strike_right, qty_dn_right, false);
    matrix.insert(strike_far, qty_dn_far, false);

    assert_eq!(matrix.evaluate(&curve), expected_live);
    assert_eq!(matrix.max_payout(), 20 * scale);

    matrix.remove(strike_left, qty_up_left, true);
    matrix.remove(strike_right, qty_up_right, true);
    matrix.remove(strike_right, qty_dn_right, false);
    matrix.remove(strike_far, qty_dn_far, false);

    assert_eq!(matrix.evaluate(&curve), 0);
    assert_eq!(matrix.evaluate_settled(strike_right), 0);
    assert_eq!(matrix.max_payout(), 0);
    assert_eq!(matrix.has_live_positions(), false);

    destroy(matrix);
}
