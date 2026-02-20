// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::math_tests;

use deepbook_predict::{constants, math};
use std::unit_test::assert_eq;

/// Helper: assert value is within tolerance of expected.
fun assert_approx(actual: u64, expected: u64, tolerance: u64) {
    let diff = if (actual > expected) { actual - expected } else { expected - actual };
    assert!(diff <= tolerance, actual);
}

// === ln Tests ===

#[test]
fun ln_of_one_is_zero() {
    let (result, is_neg) = math::ln(constants::float_scaling!());
    assert_eq!(result, 0);
    assert_eq!(is_neg, false);
}

#[test]
fun ln_of_e_is_one() {
    // e ≈ 2.718281828 → 2_718_281_828 in float_scaling
    let (result, is_neg) = math::ln(2_718_281_828);
    assert_eq!(is_neg, false);
    // Should be ~1.0 = 1_000_000_000
    assert_approx(result, constants::float_scaling!(), 1_000_000);
}

#[test]
fun ln_of_two() {
    // ln(2) ≈ 0.693147181
    let (result, is_neg) = math::ln(2 * constants::float_scaling!());
    assert_eq!(is_neg, false);
    assert_approx(result, 693_147_181, 1_000_000);
}

#[test]
fun ln_of_ten() {
    // ln(10) ≈ 2.302585093
    let (result, is_neg) = math::ln(10 * constants::float_scaling!());
    assert_eq!(is_neg, false);
    assert_approx(result, 2_302_585_093, 2_000_000);
}

#[test]
fun ln_below_one_is_negative() {
    // ln(0.5) ≈ -0.693147181
    let (result, is_neg) = math::ln(500_000_000);
    assert_eq!(is_neg, true);
    assert_approx(result, 693_147_181, 1_000_000);
}

#[test]
fun ln_of_small_value() {
    // ln(0.01) ≈ -4.605170186
    let (result, is_neg) = math::ln(10_000_000);
    assert_eq!(is_neg, true);
    assert_approx(result, 4_605_170_186, 5_000_000);
}

#[test]
fun ln_of_large_value() {
    // ln(100) ≈ 4.605170186
    let (result, is_neg) = math::ln(100 * constants::float_scaling!());
    assert_eq!(is_neg, false);
    assert_approx(result, 4_605_170_186, 5_000_000);
}

#[test]
fun ln_inverse_symmetry() {
    // ln(x) and ln(1/x) should have same magnitude, opposite signs
    let x = 3 * constants::float_scaling!(); // 3.0
    let inv_x = constants::float_scaling!() / 3; // ~0.333

    let (ln_x, neg_x) = math::ln(x);
    let (ln_inv, neg_inv) = math::ln(inv_x);

    assert_eq!(neg_x, false);
    assert_eq!(neg_inv, true);
    // Magnitudes should be close (small error from integer division)
    assert_approx(ln_x, ln_inv, 5_000_000);
}

#[test, expected_failure(abort_code = math::EInputZero)]
fun ln_of_zero_aborts() {
    math::ln(0);
    abort
}

// === exp Tests ===

#[test]
fun exp_of_zero_is_one() {
    let result = math::exp(0, false);
    assert_eq!(result, constants::float_scaling!());
}

#[test]
fun exp_of_one() {
    // e^1 ≈ 2.718281828
    let result = math::exp(constants::float_scaling!(), false);
    assert_approx(result, 2_718_281_828, 1_000_000);
}

#[test]
fun exp_of_negative_one() {
    // e^(-1) ≈ 0.367879441
    let result = math::exp(constants::float_scaling!(), true);
    assert_approx(result, 367_879_441, 1_000_000);
}

#[test]
fun exp_of_two() {
    // e^2 ≈ 7.389056099
    let result = math::exp(2 * constants::float_scaling!(), false);
    assert_approx(result, 7_389_056_099, 5_000_000);
}

#[test]
fun exp_of_ln2() {
    // e^(ln2) = 2.0
    let result = math::exp(693_147_181, false);
    assert_approx(result, 2 * constants::float_scaling!(), 2_000_000);
}

#[test]
fun exp_large_negative_approaches_zero() {
    // e^(-20) ≈ 2.06e-9 → rounds to 0 or near 0
    let result = math::exp(20 * constants::float_scaling!(), true);
    assert!(result <= 10);
}

#[test]
fun exp_and_ln_are_inverses() {
    // exp(ln(5)) ≈ 5
    let x = 5 * constants::float_scaling!();
    let (ln_x, is_neg) = math::ln(x);
    let recovered = math::exp(ln_x, is_neg);
    assert_approx(recovered, x, 10_000_000);
}

#[test]
fun exp_and_ln_inverse_below_one() {
    // exp(ln(0.25)) ≈ 0.25
    let x = 250_000_000;
    let (ln_x, is_neg) = math::ln(x);
    let recovered = math::exp(ln_x, is_neg);
    assert_approx(recovered, x, 5_000_000);
}

// === normal_cdf Tests ===

#[test]
fun cdf_at_zero_is_half() {
    // Φ(0) = 0.5
    let result = math::normal_cdf(0, false);
    assert_approx(result, 500_000_000, 5_000_000);
}

#[test]
fun cdf_symmetry() {
    // Φ(x) + Φ(-x) = 1
    let x = constants::float_scaling!(); // 1.0
    let cdf_pos = math::normal_cdf(x, false);
    let cdf_neg = math::normal_cdf(x, true);
    let sum = cdf_pos + cdf_neg;
    assert_approx(sum, constants::float_scaling!(), 1_000_000);
}

#[test]
fun cdf_symmetry_at_two() {
    let x = 2 * constants::float_scaling!();
    let cdf_pos = math::normal_cdf(x, false);
    let cdf_neg = math::normal_cdf(x, true);
    let sum = cdf_pos + cdf_neg;
    assert_approx(sum, constants::float_scaling!(), 1_000_000);
}

#[test]
fun cdf_positive_one() {
    // Φ(1.0) ≈ 0.8413
    let result = math::normal_cdf(constants::float_scaling!(), false);
    assert_approx(result, 841_345_000, 5_000_000);
}

#[test]
fun cdf_negative_one() {
    // Φ(-1.0) ≈ 0.1587
    let result = math::normal_cdf(constants::float_scaling!(), true);
    assert_approx(result, 158_655_000, 5_000_000);
}

#[test]
fun cdf_positive_two() {
    // Φ(2.0) ≈ 0.9772
    let result = math::normal_cdf(2 * constants::float_scaling!(), false);
    assert_approx(result, 977_250_000, 5_000_000);
}

#[test]
fun cdf_large_positive_saturates() {
    // Φ(10) → ~1.0
    let result = math::normal_cdf(10 * constants::float_scaling!(), false);
    assert_eq!(result, constants::float_scaling!());
}

#[test]
fun cdf_large_negative_saturates() {
    // Φ(-10) → ~0.0
    let result = math::normal_cdf(10 * constants::float_scaling!(), true);
    assert_eq!(result, 0);
}

#[test]
fun cdf_monotonically_increasing() {
    let a = math::normal_cdf(500_000_000, false); // Φ(0.5)
    let b = math::normal_cdf(constants::float_scaling!(), false); // Φ(1.0)
    let c = math::normal_cdf(2 * constants::float_scaling!(), false); // Φ(2.0)
    assert!(a < b);
    assert!(b < c);
}

#[test]
fun cdf_at_half() {
    // Φ(0.5) ≈ 0.6915
    let result = math::normal_cdf(500_000_000, false);
    assert_approx(result, 691_462_000, 5_000_000);
}

// === Signed Arithmetic: add_signed_u64 ===

#[test]
fun add_same_sign_positive() {
    // 3 + 5 = 8
    let (mag, neg) = math::add_signed_u64(3, false, 5, false);
    assert_eq!(mag, 8);
    assert_eq!(neg, false);
}

#[test]
fun add_same_sign_negative() {
    // (-3) + (-5) = -8
    let (mag, neg) = math::add_signed_u64(3, true, 5, true);
    assert_eq!(mag, 8);
    assert_eq!(neg, true);
}

#[test]
fun add_different_sign_positive_larger() {
    // 5 + (-3) = 2
    let (mag, neg) = math::add_signed_u64(5, false, 3, true);
    assert_eq!(mag, 2);
    assert_eq!(neg, false);
}

#[test]
fun add_different_sign_negative_larger() {
    // (-5) + 3 = -2
    let (mag, neg) = math::add_signed_u64(5, true, 3, false);
    assert_eq!(mag, 2);
    assert_eq!(neg, true);
}

#[test]
fun add_cancels_to_zero() {
    // 5 + (-5) = 0 (positive zero)
    let (mag, neg) = math::add_signed_u64(5, false, 5, true);
    assert_eq!(mag, 0);
    assert_eq!(neg, false);
}

#[test]
fun add_negative_cancels_to_zero() {
    // (-5) + 5 = 0 (positive zero)
    let (mag, neg) = math::add_signed_u64(5, true, 5, false);
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
fun add_zero_identity() {
    // 7 + 0 = 7
    let (mag, neg) = math::add_signed_u64(7, false, 0, false);
    assert_eq!(mag, 7);
    assert_eq!(neg, false);
}

#[test]
fun add_negative_zero_normalizes() {
    // (-0) + (-0) = +0
    let (mag, neg) = math::add_signed_u64(0, true, 0, true);
    assert_eq!(mag, 0);
    assert_eq!(neg, false);
}

// === Signed Arithmetic: sub_signed_u64 ===

#[test]
fun sub_positive_minus_positive() {
    // 5 - 3 = 2
    let (mag, neg) = math::sub_signed_u64(5, false, 3, false);
    assert_eq!(mag, 2);
    assert_eq!(neg, false);
}

#[test]
fun sub_positive_minus_larger_positive() {
    // 3 - 5 = -2
    let (mag, neg) = math::sub_signed_u64(3, false, 5, false);
    assert_eq!(mag, 2);
    assert_eq!(neg, true);
}

#[test]
fun sub_negative_minus_negative() {
    // (-3) - (-5) = (-3) + 5 = 2
    let (mag, neg) = math::sub_signed_u64(3, true, 5, true);
    assert_eq!(mag, 2);
    assert_eq!(neg, false);
}

#[test]
fun sub_positive_minus_negative() {
    // 3 - (-5) = 3 + 5 = 8
    let (mag, neg) = math::sub_signed_u64(3, false, 5, true);
    assert_eq!(mag, 8);
    assert_eq!(neg, false);
}

#[test]
fun sub_negative_minus_positive() {
    // (-3) - 5 = -8
    let (mag, neg) = math::sub_signed_u64(3, true, 5, false);
    assert_eq!(mag, 8);
    assert_eq!(neg, true);
}

#[test]
fun sub_equal_values_is_zero() {
    // 5 - 5 = 0
    let (mag, neg) = math::sub_signed_u64(5, false, 5, false);
    assert_eq!(mag, 0);
    assert_eq!(neg, false);
}

// === Signed Arithmetic: mul_signed_u64 ===

#[test]
fun mul_positive_times_positive() {
    // 2.0 * 3.0 = 6.0 (in float_scaling)
    let a = 2 * constants::float_scaling!();
    let b = 3 * constants::float_scaling!();
    let (mag, neg) = math::mul_signed_u64(a, false, b, false);
    assert_eq!(mag, 6 * constants::float_scaling!());
    assert_eq!(neg, false);
}

#[test]
fun mul_positive_times_negative() {
    // 2.0 * (-3.0) = -6.0
    let a = 2 * constants::float_scaling!();
    let b = 3 * constants::float_scaling!();
    let (mag, neg) = math::mul_signed_u64(a, false, b, true);
    assert_eq!(mag, 6 * constants::float_scaling!());
    assert_eq!(neg, true);
}

#[test]
fun mul_negative_times_negative() {
    // (-2.0) * (-3.0) = 6.0
    let a = 2 * constants::float_scaling!();
    let b = 3 * constants::float_scaling!();
    let (mag, neg) = math::mul_signed_u64(a, true, b, true);
    assert_eq!(mag, 6 * constants::float_scaling!());
    assert_eq!(neg, false);
}

#[test]
fun mul_by_zero() {
    let a = 5 * constants::float_scaling!();
    let (mag, _neg) = math::mul_signed_u64(a, false, 0, false);
    assert_eq!(mag, 0);
}

#[test]
fun mul_by_one() {
    // 5.0 * 1.0 = 5.0
    let a = 5 * constants::float_scaling!();
    let (mag, neg) = math::mul_signed_u64(a, false, constants::float_scaling!(), false);
    assert_eq!(mag, a);
    assert_eq!(neg, false);
}
