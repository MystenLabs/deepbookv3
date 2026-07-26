// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module fixed_math::approx_tests;

use fixed_math::{approx::{Self, Approx}, i64::{Self, I64}, math::float_scaling as float};
use std::unit_test::assert_eq;

fun assert_center(ball: &Approx, magnitude: u64, negative: bool) {
    assert_eq!(ball.magnitude(), magnitude);
    assert_eq!(ball.is_negative(), negative);
}

fun assert_contains(ball: &Approx, candidate: I64) {
    let center_magnitude = ball.magnitude();
    let center_is_negative = ball.is_negative();
    let distance = if (center_is_negative == candidate.is_negative()) {
        let candidate_magnitude = candidate.magnitude();
        if (center_magnitude >= candidate_magnitude) {
            (center_magnitude - candidate_magnitude) as u128
        } else {
            (candidate_magnitude - center_magnitude) as u128
        }
    } else {
        (center_magnitude as u128) + (candidate.magnitude() as u128)
    };
    assert!(distance <= (ball.error() as u128));
}

#[test]
fun constructors_and_linear_operations_preserve_the_scalar_center() {
    let a = approx::from_certified_parts(i64::from_parts(3 * float!() / 2, true), 7);
    let b = approx::from_certified_parts(i64::from_u64(float!() / 4), 11);

    let sum = a.add(&b);
    assert_center(&sum, 5 * float!() / 4, true);
    assert_eq!(sum.error(), 18);

    let difference = a.sub(&b);
    assert_center(&difference, 7 * float!() / 4, true);
    assert_eq!(difference.error(), 18);

    let exact = approx::exact_u64(42);
    assert_center(&exact, 42, false);
    assert_eq!(exact.error(), 0);
}

#[test]
fun continuous_clamps_retain_the_radius() {
    let negative = approx::from_certified_parts(i64::from_parts(10, true), 7);
    let zero = negative.clamp_nonnegative();
    assert_center(&zero, 0, false);
    assert_eq!(zero.error(), 7);

    let above_one = approx::from_certified_parts(i64::from_u64(2 * float!()), 9);
    let one = above_one.clamp_upper(float!());
    assert_center(&one, float!(), false);
    assert_eq!(one.error(), 9);

    let below_upper = negative.clamp_upper(float!());
    assert_center(&below_upper, 10, true);
    assert_eq!(below_upper.error(), 7);
}

#[test]
fun mul_exact_encloses_both_corners_and_keeps_scalar_center() {
    // 1.5 +/- 0.2 scaled by an exact 2.0: center 3.0, corners 2.6 and 3.4.
    let a = approx::from_certified_parts(i64::from_u64(3 * float!() / 2), float!() / 5);
    let result = a.mul_exact(&i64::from_u64(2 * float!()));

    assert_center(&result, 3 * float!(), false);
    assert_eq!(result.error(), 400_000_001);
    assert_contains(&result, i64::from_u64(2_600_000_000));
    assert_contains(&result, i64::from_u64(3_400_000_000));
}

#[test]
fun mul_exact_encloses_negative_product_corners() {
    let a = approx::from_certified_parts(i64::from_parts(3 * float!() / 2, true), float!() / 5);
    let result = a.mul_exact(&i64::from_u64(2 * float!()));

    assert_center(&result, 3 * float!(), true);
    assert_contains(&result, i64::from_parts(2_600_000_000, true));
    assert_contains(&result, i64::from_parts(3_400_000_000, true));
}

#[test]
fun exact_zero_absorbs_multiplication_uncertainty_on_either_side() {
    let uncertain = approx::from_certified_parts(i64::from_parts(2 * float!(), true), float!() / 5);

    let zero_multiplier = uncertain.mul_exact(&i64::zero());
    assert_center(&zero_multiplier, 0, false);
    assert_eq!(zero_multiplier.error(), 0);

    let zero_ball = approx::exact_u64(0).mul_exact(&i64::from_u64(2 * float!()));
    assert_center(&zero_ball, 0, false);
    assert_eq!(zero_ball.error(), 0);
}

#[test]
fun zero_center_with_error_does_not_absorb_multiplication_uncertainty() {
    let uncertain_zero = approx::from_certified_parts(i64::zero(), 1);
    let result = uncertain_zero.mul_exact(&i64::from_u64(float!()));

    assert_center(&result, 0, false);
    assert_eq!(result.error(), 2);
}

#[test]
fun relative_deviation_uses_the_worst_denominator_corner() {
    // 1.0 +/- 0.001: the worst denominator is 0.999, so the true relative
    // deviation is 0.001 / 0.999 = 0.1001...%, outside a 0.1% ceiling and inside
    // a 0.11% one.
    let ball = approx::from_certified_parts(i64::from_u64(float!()), float!() / 1000);
    assert!(!ball.true_relative_deviation_within(1_000_000));
    assert!(ball.true_relative_deviation_within(1_100_000));

    // An error at or above the center admits zero, so no relative bound holds.
    let unbounded = approx::from_certified_parts(i64::from_u64(float!()), float!() + 1);
    assert!(!unbounded.true_relative_deviation_within(std::u64::max_value!()));
}

#[test]
fun error_arithmetic_saturates_instead_of_wrapping() {
    let saturated = approx::from_certified_parts(i64::from_u64(float!()), std::u64::max_value!());
    let exact = approx::exact_u64(float!());
    assert_eq!(saturated.add(&exact).error(), std::u64::max_value!());
    assert_eq!(saturated.sub(&exact).error(), std::u64::max_value!());
    assert_eq!(saturated.mul_exact(&i64::from_u64(float!())).error(), std::u64::max_value!());
}
