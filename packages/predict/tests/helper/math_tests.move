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
const TENTH: u64 = 100_000_000;

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
// ln — non-trivial inputs (exercise ln_series with nonzero z)
// ============================================================

#[test]
fun ln_one_point_five() {
    // ln(1.5) — between powers of 2, forces series approximation
    let (mag, neg) = math::ln(1_500_000_000);
    precision::assert_approx(mag, gs::LN_1_5!());
    assert_eq!(neg, false);
}

#[test]
fun ln_three() {
    let (mag, neg) = math::ln(3 * FLOAT);
    precision::assert_approx(mag, gs::LN_3_0!());
    assert_eq!(neg, false);
}

#[test]
fun ln_five() {
    let (mag, neg) = math::ln(5 * FLOAT);
    precision::assert_approx(mag, gs::LN_5_0!());
    assert_eq!(neg, false);
}

#[test]
fun ln_seven() {
    let (mag, neg) = math::ln(7 * FLOAT);
    precision::assert_approx(mag, gs::LN_7_0!());
    assert_eq!(neg, false);
}

#[test]
fun ln_ten() {
    let (mag, neg) = math::ln(10 * FLOAT);
    precision::assert_approx(mag, gs::LN_10_0!());
    assert_eq!(neg, false);
}

#[test]
fun ln_point_one() {
    // ln(0.1) = -ln(10), small fraction tests recursive inversion + series
    let (mag, neg) = math::ln(TENTH);
    precision::assert_approx(mag, gs::LN_0_1!());
    assert_eq!(neg, true);
}

#[test]
fun ln_point_three() {
    let (mag, neg) = math::ln(300_000_000);
    precision::assert_approx(mag, gs::LN_0_3!());
    assert_eq!(neg, true);
}

#[test]
fun ln_point_seven() {
    let (mag, neg) = math::ln(700_000_000);
    precision::assert_approx(mag, gs::LN_0_7!());
    assert_eq!(neg, true);
}

#[test]
fun ln_near_one_below() {
    // ln(0.999) — tiny z, tests series convergence near identity
    let (mag, neg) = math::ln(999_000_000);
    precision::assert_approx(mag, gs::LN_0_999!());
    assert_eq!(neg, true);
}

#[test]
fun ln_near_one_above() {
    // ln(1.001) — tiny z from the other side
    let (mag, neg) = math::ln(1_001_000_000);
    precision::assert_approx(mag, gs::LN_1_001!());
    assert_eq!(neg, false);
}

#[test]
fun ln_hundred() {
    // Large input — multiple normalize shifts + series
    let (mag, neg) = math::ln(100 * FLOAT);
    precision::assert_approx(mag, gs::LN_100_0!());
    assert_eq!(neg, false);
}

#[test]
fun ln_thousand() {
    let (mag, neg) = math::ln(1000 * FLOAT);
    precision::assert_approx(mag, gs::LN_1000_0!());
    assert_eq!(neg, false);
}

// ============================================================
// exp (scipy ground truth — assert_approx)
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
// exp — non-trivial inputs within operating range
// Operating range: max input = d2²/2 ≈ 13.5 (from quote bounds)
// ============================================================

#[test]
fun exp_tiny_positive() {
    precision::assert_approx(math::exp(1_000_000, false), gs::EXP_0_001!());
}

#[test]
fun exp_tiny_negative() {
    precision::assert_approx(math::exp(1_000_000, true), gs::EXP_NEG_0_001!());
}

#[test]
fun exp_small_positive() {
    precision::assert_approx(math::exp(10_000_000, false), gs::EXP_0_01!());
}

#[test]
fun exp_small_negative() {
    precision::assert_approx(math::exp(10_000_000, true), gs::EXP_NEG_0_01!());
}

#[test]
fun exp_point_one_positive() {
    precision::assert_approx(math::exp(TENTH, false), gs::EXP_0_1!());
}

#[test]
fun exp_point_one_negative() {
    precision::assert_approx(math::exp(TENTH, true), gs::EXP_NEG_0_1!());
}

#[test]
fun exp_point_three_positive() {
    precision::assert_approx(math::exp(300_000_000, false), gs::EXP_0_3!());
}

#[test]
fun exp_point_three_negative() {
    precision::assert_approx(math::exp(300_000_000, true), gs::EXP_NEG_0_3!());
}

#[test]
fun exp_half_positive() {
    precision::assert_approx(math::exp(HALF, false), gs::EXP_0_5!());
}

#[test]
fun exp_half_negative() {
    precision::assert_approx(math::exp(HALF, true), gs::EXP_NEG_0_5!());
}

#[test]
fun exp_one_point_five_positive() {
    precision::assert_approx(math::exp(1_500_000_000, false), gs::EXP_1_5!());
}

#[test]
fun exp_one_point_five_negative() {
    precision::assert_approx(math::exp(1_500_000_000, true), gs::EXP_NEG_1_5!());
}

#[test]
fun exp_two_point_five_positive() {
    precision::assert_approx(math::exp(2_500_000_000, false), gs::EXP_2_5!());
}

#[test]
fun exp_two_point_five_negative() {
    precision::assert_approx(math::exp(2_500_000_000, true), gs::EXP_NEG_2_5!());
}

#[test]
fun exp_six_point_eight_positive() {
    // ~50% of max operating range input
    precision::assert_approx(math::exp(6_800_000_000, false), gs::EXP_6_8!());
}

#[test]
fun exp_six_point_eight_negative() {
    precision::assert_approx(math::exp(6_800_000_000, true), gs::EXP_NEG_6_8!());
}

#[test]
fun exp_twelve_point_two_positive() {
    // ~90% of max operating range input
    precision::assert_approx(math::exp(12_200_000_000, false), gs::EXP_12_2!());
}

#[test]
fun exp_twelve_point_two_negative() {
    precision::assert_approx(math::exp(12_200_000_000, true), gs::EXP_NEG_12_2!());
}

// ============================================================
// normal_cdf (scipy ground truth — assert_approx)
// ============================================================

#[test]
fun cdf_zero_positive() {
    // Φ(0) = 0.5 exactly
    precision::assert_approx(math::normal_cdf(0, false), gs::PHI_0!());
}

#[test]
fun cdf_zero_negative() {
    precision::assert_approx(math::normal_cdf(0, true), gs::PHI_NEG_0!());
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
    precision::assert_approx(pos, gs::PHI_8_0!());
    precision::assert_approx(neg, gs::PHI_NEG_8_0!());
    assert_eq!(pos + neg, FLOAT);
}

#[test]
fun cdf_monotonic() {
    let phi1 = math::normal_cdf(FLOAT, false);
    let phi2 = math::normal_cdf(2 * FLOAT, false);
    let phi3 = math::normal_cdf(3 * FLOAT, false);
    precision::assert_approx(phi1, gs::PHI_1_0!());
    precision::assert_approx(phi2, gs::PHI_2_0!());
    precision::assert_approx(phi3, gs::PHI_3_0!());
    assert_eq!(phi1 < phi2, true);
    assert_eq!(phi2 < phi3, true);
}

#[test]
fun cdf_neg_two() {
    precision::assert_approx(math::normal_cdf(2 * FLOAT, true), gs::PHI_NEG_2_0!());
}

#[test]
fun cdf_greater_than_half_for_positive() {
    precision::assert_approx(math::normal_cdf(TENTH, false), gs::PHI_0_1!());
    precision::assert_approx(math::normal_cdf(FLOAT, false), gs::PHI_1_0!());
    precision::assert_approx(math::normal_cdf(3 * FLOAT, false), gs::PHI_3_0!());
}

#[test]
fun cdf_less_than_half_for_negative() {
    precision::assert_approx(math::normal_cdf(TENTH, true), gs::PHI_NEG_0_1!());
    precision::assert_approx(math::normal_cdf(FLOAT, true), gs::PHI_NEG_1_0!());
    precision::assert_approx(math::normal_cdf(3 * FLOAT, true), gs::PHI_NEG_3_0!());
}

// ============================================================
// normal_cdf — dense coverage within operating range
// Operating range: |d2| <= 5.2 (from 0.1c—99.9c quote bounds)
// ============================================================

#[test]
fun cdf_point_zero_one() {
    precision::assert_approx(math::normal_cdf(10_000_000, false), gs::PHI_0_01!());
}

#[test]
fun cdf_point_zero_five() {
    precision::assert_approx(math::normal_cdf(50_000_000, false), gs::PHI_0_05!());
}

#[test]
fun cdf_point_seven_five() {
    precision::assert_approx(math::normal_cdf(750_000_000, false), gs::PHI_0_75!());
    precision::assert_approx(math::normal_cdf(750_000_000, true), gs::PHI_NEG_0_75!());
    assert_eq!(math::normal_cdf(750_000_000, false) + math::normal_cdf(750_000_000, true), FLOAT);
}

#[test]
fun cdf_one_point_five() {
    precision::assert_approx(math::normal_cdf(1_500_000_000, false), gs::PHI_1_5!());
    precision::assert_approx(math::normal_cdf(1_500_000_000, true), gs::PHI_NEG_1_5!());
}

#[test]
fun cdf_two_point_five() {
    precision::assert_approx(math::normal_cdf(2_500_000_000, false), gs::PHI_2_5!());
    precision::assert_approx(math::normal_cdf(2_500_000_000, true), gs::PHI_NEG_2_5!());
}

#[test]
fun cdf_at_quote_boundary() {
    // |d2| = 5.2 — at the edge of the quotable range (0.1c price)
    precision::assert_approx(math::normal_cdf(5_200_000_000, false), gs::PHI_5_2!());
}
