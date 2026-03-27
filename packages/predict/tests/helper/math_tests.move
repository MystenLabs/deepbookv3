// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::math_tests;

use deepbook_predict::{generated_math as gs, math, precision};
use std::unit_test::assert_eq;

const FLOAT: u64 = 1_000_000_000;
const HALF: u64 = 500_000_000;
const QUARTER: u64 = 250_000_000;
const EIGHTH: u64 = 125_000_000;

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
    // (-5) - (-3) = -5 + 3 = -2
    let (mag, neg) = math::sub_signed_u64(5, true, 3, true);
    assert_eq!(mag, 2);
    assert_eq!(neg, true);
}

#[test]
fun sub_neg_minus_neg_larger_b() {
    // (-3) - (-5) = -3 + 5 = 2
    let (mag, neg) = math::sub_signed_u64(3, true, 5, true);
    assert_eq!(mag, 2);
    assert_eq!(neg, false);
}

#[test]
fun sub_pos_minus_neg() {
    // 5 - (-3) = 5 + 3 = 8
    let (mag, neg) = math::sub_signed_u64(5, false, 3, true);
    assert_eq!(mag, 8);
    assert_eq!(neg, false);
}

#[test]
fun sub_neg_minus_pos() {
    // (-5) - 3 = -(5+3) = -8
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
        10 * FLOAT,
        false,
        3 * FLOAT,
        false,
    );
    assert_eq!(mag, 7 * FLOAT);
    assert_eq!(neg, false);
}

#[test]
fun sub_neg_equal_values_normalizes_to_positive_zero() {
    // (-5) - (-5) = 0, should normalize to +0
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
    // 5 + (-3) = 2
    let (mag, neg) = math::add_signed_u64(5, false, 3, true);
    assert_eq!(mag, 2);
    assert_eq!(neg, false);
}

#[test]
fun add_pos_plus_neg_larger_neg() {
    // 3 + (-5) = -2
    let (mag, neg) = math::add_signed_u64(3, false, 5, true);
    assert_eq!(mag, 2);
    assert_eq!(neg, true);
}

#[test]
fun add_neg_plus_pos_larger_pos() {
    // (-3) + 5 = 2
    let (mag, neg) = math::add_signed_u64(3, true, 5, false);
    assert_eq!(mag, 2);
    assert_eq!(neg, false);
}

#[test]
fun add_neg_plus_pos_larger_neg() {
    // (-5) + 3 = -2
    let (mag, neg) = math::add_signed_u64(5, true, 3, false);
    assert_eq!(mag, 2);
    assert_eq!(neg, true);
}

#[test]
fun add_opposite_sign_equal_magnitude() {
    // 5 + (-5) = 0
    let (mag, neg) = math::add_signed_u64(5, false, 5, true);
    assert_eq!(mag, 0);
    assert_eq!(neg, false);
}

#[test]
fun add_zero_normalization() {
    // (-0) + 0: a_neg != b_neg -> different signs.
    // a >= b (0 >= 0) -> diff = 0 -> (0, false)
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
    // (-0) + (-0) = -0, but should normalize to +0
    let (mag, neg) = math::add_signed_u64(0, true, 0, true);
    assert_eq!(mag, 0);
    assert_eq!(neg, false);
}

#[test]
fun add_large_same_sign() {
    let (mag, neg) = math::add_signed_u64(
        5 * FLOAT,
        false,
        3 * FLOAT,
        false,
    );
    assert_eq!(mag, 8 * FLOAT);
    assert_eq!(neg, false);
}

// ============================================================
// mul_signed_u64
// ============================================================

#[test]
fun mul_pos_times_pos() {
    // 2.0 * 3.0 = 6.0 (in FLOAT_SCALING)
    let (mag, neg) = math::mul_signed_u64(2 * FLOAT, false, 3 * FLOAT, false);
    assert_eq!(mag, 6 * FLOAT);
    assert_eq!(neg, false);
}

#[test]
fun mul_pos_times_neg() {
    let (mag, neg) = math::mul_signed_u64(2 * FLOAT, false, 3 * FLOAT, true);
    assert_eq!(mag, 6 * FLOAT);
    assert_eq!(neg, true);
}

#[test]
fun mul_neg_times_neg() {
    let (mag, neg) = math::mul_signed_u64(2 * FLOAT, true, 3 * FLOAT, true);
    assert_eq!(mag, 6 * FLOAT);
    assert_eq!(neg, false);
}

#[test]
fun mul_anything_times_zero() {
    let (mag, neg) = math::mul_signed_u64(5 * FLOAT, false, 0, false);
    assert_eq!(mag, 0);
    assert_eq!(neg, false);
}

#[test]
fun mul_neg_times_zero() {
    // Zero result normalizes sign to false regardless of input signs
    let (mag, neg) = math::mul_signed_u64(5 * FLOAT, true, 0, true);
    assert_eq!(mag, 0);
    assert_eq!(neg, false);
}

#[test]
fun mul_fractional() {
    // 0.5 * 0.5 = 0.25
    let (mag, neg) = math::mul_signed_u64(HALF, false, HALF, false);
    assert_eq!(mag, QUARTER);
    assert_eq!(neg, false);
}

#[test]
fun mul_one_times_value() {
    // 1.0 * x = x
    let (mag, neg) = math::mul_signed_u64(FLOAT, false, 42 * FLOAT, true);
    assert_eq!(mag, 42 * FLOAT);
    assert_eq!(neg, true);
}

#[test]
fun mul_neg_times_pos() {
    let (mag, neg) = math::mul_signed_u64(3 * FLOAT, true, 4 * FLOAT, false);
    assert_eq!(mag, 12 * FLOAT);
    assert_eq!(neg, true);
}

// ============================================================
// ln (scipy ground truth — assert_approx)
// ============================================================

#[test]
fun ln_one() {
    // ln(1.0) = 0 exactly
    let (mag, neg) = math::ln(FLOAT);
    assert_eq!(mag, 0);
    assert_eq!(neg, false);
}

#[test]
fun ln_two() {
    let (mag, neg) = math::ln(2 * FLOAT);
    precision::assert_approx(mag, gs::LN2!());
    assert_eq!(neg, false);
}

#[test]
fun ln_half() {
    // ln(0.5) = -ln(2)
    let (mag, neg) = math::ln(HALF);
    precision::assert_approx(mag, gs::LN2!());
    assert_eq!(neg, true);
}

#[test]
fun ln_four() {
    let (mag, neg) = math::ln(4 * FLOAT);
    precision::assert_approx(mag, gs::LN4!());
    assert_eq!(neg, false);
}

#[test]
fun ln_quarter() {
    // ln(0.25) = -ln(4)
    let (mag, neg) = math::ln(QUARTER);
    precision::assert_approx(mag, gs::LN4!());
    assert_eq!(neg, true);
}

#[test]
fun ln_eight() {
    let (mag, neg) = math::ln(8 * FLOAT);
    precision::assert_approx(mag, gs::LN8!());
    assert_eq!(neg, false);
}

#[test]
fun ln_sixteen() {
    let (mag, neg) = math::ln(16 * FLOAT);
    precision::assert_approx(mag, gs::LN16!());
    assert_eq!(neg, false);
}

#[test, expected_failure(abort_code = math::EInputZero)]
fun ln_zero_aborts() {
    math::ln(0);

    abort
}

#[test]
fun ln_smallest_input() {
    // ln(1/1e9) = -ln(1e9)
    let (mag, neg) = math::ln(1);
    precision::assert_approx(mag, gs::LN_1E9!());
    assert_eq!(neg, true);
}

// ============================================================
// exp (property tests — mathematical identities)
// ============================================================

#[test]
fun exp_zero() {
    // e^0 = 1.0 exactly
    assert_eq!(math::exp(0, false), FLOAT);
}

#[test]
fun exp_ln2_positive() {
    // e^(ln2) = 2.0
    precision::assert_approx(math::exp(gs::LN2!(), false), 2 * FLOAT);
}

#[test]
fun exp_ln2_negative() {
    // e^(-ln2) = 0.5
    precision::assert_approx(math::exp(gs::LN2!(), true), HALF);
}

#[test]
fun exp_2ln2_positive() {
    // e^(2*ln2) = 4.0
    precision::assert_approx(math::exp(gs::LN4!(), false), 4 * FLOAT);
}

#[test]
fun exp_2ln2_negative() {
    // e^(-2*ln2) = 0.25
    precision::assert_approx(math::exp(gs::LN4!(), true), QUARTER);
}

#[test]
fun exp_3ln2_positive() {
    // e^(3*ln2) = 8.0
    precision::assert_approx(math::exp(gs::LN8!(), false), 8 * FLOAT);
}

#[test]
fun exp_3ln2_negative() {
    // e^(-3*ln2) = 0.125
    precision::assert_approx(math::exp(gs::LN8!(), true), EIGHTH);
}

#[test]
fun exp_large_negative_underflows_to_zero() {
    // e^(-50) should underflow to 0 via the cascading right-shift path
    assert_eq!(math::exp(50 * FLOAT, true), 0);
}

#[test]
fun exp_one_positive() {
    // e^1 = E
    precision::assert_approx(math::exp(FLOAT, false), gs::E!());
}

#[test]
fun exp_one_negative() {
    // e^(-1) = 1/E
    precision::assert_approx(math::exp(FLOAT, true), gs::E_INV!());
}

// ============================================================
// normal_cdf (property tests — mathematical invariants)
// ============================================================

#[test]
fun cdf_zero_is_half() {
    assert_eq!(math::normal_cdf(0, false), HALF);
    assert_eq!(math::normal_cdf(0, true), HALF);
}

#[test]
fun cdf_zero_sums_to_one() {
    // Contract invariant: cdf(x) + cdf(-x) = FLOAT
    let pos = math::normal_cdf(0, false);
    let neg = math::normal_cdf(0, true);
    assert_eq!(pos + neg, FLOAT);
}

#[test]
fun cdf_large_positive() {
    // Phi(x) = FLOAT for x > 8*FLOAT (exact boundary)
    assert_eq!(math::normal_cdf(9 * FLOAT, false), FLOAT);
}

#[test]
fun cdf_large_negative() {
    // Phi(-x) = 0 for x > 8*FLOAT (exact boundary)
    assert_eq!(math::normal_cdf(9 * FLOAT, true), 0);
}

#[test]
fun cdf_symmetry_one() {
    // Contract invariant: cdf(x) + cdf(-x) = FLOAT
    let pos = math::normal_cdf(FLOAT, false);
    let neg = math::normal_cdf(FLOAT, true);
    assert_eq!(pos + neg, FLOAT);
}

#[test]
fun cdf_symmetry_two() {
    let pos = math::normal_cdf(2 * FLOAT, false);
    let neg = math::normal_cdf(2 * FLOAT, true);
    assert_eq!(pos + neg, FLOAT);
}

#[test]
fun cdf_symmetry_half() {
    let pos = math::normal_cdf(HALF, false);
    let neg = math::normal_cdf(HALF, true);
    assert_eq!(pos + neg, FLOAT);
}

#[test]
fun cdf_symmetry_three() {
    let pos = math::normal_cdf(3 * FLOAT, false);
    let neg = math::normal_cdf(3 * FLOAT, true);
    assert_eq!(pos + neg, FLOAT);
}

#[test]
fun cdf_at_boundary_eight() {
    // x = 8*FLOAT exactly goes through polynomial (not the > 8 early return)
    let pos = math::normal_cdf(8 * FLOAT, false);
    let neg = math::normal_cdf(8 * FLOAT, true);
    assert_eq!(pos + neg, FLOAT);
}

#[test]
fun cdf_monotonic() {
    let phi1 = math::normal_cdf(FLOAT, false);
    let phi2 = math::normal_cdf(2 * FLOAT, false);
    let phi3 = math::normal_cdf(3 * FLOAT, false);
    assert!(phi1 > HALF);
    assert!(phi1 < phi2);
    assert!(phi2 < phi3);
}

#[test]
fun cdf_positive_greater_than_half() {
    assert!(math::normal_cdf(FLOAT, false) > HALF);
    assert!(math::normal_cdf(3 * FLOAT, false) > HALF);
}

#[test]
fun cdf_negative_less_than_half() {
    assert!(math::normal_cdf(FLOAT, true) < HALF);
    assert!(math::normal_cdf(3 * FLOAT, true) < HALF);
}

// ============================================================
// Randomized vector tests (scipy ground truth)
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
    let f: u64 = 1_000_000_000;
    gs::cdf_cases().do_ref!(|c| {
        let result = math::normal_cdf(gs::cdf_input(c), gs::cdf_is_negative(c));
        let expected = gs::cdf_expected(c);
        if (expected < 1_000) {
            // Deep tail: contract clamps at sqrt(32), allow small absolute error
            assert!(result < 1_000);
        } else if (expected > f - 1_000) {
            // Near FLOAT: symmetric to deep tail
            assert!(result > f - 1_000);
        } else {
            precision::assert_approx(result, expected);
        };
    });
}

#[test, expected_failure(abort_code = math::EExpOverflow)]
fun exp_overflow_aborts() {
    // Any input above MAX_EXP_INPUT should abort
    math::exp(23_638_153_700, false);

    abort
}

#[test]
fun exp_at_max_input_succeeds() {
    // Exactly at the boundary — should not abort
    let result = math::exp(23_638_153_699, false);
    assert!(result > 0);
}

#[test]
fun exp_overflow_cases_all_above_max() {
    // Verify all generated overflow inputs are above the boundary
    gs::exp_overflow_cases().do!(|x| {
        assert!(x > 23_638_153_699);
    });
}
