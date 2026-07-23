// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module fixed_math::approx_tests;

use fixed_math::{approx::{Self, Approx}, i64::{Self, I64}, math::{Self, float_scaling as float}};
use std::unit_test::assert_eq;

const EUnexpectedSuccess: u64 = 999;
// Arbitrary-precision Decimal references emitted by
// `packages/predict/tests/helper/reference/generate_constants.py`.
const LN_RATIO_TWO_REFERENCE: u64 = 693_147_181;
const LN_RATIO_ONE_RAW_REFERENCE_MAG: u64 = 20_723_265_837;
const LN_RATIO_UNDERFLOW_REFERENCE_MAG: u64 = 20_772_056_001;
const LN_RATIO_U64_MAX_REFERENCE: u64 = 44_361_419_556;

fun assert_center(ball: &Approx, magnitude: u64, negative: bool) {
    assert_eq!(ball.magnitude(), magnitude);
    assert_eq!(ball.is_negative(), negative);
}

fun assert_contains(ball: &Approx, candidate: I64) {
    let center = ball.value();
    let distance = if (center.is_negative() == candidate.is_negative()) {
        let center_magnitude = center.magnitude();
        let candidate_magnitude = candidate.magnitude();
        if (center_magnitude >= candidate_magnitude) {
            (center_magnitude - candidate_magnitude) as u128
        } else {
            (candidate_magnitude - center_magnitude) as u128
        }
    } else {
        (center.magnitude() as u128) + (candidate.magnitude() as u128)
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

    let negated = a.neg();
    assert_center(&negated, 3 * float!() / 2, false);
    assert_eq!(negated.error(), 7);

    let doubled = a.double();
    assert_center(&doubled, 3 * float!(), true);
    assert_eq!(doubled.error(), 14);

    let halved = a.half();
    assert_center(&halved, 3 * float!() / 4, true);
    assert_eq!(halved.error(), 8);

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
    let one = above_one.clamp_unit_interval();
    assert_center(&one, float!(), false);
    assert_eq!(one.error(), 9);

    let below_upper = negative.clamp_upper(float!());
    assert_center(&below_upper, 10, true);
    assert_eq!(below_upper.error(), 7);
}

#[test]
fun mul_scaled_encloses_all_positive_corners_and_keeps_scalar_center() {
    let a = approx::from_certified_parts(i64::from_u64(3 * float!() / 2), float!() / 5);
    let b = approx::from_certified_parts(i64::from_u64(2 * float!()), 3 * float!() / 10);
    let result = a.mul_scaled(&b);

    assert_center(&result, 3 * float!(), false);
    assert_eq!(result.error(), 910_000_001);
    assert_contains(&result, i64::from_u64(2_210_000_000));
    assert_contains(&result, i64::from_u64(3_910_000_000));
}

#[test]
fun mul_scaled_encloses_negative_product_corners() {
    let a = approx::from_certified_parts(i64::from_parts(3 * float!() / 2, true), float!() / 5);
    let b = approx::from_certified_parts(i64::from_u64(2 * float!()), 3 * float!() / 10);
    let result = a.mul_scaled(&b);

    assert_center(&result, 3 * float!(), true);
    assert_contains(&result, i64::from_parts(2_210_000_000, true));
    assert_contains(&result, i64::from_parts(3_910_000_000, true));
}

#[test]
fun square_scaled_encloses_fixed_sign_and_zero_crossing_balls() {
    let fixed_sign = approx::from_certified_parts(
        i64::from_parts(3 * float!() / 2, true),
        float!() / 5,
    );
    let fixed_result = fixed_sign.square_scaled();
    assert_center(&fixed_result, 2_250_000_000, false);
    assert_eq!(fixed_result.error(), 640_000_001);
    assert_contains(&fixed_result, i64::from_u64(1_690_000_000));
    assert_contains(&fixed_result, i64::from_u64(2_890_000_000));

    let crossing = approx::from_certified_parts(i64::from_u64(float!() / 10), float!() / 5);
    let crossing_result = crossing.square_scaled();
    assert_center(&crossing_result, 10_000_000, false);
    assert_eq!(crossing_result.error(), 80_000_001);
    assert_contains(&crossing_result, i64::zero());
    assert_contains(&crossing_result, i64::from_u64(90_000_000));
}

#[test]
fun div_scaled_encloses_outward_quotient_corners() {
    let a = approx::from_certified_parts(i64::from_u64(3 * float!()), float!() / 5);
    let b = approx::from_certified_parts(i64::from_u64(2 * float!()), float!() / 10);
    let result = a.div_scaled(&b);

    assert_center(&result, 3 * float!() / 2, false);
    assert_eq!(result.error(), 188_365_653);
    let lower = math::div_down(14 * float!() / 5, 21 * float!() / 10);
    let upper = math::div_up(16 * float!() / 5, 19 * float!() / 10);
    assert_contains(&result, i64::from_u64(lower));
    assert_contains(&result, i64::from_u64(upper));
}

#[test]
fun div_scaled_saturates_when_denominator_ball_reaches_zero() {
    let a = approx::exact_u64(float!());
    let b = approx::from_certified_parts(i64::from_u64(float!() / 10), float!() / 10);
    assert_eq!(a.div_scaled(&b).error(), std::u64::max_value!());
}

#[test, expected_failure(abort_code = i64::EZeroDivisor)]
fun div_scaled_zero_center_denominator_aborts() {
    let numerator = approx::exact_u64(float!());
    let denominator = approx::exact_u64(0);
    numerator.div_scaled(&denominator);
    abort EUnexpectedSuccess
}

#[test]
fun mul_div_down_encloses_both_fixed_sign_corners() {
    let a = approx::from_certified_parts(i64::from_u64(3 * float!() / 2), float!() / 10);
    let b = approx::from_certified_parts(i64::from_u64(2 * float!()), float!() / 5);
    let c = approx::from_certified_parts(i64::from_u64(4 * float!()), float!() / 10);
    let result = a.mul_div_down(&b, &c);

    assert_center(&result, 3 * float!() / 4, false);
    assert_eq!(result.error(), 152_564_103);
    let lower = math::mul_div_down(
        3 * float!() / 2 - float!() / 10,
        2 * float!() - float!() / 5,
        4 * float!() + float!() / 10,
    );
    let upper = math::mul_div_up(
        3 * float!() / 2 + float!() / 10,
        2 * float!() + float!() / 5,
        4 * float!() - float!() / 10,
    );
    assert_contains(&result, i64::from_u64(lower));
    assert_contains(&result, i64::from_u64(upper));
}

#[test]
fun mul_div_down_accounts_for_a_negative_denominator() {
    let a = approx::exact_u64(float!());
    let b = approx::exact_u64(float!());
    let c = approx::exact(i64::from_parts(3 * float!(), true));
    let result = a.mul_div_down(&b, &c);

    assert_center(&result, 333_333_333, true);
    assert_eq!(result.error(), 1);
    assert_contains(&result, i64::from_parts(333_333_334, true));
}

#[test]
fun mul_div_down_covers_a_numerator_sign_change() {
    let a = approx::from_certified_parts(i64::from_u64(float!() / 10), float!() / 5);
    let b = approx::exact_u64(2 * float!());
    let c = approx::exact_u64(float!());
    let result = a.mul_div_down(&b, &c);

    assert_center(&result, float!() / 5, false);
    assert_eq!(result.error(), 4 * float!() / 5);
    assert_contains(&result, i64::from_parts(float!() / 5, true));
    assert_contains(&result, i64::from_u64(3 * float!() / 5));
}

#[test]
fun mul_div_down_saturates_uncertifiable_domains() {
    let one = approx::exact_u64(1);
    let denominator_crosses_zero = approx::from_certified_parts(i64::from_u64(1), 1);
    assert_eq!(one.mul_div_down(&one, &denominator_crosses_zero).error(), std::u64::max_value!());

    let endpoint_overflows = approx::from_certified_parts(i64::from_u64(std::u64::max_value!()), 1);
    assert_eq!(endpoint_overflows.mul_div_down(&one, &one).error(), std::u64::max_value!());
}

#[test, expected_failure(abort_code = math::EInputZero)]
fun mul_div_down_zero_center_denominator_aborts() {
    let one = approx::exact_u64(1);
    let denominator = approx::exact_u64(0);
    one.mul_div_down(&one, &denominator);
    abort EUnexpectedSuccess
}

#[test]
fun transcendental_balls_enclose_independent_endpoint_references() {
    // Python stdlib references, rounded to 1e9; these are independent of the
    // contract approximations used to construct each center.
    let logarithm = approx::ln(2 * float!(), float!() / 2);
    assert_contains(&logarithm, i64::from_u64(405_465_108)); // ln(1.5)
    assert_contains(&logarithm, i64::from_u64(916_290_732)); // ln(2.5)

    let square_root_input = approx::from_certified_parts(i64::from_u64(4 * float!()), float!());
    let square_root = square_root_input.sqrt();
    assert_center(&square_root, 2 * float!(), false);
    assert_eq!(square_root.error(), 267_949_194);
    assert_contains(&square_root, i64::from_u64(1_732_050_807)); // floor(sqrt(3) * 1e9)
    assert_contains(&square_root, i64::from_u64(2_236_067_977)); // floor(sqrt(5) * 1e9)

    let normal_input = approx::from_certified_parts(i64::from_u64(float!()), float!() / 2);
    let cdf = normal_input.normal_cdf();
    assert_contains(&cdf, i64::from_u64(691_462_461)); // Phi(0.5)
    assert_contains(&cdf, i64::from_u64(933_192_799)); // Phi(1.5)

    let pdf = normal_input.normal_pdf();
    assert_contains(&pdf, i64::from_u64(352_065_327)); // phi(0.5)
    assert_contains(&pdf, i64::from_u64(129_517_596)); // phi(1.5)
}

#[test]
fun ln_ratio_encloses_independent_references_across_quotient_domains() {
    let ordinary = approx::ln_ratio(2 * float!(), float!());
    assert_contains(&ordinary, i64::from_u64(LN_RATIO_TWO_REFERENCE));
    assert!(ordinary.error() < std::u64::max_value!());

    let one_raw = approx::ln_ratio(10_000_000, 10_000_000_000_000_000);
    assert_contains(
        &one_raw,
        i64::from_parts(LN_RATIO_ONE_RAW_REFERENCE_MAG, true),
    );
    assert!(one_raw.error() < std::u64::max_value!());

    let underflow = approx::ln_ratio(100_000_000, 105_000_000_000_000_000);
    assert_contains(
        &underflow,
        i64::from_parts(LN_RATIO_UNDERFLOW_REFERENCE_MAG, true),
    );
    assert!(underflow.error() < std::u64::max_value!());

    let overflow = approx::ln_ratio(std::u64::max_value!(), 1);
    assert_contains(&overflow, i64::from_u64(LN_RATIO_U64_MAX_REFERENCE));
    assert!(overflow.error() < std::u64::max_value!());
}

#[test, expected_failure(abort_code = math::EInputZero)]
fun ln_ratio_zero_numerator_aborts() {
    approx::ln_ratio(0, float!());
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = math::EInputZero)]
fun ln_ratio_zero_denominator_aborts() {
    approx::ln_ratio(float!(), 0);
    abort EUnexpectedSuccess
}

#[test]
fun normal_cdf_uses_a_certified_upper_bound_for_its_derivative() {
    // At x=0.024, independent Python true math gives phi(x)=398_827_401.568...
    // raw units, so 398_827_402 is an outward integer upper bound. The ball spans
    // [0.024, 20.024], making x=0.024 the exact maximum-density corner.
    let radius = 10 * float!();
    let input = approx::from_certified_parts(i64::from_u64(10_024_000_000), radius);
    let result = input.normal_cdf();
    let required_propagation = math::mul_up(398_827_402, radius);
    assert!(result.error() >= required_propagation + 20);
}

#[test]
fun error_arithmetic_saturates_instead_of_wrapping() {
    let saturated = approx::from_certified_parts(i64::from_u64(float!()), std::u64::max_value!());
    let exact = approx::exact_u64(float!());
    assert_eq!(saturated.add(&exact).error(), std::u64::max_value!());
    assert_eq!(saturated.sub(&exact).error(), std::u64::max_value!());
    assert_eq!(saturated.mul_scaled(&exact).error(), std::u64::max_value!());
    assert_eq!(approx::ln(float!(), float!()).error(), std::u64::max_value!());
}
