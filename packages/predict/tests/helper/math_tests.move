// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit tests for math functions.
/// Property tests verify identities, invariants, and error conditions.
/// Generated vector tests validate precision against scipy ground truth.
#[test_only]
module deepbook_predict::math_tests;

use deepbook_predict::{constants, generated_math as gs, i64, math, precision};
use std::unit_test::assert_eq;

const HALF: u64 = 500_000_000;

fun signed(magnitude: u64, is_negative: bool): i64::I64 {
    i64::from_parts(magnitude, is_negative)
}

fun exp(input: u64, is_negative: bool): u64 {
    let x = signed(input, is_negative);
    math::exp(&x)
}

fun cdf(input: u64, is_negative: bool): u64 {
    let x = signed(input, is_negative);
    math::normal_cdf(&x)
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

    abort 999
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

    abort 999
}

// ============================================================
// ln — property tests
// ============================================================

#[test]
fun ln_one_is_zero() {
    let result = math::ln(constants::float_scaling!());
    assert_eq!(i64::magnitude(&result), 0);
    assert_eq!(i64::is_negative(&result), false);
}

#[test, expected_failure(abort_code = math::EInputZero)]
fun ln_zero_aborts() {
    math::ln(0);

    abort 999
}

// ============================================================
// exp — property tests
// ============================================================

#[test]
fun exp_zero_is_one() {
    assert_eq!(exp(0, false), constants::float_scaling!());
}

#[test]
fun exp_large_negative_underflows_to_zero() {
    assert_eq!(exp(50 * constants::float_scaling!(), true), 0);
}

#[test, expected_failure(abort_code = math::EExpOverflow)]
fun exp_overflow_aborts() {
    exp(23_638_153_700, false);

    abort 999
}

#[test]
fun exp_at_max_input_succeeds() {
    let result = exp(23_638_153_699, false);
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
    let precisions: vector<u64> = vector[constants::float_scaling!(), 100_000_000, 1_000_000];
    precisions.do_ref!(|precision| {
        xs.do_ref!(|x| {
            let expected = deepbook::math::sqrt(*x, *precision);
            let actual = math::sqrt(*x, *precision);
            assert_eq!(actual, expected);
        });
    });
}

#[test, expected_failure(abort_code = math::EInvalidPrecision)]
fun sqrt_zero_precision_aborts() {
    math::sqrt(1, 0);
    abort 999
}

// ============================================================
// normal_cdf — property tests
// ============================================================

#[test]
fun cdf_zero_is_half() {
    assert_eq!(cdf(0, false), HALF);
    assert_eq!(cdf(0, true), HALF);
}

#[test]
fun cdf_symmetry() {
    // cdf(x) + cdf(-x) = constants::float_scaling!() for various x
    assert_eq!(cdf(0, false) + cdf(0, true), constants::float_scaling!());
    assert_eq!(cdf(HALF, false) + cdf(HALF, true), constants::float_scaling!());
    assert_eq!(
        cdf(constants::float_scaling!(), false) + cdf(constants::float_scaling!(), true),
        constants::float_scaling!(),
    );
    assert_eq!(
        cdf(2 * constants::float_scaling!(), false) + cdf(2 * constants::float_scaling!(), true),
        constants::float_scaling!(),
    );
    assert_eq!(
        cdf(3 * constants::float_scaling!(), false) + cdf(3 * constants::float_scaling!(), true),
        constants::float_scaling!(),
    );
    assert_eq!(
        cdf(8 * constants::float_scaling!(), false) + cdf(8 * constants::float_scaling!(), true),
        constants::float_scaling!(),
    );
}

#[test]
fun cdf_clamp_above_eight() {
    assert_eq!(cdf(9 * constants::float_scaling!(), false), constants::float_scaling!());
    assert_eq!(cdf(9 * constants::float_scaling!(), true), 0);
}

#[test]
fun cdf_monotonic() {
    let phi1 = cdf(constants::float_scaling!(), false);
    let phi2 = cdf(2 * constants::float_scaling!(), false);
    let phi3 = cdf(3 * constants::float_scaling!(), false);
    assert!(phi1 > HALF);
    assert!(phi1 < phi2);
    assert!(phi2 < phi3);
}

#[test]
fun cdf_positive_greater_than_half() {
    assert!(cdf(constants::float_scaling!(), false) > HALF);
}

#[test]
fun cdf_negative_less_than_half() {
    assert!(cdf(constants::float_scaling!(), true) < HALF);
}

// ============================================================
// Generated vector tests (scipy ground truth)
// ============================================================

#[test]
fun ln_matches_scipy() {
    gs::ln_cases().do_ref!(|c| {
        let result = math::ln(gs::ln_input(c));
        precision::assert_approx(i64::magnitude(&result), gs::ln_expected_mag(c));
        assert_eq!(i64::is_negative(&result), gs::ln_expected_neg(c));
    });
}

#[test]
fun exp_matches_scipy() {
    gs::exp_cases().do_ref!(|c| {
        let result = exp(gs::exp_input(c), gs::exp_is_negative(c));
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
        let result = cdf(gs::cdf_input(c), gs::cdf_is_negative(c));
        let expected = gs::cdf_expected(c);
        if (expected == 0) {
            assert_eq!(result, 0);
        } else {
            precision::assert_approx(result, expected);
        };
    });
}
