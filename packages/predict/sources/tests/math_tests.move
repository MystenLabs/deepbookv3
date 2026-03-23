// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::math_tests;

use deepbook_predict::math;
use std::unit_test::assert_eq;

const FLOAT: u64 = 1_000_000_000;

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
    // (-0) + 0: same sign branch (both false after b_neg flip? No.)
    // a=0, a_neg=true, b=0, b_neg=false. a_neg != b_neg -> different signs.
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
    let (mag, neg) = math::mul_signed_u64(500_000_000, false, 500_000_000, false);
    assert_eq!(mag, 250_000_000);
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
// ln
// ============================================================

#[test]
fun ln_one() {
    // ln(1.0) = 0
    let (mag, neg) = math::ln(FLOAT);
    assert_eq!(mag, 0);
    assert_eq!(neg, false);
}

#[test]
fun ln_two() {
    // ln(2.0): normalize(2e9) -> y=1e9, n=1. log_ratio(1e9)=0.
    // result = 1 * 693_147_181 = 693_147_181
    let (mag, neg) = math::ln(2 * FLOAT);
    assert_eq!(mag, 693_147_181);
    assert_eq!(neg, false);
}

#[test]
fun ln_half() {
    // ln(0.5) = -ln(2): inv = div(1e9, 5e8) = 2e9. ln(2e9) = 693_147_181.
    let (mag, neg) = math::ln(500_000_000);
    assert_eq!(mag, 693_147_181);
    assert_eq!(neg, true);
}

#[test]
fun ln_four() {
    // ln(4.0) = 2*ln(2): normalize(4e9) -> y=1e9, n=2. log_ratio=0.
    // result = 2 * 693_147_181 = 1_386_294_362
    let (mag, neg) = math::ln(4 * FLOAT);
    assert_eq!(mag, 1_386_294_362);
    assert_eq!(neg, false);
}

#[test]
fun ln_quarter() {
    // ln(0.25) = -ln(4): inv = div(1e9, 2.5e8) = 4e9. ln(4e9) = 1_386_294_362.
    let (mag, neg) = math::ln(250_000_000);
    assert_eq!(mag, 1_386_294_362);
    assert_eq!(neg, true);
}

#[test]
fun ln_eight() {
    // ln(8.0) = 3*ln(2): normalize(8e9) -> y=1e9, n=3.
    // result = 3 * 693_147_181 = 2_079_441_543
    let (mag, neg) = math::ln(8 * FLOAT);
    assert_eq!(mag, 2_079_441_543);
    assert_eq!(neg, false);
}

#[test]
fun ln_sixteen() {
    // ln(16.0) = 4*ln(2): normalize(16e9) -> y=1e9, n=4.
    // result = 4 * 693_147_181 = 2_772_588_724
    let (mag, neg) = math::ln(16 * FLOAT);
    assert_eq!(mag, 2_772_588_724);
    assert_eq!(neg, false);
}

#[test, expected_failure(abort_code = math::EInputZero)]
fun ln_zero_aborts() {
    math::ln(0);

    abort
}

#[test]
fun ln_smallest_input() {
    // ln(1/1e9) = -ln(1e9). Should be large and negative.
    let (mag, neg) = math::ln(1);
    assert!(mag > 0);
    assert_eq!(neg, true);
}

#[test]
fun ln_power_of_two_roundtrip() {
    // For any power of 2, normalize yields (1e9, n) so result = n * LN2 exactly.
    // Verify ln(2^k) = k * 693_147_181 for several values.
    let (mag, _) = math::ln(2 * FLOAT);
    assert_eq!(mag, 693_147_181);
    let (mag, _) = math::ln(4 * FLOAT);
    assert_eq!(mag, 2 * 693_147_181);
    let (mag, _) = math::ln(8 * FLOAT);
    assert_eq!(mag, 3 * 693_147_181);
}

// ============================================================
// exp
// ============================================================

#[test]
fun exp_zero_positive() {
    assert_eq!(math::exp(0, false), FLOAT);
}

#[test]
fun exp_zero_negative() {
    assert_eq!(math::exp(0, true), FLOAT);
}

#[test]
fun exp_ln2_positive() {
    // e^(ln2) = 2.0. reduce_exp: n=1, r=0. exp_series(0)=1e9. 1e9 << 1 = 2e9.
    assert_eq!(math::exp(693_147_181, false), 2 * FLOAT);
}

#[test]
fun exp_ln2_negative() {
    // e^(-ln2) = 0.5. div(1e9,1e9) >> 1 = 500_000_000.
    assert_eq!(math::exp(693_147_181, true), 500_000_000);
}

#[test]
fun exp_2ln2_positive() {
    // e^(2*ln2) = 4.0. n=2, r=0. 1e9 << 2 = 4e9.
    assert_eq!(math::exp(1_386_294_362, false), 4 * FLOAT);
}

#[test]
fun exp_2ln2_negative() {
    // e^(-2*ln2) = 0.25. div(1e9,1e9) >> 2 = 250_000_000.
    assert_eq!(math::exp(1_386_294_362, true), 250_000_000);
}

#[test]
fun exp_3ln2_positive() {
    // e^(3*ln2) = 8.0. n=3, r=0. 1e9 << 3 = 8e9.
    assert_eq!(math::exp(2_079_441_543, false), 8 * FLOAT);
}

#[test]
fun exp_3ln2_negative() {
    // e^(-3*ln2) = 0.125. div(1e9,1e9) >> 3 = 125_000_000.
    assert_eq!(math::exp(2_079_441_543, true), 125_000_000);
}

#[test]
fun exp_large_negative_underflows_to_zero() {
    // e^(-50) should underflow to 0 via the cascading right-shift path
    assert_eq!(math::exp(50 * FLOAT, true), 0);
}

#[test]
fun exp_one_positive() {
    // e^1 = 2_718_281_818 (exact integer output from the Taylor series)
    assert_eq!(math::exp(FLOAT, false), 2_718_281_818);
}

#[test]
fun exp_one_negative() {
    // e^(-1) = 367_879_442 (exact integer output)
    assert_eq!(math::exp(FLOAT, true), 367_879_442);
}

#[test]
fun exp_roundtrip_two() {
    // exp(ln(2e9)) = 2e9 exactly (ln(2e9)=LN2, exp reduces to r=0, shift by 1)
    let (ln_mag, ln_neg) = math::ln(2 * FLOAT);
    let result = math::exp(ln_mag, ln_neg);
    assert_eq!(result, 2 * FLOAT);
}

#[test]
fun exp_roundtrip_half() {
    // exp(ln(0.5)) = 500_000_000 exactly
    let (ln_mag, ln_neg) = math::ln(500_000_000);
    let result = math::exp(ln_mag, ln_neg);
    assert_eq!(result, 500_000_000);
}

#[test]
fun exp_roundtrip_four() {
    let (ln_mag, ln_neg) = math::ln(4 * FLOAT);
    let result = math::exp(ln_mag, ln_neg);
    assert_eq!(result, 4 * FLOAT);
}

#[test]
fun exp_roundtrip_quarter() {
    let (ln_mag, ln_neg) = math::ln(250_000_000);
    let result = math::exp(ln_mag, ln_neg);
    assert_eq!(result, 250_000_000);
}

// ============================================================
// normal_cdf
// ============================================================

#[test]
fun cdf_zero_positive() {
    // Phi(0) ≈ 0.5. Due to integer rounding in the polynomial, the exact
    // output is 500_000_002.
    assert_eq!(math::normal_cdf(0, false), 500_000_002);
}

#[test]
fun cdf_zero_negative() {
    // Phi(-0): complement = 1e9 - 500_000_002 = 499_999_998
    assert_eq!(math::normal_cdf(0, true), 499_999_998);
}

#[test]
fun cdf_zero_sums_to_one() {
    let pos = math::normal_cdf(0, false);
    let neg = math::normal_cdf(0, true);
    assert_eq!(pos + neg, FLOAT);
}

#[test]
fun cdf_large_positive() {
    // Phi(x) = 1e9 for x > 8*FLOAT
    assert_eq!(math::normal_cdf(9 * FLOAT, false), FLOAT);
}

#[test]
fun cdf_large_negative() {
    // Phi(-x) = 0 for x > 8*FLOAT
    assert_eq!(math::normal_cdf(9 * FLOAT, true), 0);
}

#[test]
fun cdf_symmetry_one() {
    // Phi(1) + Phi(-1) = 1e9 by construction
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
    let pos = math::normal_cdf(500_000_000, false);
    let neg = math::normal_cdf(500_000_000, true);
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
    // x = 8*FLOAT exactly is not > 8*FLOAT, so it goes through polynomial
    let pos = math::normal_cdf(8 * FLOAT, false);
    let neg = math::normal_cdf(8 * FLOAT, true);
    assert_eq!(pos + neg, FLOAT);
    assert!(pos > 999_000_000);
}

#[test]
fun cdf_monotonic() {
    let c1 = math::normal_cdf(FLOAT, false);
    let c2 = math::normal_cdf(2 * FLOAT, false);
    let c3 = math::normal_cdf(3 * FLOAT, false);
    assert!(c1 < c2);
    assert!(c2 < c3);
}

#[test]
fun cdf_one_exact() {
    // Phi(1) = 841_344_742 (exact integer output from the Abramowitz polynomial)
    assert_eq!(math::normal_cdf(FLOAT, false), 841_344_742);
}

#[test]
fun cdf_neg_one_exact() {
    // Phi(-1) = 1e9 - Phi(1) = 158_655_258
    assert_eq!(math::normal_cdf(FLOAT, true), 158_655_258);
}

#[test]
fun cdf_two_exact() {
    // Phi(2) = 977_249_939 (exact integer output)
    assert_eq!(math::normal_cdf(2 * FLOAT, false), 977_249_939);
}

#[test]
fun cdf_neg_two_exact() {
    // Phi(-2) = 1e9 - Phi(2) = 22_750_061
    assert_eq!(math::normal_cdf(2 * FLOAT, true), 22_750_061);
}

#[test]
fun cdf_greater_than_half_for_positive() {
    // Any positive x should give Phi(x) > 0.5
    assert!(math::normal_cdf(100_000_000, false) > 500_000_000);
    assert!(math::normal_cdf(FLOAT, false) > 500_000_000);
    assert!(math::normal_cdf(5 * FLOAT, false) > 500_000_000);
}

#[test]
fun cdf_less_than_half_for_negative() {
    // Phi(-x) < 0.5 for any positive x
    assert!(math::normal_cdf(100_000_000, true) < 500_000_000);
    assert!(math::normal_cdf(FLOAT, true) < 500_000_000);
    assert!(math::normal_cdf(5 * FLOAT, true) < 500_000_000);
}
