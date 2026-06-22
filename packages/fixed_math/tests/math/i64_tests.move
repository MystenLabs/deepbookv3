// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module fixed_math::i64_tests;

use fixed_math::{i64, math::float_scaling as float};
use std::unit_test::assert_eq;

// === Constructors and getters ===

#[test]
fun zero_is_normalized_nonnegative() {
    let z = i64::zero();
    assert_eq!(z.magnitude(), 0);
    assert!(!z.is_negative());
    assert!(z.is_zero());
}

#[test]
fun from_u64_is_nonnegative() {
    let v = i64::from_u64(42);
    assert_eq!(v.magnitude(), 42);
    assert!(!v.is_negative());
    assert!(!v.is_zero());
}

#[test]
fun from_u64_max_is_nonnegative() {
    let v = i64::from_u64(std::u64::max_value!());
    assert_eq!(v.magnitude(), std::u64::max_value!());
    assert!(!v.is_negative());
}

#[test]
fun from_parts_positive_keeps_sign() {
    let v = i64::from_parts(10, false);
    assert_eq!(v.magnitude(), 10);
    assert!(!v.is_negative());
}

#[test]
fun from_parts_negative_keeps_sign() {
    let v = i64::from_parts(10, true);
    assert_eq!(v.magnitude(), 10);
    assert!(v.is_negative());
}

#[test]
fun from_parts_zero_magnitude_normalizes_to_nonnegative() {
    // is_negative=true with magnitude=0 must collapse to the canonical zero
    // so equality checks elsewhere don't see "negative zero" as distinct.
    let v = i64::from_parts(0, true);
    assert_eq!(v.magnitude(), 0);
    assert!(!v.is_negative());
    assert!(v.is_zero());
}

#[test]
fun is_zero_true_for_zero_only() {
    assert!(i64::zero().is_zero());
    assert!(i64::from_u64(0).is_zero());
    assert!(!i64::from_u64(1).is_zero());
    assert!(!i64::from_parts(1, true).is_zero());
}

// === neg ===

#[test]
fun neg_zero_stays_normalized_nonnegative() {
    let n = i64::zero().neg();
    assert_eq!(n.magnitude(), 0);
    assert!(!n.is_negative());
}

#[test]
fun neg_positive_becomes_negative() {
    let n = i64::from_u64(5).neg();
    assert_eq!(n.magnitude(), 5);
    assert!(n.is_negative());
}

#[test]
fun neg_negative_becomes_positive() {
    let n = i64::from_parts(5, true).neg();
    assert_eq!(n.magnitude(), 5);
    assert!(!n.is_negative());
}

// === add ===

#[test]
fun add_two_positives_sums_magnitudes() {
    let r = i64::from_u64(3).add(&i64::from_u64(4));
    assert_eq!(r.magnitude(), 7);
    assert!(!r.is_negative());
}

#[test]
fun add_two_negatives_sums_magnitudes_negative() {
    let r = i64::from_parts(3, true).add(&i64::from_parts(4, true));
    assert_eq!(r.magnitude(), 7);
    assert!(r.is_negative());
}

#[test]
fun add_positive_plus_smaller_negative_is_positive() {
    // +10 + (-3) = +7
    let r = i64::from_u64(10).add(&i64::from_parts(3, true));
    assert_eq!(r.magnitude(), 7);
    assert!(!r.is_negative());
}

#[test]
fun add_positive_plus_larger_negative_is_negative() {
    // +3 + (-10) = -7
    let r = i64::from_u64(3).add(&i64::from_parts(10, true));
    assert_eq!(r.magnitude(), 7);
    assert!(r.is_negative());
}

#[test]
fun add_opposite_equal_magnitudes_is_zero() {
    // +5 + (-5) = 0 (must normalize to nonnegative zero)
    let r = i64::from_u64(5).add(&i64::from_parts(5, true));
    assert!(r.is_zero());
    assert!(!r.is_negative());
}

#[test]
fun add_zero_is_identity() {
    let r = i64::from_u64(7).add(&i64::zero());
    assert_eq!(r.magnitude(), 7);
    assert!(!r.is_negative());

    let r2 = i64::zero().add(&i64::from_parts(7, true));
    assert_eq!(r2.magnitude(), 7);
    assert!(r2.is_negative());
}

// === sub ===

#[test]
fun sub_positives_can_go_negative() {
    // 3 - 10 = -7
    let r = i64::from_u64(3).sub(&i64::from_u64(10));
    assert_eq!(r.magnitude(), 7);
    assert!(r.is_negative());
}

#[test]
fun sub_positives_stays_positive_when_larger_first() {
    // 10 - 3 = +7
    let r = i64::from_u64(10).sub(&i64::from_u64(3));
    assert_eq!(r.magnitude(), 7);
    assert!(!r.is_negative());
}

#[test]
fun sub_equal_magnitudes_is_zero() {
    let r = i64::from_u64(5).sub(&i64::from_u64(5));
    assert!(r.is_zero());
    assert!(!r.is_negative());
}

#[test]
fun sub_negative_minus_negative_orders_by_magnitude() {
    // -3 - (-10) = +7
    let r = i64::from_parts(3, true).sub(&i64::from_parts(10, true));
    assert_eq!(r.magnitude(), 7);
    assert!(!r.is_negative());
}

#[test]
fun sub_zero_is_identity() {
    let r = i64::from_u64(7).sub(&i64::zero());
    assert_eq!(r.magnitude(), 7);
    assert!(!r.is_negative());
}

#[test]
fun sub_from_zero_negates() {
    // 0 - 7 = -7
    let r = i64::zero().sub(&i64::from_u64(7));
    assert_eq!(r.magnitude(), 7);
    assert!(r.is_negative());
}

// === mul_scaled (FLOAT_SCALING = 1e9) ===

#[test]
fun mul_scaled_one_times_one_is_one() {
    let r = i64::from_u64(float!()).mul_scaled(&i64::from_u64(float!()));
    assert_eq!(r.magnitude(), float!());
    assert!(!r.is_negative());
}

#[test]
fun mul_scaled_two_times_three_is_six() {
    // 2.0 * 3.0 = 6.0 in 1e9 fixed-point.
    let r = i64::from_u64(2 * float!()).mul_scaled(&i64::from_u64(3 * float!()));
    assert_eq!(r.magnitude(), 6 * float!());
    assert!(!r.is_negative());
}

#[test]
fun mul_scaled_signs_multiply() {
    // (-2) * (+3) = -6
    let r = i64::from_parts(2 * float!(), true).mul_scaled(&i64::from_u64(3 * float!()));
    assert_eq!(r.magnitude(), 6 * float!());
    assert!(r.is_negative());

    // (-2) * (-3) = +6
    let r2 = i64::from_parts(2 * float!(), true).mul_scaled(&i64::from_parts(3 * float!(), true));
    assert_eq!(r2.magnitude(), 6 * float!());
    assert!(!r2.is_negative());
}

#[test]
fun mul_scaled_by_zero_is_zero() {
    // a is negative but result magnitude == 0, so the result must normalize
    // to nonnegative zero (covered by `from_parts`).
    let r = i64::from_parts(5 * float!(), true).mul_scaled(&i64::zero());
    assert!(r.is_zero());
    assert!(!r.is_negative());
}

#[test]
fun mul_scaled_rounds_down() {
    // 1e9 * 1 / 1e9 = 1 exactly; verify u128 intermediate avoids overflow at
    // a value that would overflow a u64 multiply.
    let big = std::u64::max_value!() / 2;
    let r = i64::from_u64(big).mul_scaled(&i64::from_u64(float!()));
    // (big * 1e9) / 1e9 == big exactly.
    assert_eq!(r.magnitude(), big);
}

// === div_scaled ===

#[test]
fun div_scaled_six_div_three_is_two() {
    // 6.0 / 3.0 = 2.0
    let r = i64::from_u64(6 * float!()).div_scaled(&i64::from_u64(3 * float!()));
    assert_eq!(r.magnitude(), 2 * float!());
    assert!(!r.is_negative());
}

#[test]
fun div_scaled_one_div_two_is_half() {
    // 1.0 / 2.0 = 0.5 = 500_000_000
    let r = i64::from_u64(float!()).div_scaled(&i64::from_u64(2 * float!()));
    assert_eq!(r.magnitude(), float!() / 2);
    assert!(!r.is_negative());
}

#[test]
fun div_scaled_signs_divide() {
    // (-6) / (+3) = -2
    let r = i64::from_parts(6 * float!(), true).div_scaled(&i64::from_u64(3 * float!()));
    assert_eq!(r.magnitude(), 2 * float!());
    assert!(r.is_negative());

    // (-6) / (-3) = +2
    let r2 = i64::from_parts(6 * float!(), true).div_scaled(&i64::from_parts(3 * float!(), true));
    assert_eq!(r2.magnitude(), 2 * float!());
    assert!(!r2.is_negative());
}

#[test]
fun div_scaled_zero_numerator_is_zero() {
    let r = i64::zero().div_scaled(&i64::from_u64(3 * float!()));
    assert!(r.is_zero());
    assert!(!r.is_negative());
}

#[test]
fun div_scaled_rounds_down() {
    // 1 / 3 in 1e9 fixed-point = floor(1e18 / 3) / 1 = 333_333_333.
    let r = i64::from_u64(float!()).div_scaled(&i64::from_u64(3 * float!()));
    assert_eq!(r.magnitude(), 333_333_333);
}

// EZeroDivisor is the only abort in this module.
#[test, expected_failure(abort_code = i64::EZeroDivisor)]
fun div_scaled_by_zero_aborts() {
    i64::from_u64(1).div_scaled(&i64::zero());
    abort 999
}

// === square_scaled ===

#[test]
fun square_scaled_zero_is_zero() {
    assert_eq!(i64::zero().square_scaled(), 0);
}

#[test]
fun square_scaled_one_is_one() {
    assert_eq!(i64::from_u64(float!()).square_scaled(), float!());
}

#[test]
fun square_scaled_three_is_nine() {
    // 3.0^2 = 9.0
    assert_eq!(i64::from_u64(3 * float!()).square_scaled(), 9 * float!());
}

#[test]
fun square_scaled_negative_three_is_nine() {
    // (-3.0)^2 = +9.0 (squared values must be nonnegative)
    assert_eq!(i64::from_parts(3 * float!(), true).square_scaled(), 9 * float!());
}

#[test]
fun square_scaled_half_is_quarter() {
    // (0.5)^2 = 0.25 = 250_000_000
    assert_eq!(i64::from_u64(float!() / 2).square_scaled(), float!() / 4);
}
