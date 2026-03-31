// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit tests for math functions.
/// Property tests verify identities, invariants, and error conditions.
/// Generated vector tests validate precision against scipy ground truth.
#[test_only]
module deepbook_predict::math_tests;

use deepbook_predict::{constants, generated_math as gs, math, precision};
use std::unit_test::assert_eq;

const HALF: u64 = 500_000_000;
const QUARTER: u64 = 250_000_000;

// ============================================================
// sub_signed_u64
// ============================================================

#[test]
fun sub_pos_minus_smaller_pos() {
    let (mag, neg) = math::sub_signed_u64(5, false, 3, false);
    assert_eq!(mag, 2);
    assert_eq!(neg, false);
}
#[test]
fun sub_smaller_pos_minus_larger_pos() {
    let (mag, neg) = math::sub_signed_u64(3, false, 5, false);
    assert_eq!(mag, 2);
    assert_eq!(neg, true);
}
#[test]
fun sub_neg_minus_neg_larger_a() {
    let (mag, neg) = math::sub_signed_u64(5, true, 3, true);
    assert_eq!(mag, 2);
    assert_eq!(neg, true);
}

#[test]
fun sub_neg_minus_neg_larger_b() {
    let (mag, neg) = math::sub_signed_u64(3, true, 5, true);
    assert_eq!(mag, 2);
    assert_eq!(neg, false);
}

#[test]
fun sub_pos_minus_neg() {
    let (mag, neg) = math::sub_signed_u64(5, false, 3, true);
    assert_eq!(mag, 8);
    assert_eq!(neg, false);
}

#[test]
fun sub_neg_minus_pos() {
    let (mag, neg) = math::sub_signed_u64(5, true, 3, false);
    assert_eq!(mag, 8);
    assert_eq!(neg, true);
}

#[test]
fun sub_equal_values() {
    let (mag, neg) = math::sub_signed_u64(5, false, 5, false);
    assert_eq!(mag, 0);
    assert_eq!(neg, false);
}

#[test]
fun sub_zero_minus_zero() {
    let (mag, neg) = math::sub_signed_u64(0, false, 0, false);
    assert_eq!(mag, 0);
    assert_eq!(neg, false);
}

#[test]
fun sub_large_values() {
    let (mag, neg) = math::sub_signed_u64(
        10 * constants::float_scaling!(),
        false,
        3 * constants::float_scaling!(),
        false,
    );
    assert_eq!(mag, 7 * constants::float_scaling!());
    assert_eq!(neg, false);
}

#[test]
fun sub_neg_equal_values_normalizes_to_positive_zero() {
    let (mag, neg) = math::sub_signed_u64(5, true, 5, true);
    assert_eq!(mag, 0);
    assert_eq!(neg, false);
}

// ============================================================
// add_signed_u64
// ============================================================

#[test]
fun add_pos_plus_pos() {
    let (mag, neg) = math::add_signed_u64(5, false, 3, false);
    assert_eq!(mag, 8);
    assert_eq!(neg, false);
}

#[test]
fun add_neg_plus_neg() {
    let (mag, neg) = math::add_signed_u64(5, true, 3, true);
    assert_eq!(mag, 8);
    assert_eq!(neg, true);
}

#[test]
fun add_pos_plus_neg_larger_pos() {
    let (mag, neg) = math::add_signed_u64(5, false, 3, true);
    assert_eq!(mag, 2);
    assert_eq!(neg, false);
}

#[test]
fun add_pos_plus_neg_larger_neg() {
    let (mag, neg) = math::add_signed_u64(3, false, 5, true);
    assert_eq!(mag, 2);
    assert_eq!(neg, true);
}

#[test]
fun add_neg_plus_pos_larger_pos() {
    let (mag, neg) = math::add_signed_u64(3, true, 5, false);
    assert_eq!(mag, 2);
    assert_eq!(neg, false);
}

#[test]
fun add_neg_plus_pos_larger_neg() {
    let (mag, neg) = math::add_signed_u64(5, true, 3, false);
    assert_eq!(mag, 2);
    assert_eq!(neg, true);
}

#[test]
fun add_opposite_sign_equal_magnitude() {
    let (mag, neg) = math::add_signed_u64(5, false, 5, true);
    assert_eq!(mag, 0);
    assert_eq!(neg, false);
}

#[test]
fun add_zero_normalization() {
    let (mag, neg) = math::add_signed_u64(0, true, 0, false);
    assert_eq!(mag, 0);
    assert_eq!(neg, false);
}

#[test]
fun add_zero_plus_zero() {
    let (mag, neg) = math::add_signed_u64(0, false, 0, false);
    assert_eq!(mag, 0);
    assert_eq!(neg, false);
}

#[test]
fun add_neg_zero_plus_neg_zero() {
    let (mag, neg) = math::add_signed_u64(0, true, 0, true);
    assert_eq!(mag, 0);
    assert_eq!(neg, false);
}

#[test]
fun add_large_same_sign() {
    let (mag, neg) = math::add_signed_u64(
        5 * constants::float_scaling!(),
        false,
        3 * constants::float_scaling!(),
        false,
    );
    assert_eq!(mag, 8 * constants::float_scaling!());
    assert_eq!(neg, false);
}

// ============================================================
// mul_signed_u64
// ============================================================

#[test]
fun mul_pos_times_pos() {
    let (mag, neg) = math::mul_signed_u64(
        2 * constants::float_scaling!(),
        false,
        3 * constants::float_scaling!(),
        false,
    );
    assert_eq!(mag, 6 * constants::float_scaling!());
    assert_eq!(neg, false);
}

#[test]
fun mul_pos_times_neg() {
    let (mag, neg) = math::mul_signed_u64(
        2 * constants::float_scaling!(),
        false,
        3 * constants::float_scaling!(),
        true,
    );
    assert_eq!(mag, 6 * constants::float_scaling!());
    assert_eq!(neg, true);
}

#[test]
fun mul_neg_times_neg() {
    let (mag, neg) = math::mul_signed_u64(
        2 * constants::float_scaling!(),
        true,
        3 * constants::float_scaling!(),
        true,
    );
    assert_eq!(mag, 6 * constants::float_scaling!());
    assert_eq!(neg, false);
}

#[test]
fun mul_anything_times_zero() {
    let (mag, neg) = math::mul_signed_u64(5 * constants::float_scaling!(), false, 0, false);
    assert_eq!(mag, 0);
    assert_eq!(neg, false);
}

#[test]
fun mul_neg_times_zero() {
    let (mag, neg) = math::mul_signed_u64(5 * constants::float_scaling!(), true, 0, true);
    assert_eq!(mag, 0);
    assert_eq!(neg, false);
}

#[test]
fun mul_fractional() {
    let (mag, neg) = math::mul_signed_u64(HALF, false, HALF, false);
    assert_eq!(mag, QUARTER);
    assert_eq!(neg, false);
}

#[test]
fun mul_one_times_value() {
    let (mag, neg) = math::mul_signed_u64(
        constants::float_scaling!(),
        false,
        42 * constants::float_scaling!(),
        true,
    );
    assert_eq!(mag, 42 * constants::float_scaling!());
    assert_eq!(neg, true);
}

#[test]
fun mul_neg_times_pos() {
    let (mag, neg) = math::mul_signed_u64(
        3 * constants::float_scaling!(),
        true,
        4 * constants::float_scaling!(),
        false,
    );
    assert_eq!(mag, 12 * constants::float_scaling!());
    assert_eq!(neg, true);
}

// ============================================================
// mul_div_round_down
// ============================================================

#[test]
fun mul_div_round_down_exact() {
    // 10 * 20 / 5 = 40
    assert_eq!(math::mul_div_round_down(10, 20, 5), 40);
}

#[test]
fun mul_div_round_down_truncates() {
    // 10 * 3 / 7 = 30/7 = 4.28... → 4
    assert_eq!(math::mul_div_round_down(10, 3, 7), 4);
}

#[test]
fun mul_div_round_down_zero_numerator() {
    assert_eq!(math::mul_div_round_down(0, 100, 7), 0);
}

#[test, expected_failure]
fun mul_div_round_down_zero_denominator_aborts() {
    math::mul_div_round_down(10, 20, 0);

    abort
}

// ============================================================
// mul_div_round_up
// ============================================================

#[test]
fun mul_div_round_up_exact() {
    // 10 * 20 / 5 = 40 (no rounding needed)
    assert_eq!(math::mul_div_round_up(10, 20, 5), 40);
}

#[test]
fun mul_div_round_up_rounds() {
    // 10 * 3 / 7 = 30/7 = 4.28... → 5
    assert_eq!(math::mul_div_round_up(10, 3, 7), 5);
}

#[test]
fun mul_div_round_up_zero_numerator() {
    assert_eq!(math::mul_div_round_up(0, 100, 7), 0);
}

#[test, expected_failure]
fun mul_div_round_up_zero_denominator_aborts() {
    math::mul_div_round_up(10, 20, 0);

    abort
}

// ============================================================
// ln — property tests
// ============================================================

#[test]
fun ln_one_is_zero() {
    let (mag, neg) = math::ln(constants::float_scaling!());
    assert_eq!(mag, 0);
    assert_eq!(neg, false);
}

#[test, expected_failure(abort_code = math::EInputZero)]
fun ln_zero_aborts() {
    math::ln(0);

    abort
}

// ============================================================
// exp — property tests
// ============================================================

#[test]
fun exp_zero_is_one() {
    assert_eq!(math::exp(0, false), constants::float_scaling!());
}

#[test]
fun exp_large_negative_underflows_to_zero() {
    assert_eq!(math::exp(50 * constants::float_scaling!(), true), 0);
}

#[test, expected_failure(abort_code = math::EExpOverflow)]
fun exp_overflow_aborts() {
    math::exp(23_638_153_700, false);

    abort
}

#[test]
fun exp_at_max_input_succeeds() {
    let result = math::exp(23_638_153_699, false);
    assert!(result > 0);
}

#[test]
fun sqrt_matches_deepbook_math() {
    let xs: vector<u64> = vector[
        0,
        1,
        2,
        10,
        100,
        10_000,
        100_000_000,
        500_000_000,
        constants::float_scaling!(),
        2 * constants::float_scaling!(),
        4 * constants::float_scaling!(),
        9 * constants::float_scaling!(),
        10 * constants::float_scaling!(),
        100 * constants::float_scaling!(),
        1_000 * constants::float_scaling!(),
        18_446_744_073_709_551_615,
    ];
    let precisions: vector<u64> = vector[
        constants::float_scaling!(),
        100_000_000,
        1_000_000,
    ];
    precisions.do_ref!(|precision| {
        xs.do_ref!(|x| {
            let expected = deepbook::math::sqrt(*x, *precision);
            let actual = math::sqrt(*x, *precision);
            assert_eq!(actual, expected);
        });
    });
}

// ============================================================
// normal_cdf — property tests
// ============================================================

#[test]
fun cdf_zero_is_half() {
    assert_eq!(math::normal_cdf(0, false), HALF);
    assert_eq!(math::normal_cdf(0, true), HALF);
}

#[test]
fun cdf_symmetry() {
    // cdf(x) + cdf(-x) = constants::float_scaling!() for various x
    assert_eq!(math::normal_cdf(0, false) + math::normal_cdf(0, true), constants::float_scaling!());
    assert_eq!(
        math::normal_cdf(HALF, false) + math::normal_cdf(HALF, true),
        constants::float_scaling!(),
    );
    assert_eq!(
        math::normal_cdf(constants::float_scaling!(), false) + math::normal_cdf(constants::float_scaling!(), true),
        constants::float_scaling!(),
    );
    assert_eq!(
        math::normal_cdf(2 * constants::float_scaling!(), false) + math::normal_cdf(2 * constants::float_scaling!(), true),
        constants::float_scaling!(),
    );
    assert_eq!(
        math::normal_cdf(3 * constants::float_scaling!(), false) + math::normal_cdf(3 * constants::float_scaling!(), true),
        constants::float_scaling!(),
    );
    assert_eq!(
        math::normal_cdf(8 * constants::float_scaling!(), false) + math::normal_cdf(8 * constants::float_scaling!(), true),
        constants::float_scaling!(),
    );
}

#[test]
fun cdf_clamp_above_eight() {
    assert_eq!(
        math::normal_cdf(9 * constants::float_scaling!(), false),
        constants::float_scaling!(),
    );
    assert_eq!(math::normal_cdf(9 * constants::float_scaling!(), true), 0);
}

#[test]
fun cdf_monotonic() {
    let phi1 = math::normal_cdf(constants::float_scaling!(), false);
    let phi2 = math::normal_cdf(2 * constants::float_scaling!(), false);
    let phi3 = math::normal_cdf(3 * constants::float_scaling!(), false);
    assert!(phi1 > HALF);
    assert!(phi1 < phi2);
    assert!(phi2 < phi3);
}

#[test]
fun cdf_positive_greater_than_half() {
    assert!(math::normal_cdf(constants::float_scaling!(), false) > HALF);
}

#[test]
fun cdf_negative_less_than_half() {
    assert!(math::normal_cdf(constants::float_scaling!(), true) < HALF);
}

// ============================================================
// Generated vector tests (scipy ground truth)
// ============================================================

#[test]
fun ln_matches_scipy() {
    gs::ln_cases().do_ref!(|c| {
        let (mag, neg) = math::ln(gs::ln_input(c));
        precision::assert_approx(mag, gs::ln_expected_mag(c));
        assert_eq!(neg, gs::ln_expected_neg(c));
    });
}

#[test]
fun exp_matches_scipy() {
    gs::exp_cases().do_ref!(|c| {
        let result = math::exp(gs::exp_input(c), gs::exp_is_negative(c));
        let expected = gs::exp_expected(c);
        if (expected == 0) {
            assert_eq!(result, 0);
        } else {
            precision::assert_approx(result, expected);
        };
    });
}

#[test]
fun cdf_matches_scipy() {
    gs::cdf_cases().do_ref!(|c| {
        let result = math::normal_cdf(gs::cdf_input(c), gs::cdf_is_negative(c));
        let expected = gs::cdf_expected(c);
        if (expected == 0) {
            assert_eq!(result, 0);
        } else {
            precision::assert_approx(result, expected);
        };
    });
}
