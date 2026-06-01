// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::math_tests;

use deepbook_predict::{constants::float_scaling as float, i64, math};
use std::unit_test::assert_eq;

// Math approximation snapshot constants (FLOAT_SCALING = 1e9).
//
// Each constant is anchored against a scipy ground-truth value documented in
// the adjacent comment. The asserted value is the contract's current
// fixed-point output, which differs from scipy by the noted `delta`. This is
// intentional: the math module trades precision for cheap on-chain evaluation
// (~5 units of error at 1e9 per the `normal_cdf` source comment), and the
// snapshot exists so any future change to the approximation surfaces here
// rather than silently shifting downstream pricing. When `generate_constants.py`
// lands, regenerate these and re-verify the deltas.

// ln: scipy = 0.6931471805599453, expected = 693_147_181 (rounded).
// Contract returns 693_147_180; delta = -1 (scipy is +1).
const LN_2: u64 = 693_147_180;
// ln: scipy = 2.302585092994046, expected = 2_302_585_093.
// Contract returns 2_302_585_090; delta = -3.
const LN_10: u64 = 2_302_585_090;

// exp: scipy = 2.718281828459045, expected = 2_718_281_828.
// Contract returns 2_718_281_820; delta = -8.
const EXP_1: u64 = 2_718_281_820;
// exp: scipy = 0.36787944117144233, expected = 367_879_441.
// Contract returns 367_879_442; delta = +1.
const EXP_NEG_1: u64 = 367_879_442;
// exp: scipy = 7.38905609893065, expected = 7_389_056_099.
// Contract returns 7_389_056_092; delta = -7.
const EXP_2: u64 = 7_389_056_092;
// exp: scipy = 0.1353352832366127, expected = 135_335_283. Contract matches.
const EXP_NEG_2: u64 = 135_335_283;
// exp: scipy = 22026.465794806718, expected = 22_026_465_794_807.
// Contract returns 22_026_465_902_592; delta = +107_785 (rel ~5e-6).
// Larger drift at the high end is expected from the shift-by-32 path in
// `exp_u128`.
const EXP_10: u64 = 22_026_465_902_592;
// exp: scipy = 0.00004539992976248485, expected = 45_400.
// Contract returns 45_399; delta = -1.
const EXP_NEG_10: u64 = 45_399;

// normal_cdf: scipy = 0.6914624612740131, expected = 691_462_461. Contract matches.
const CDF_HALF: u64 = 691_462_461;
// normal_cdf: scipy = 0.3085375387259869, expected = 308_537_539. Contract matches.
const CDF_NEG_HALF: u64 = 308_537_539;
// normal_cdf: scipy = 0.8413447460685429, expected = 841_344_746.
// Contract returns 841_344_747; delta = +1.
const CDF_1: u64 = 841_344_747;
// normal_cdf: scipy = 0.15865525393145707, expected = 158_655_254.
// Contract returns 158_655_253; delta = -1.
const CDF_NEG_1: u64 = 158_655_253;
// normal_cdf: scipy = 0.9772498680518208, expected = 977_249_868.
// Contract returns 977_249_869; delta = +1.
const CDF_2: u64 = 977_249_869;
// normal_cdf: scipy = 0.022750131948179195, expected = 22_750_132.
// Contract returns 22_750_131; delta = -1.
const CDF_NEG_2: u64 = 22_750_131;
// normal_cdf: scipy = 0.9986501019683699, expected = 998_650_102.
// Contract returns 998_650_103; delta = +1.
const CDF_3: u64 = 998_650_103;
// normal_cdf: scipy = 0.0013498980316301035, expected = 1_349_898.
// Contract returns 1_349_897; delta = -1.
const CDF_NEG_3: u64 = 1_349_897;

// sqrt: scipy = 1.4142135623730951, expected = 1_414_213_562. Contract matches.
const SQRT_2: u64 = 1_414_213_562;
// sqrt: scipy = 1.7320508075688772, expected = 1_732_050_808.
// Contract returns 1_732_050_807; delta = -1 (Newton-step floor correction).
const SQRT_3: u64 = 1_732_050_807;
// sqrt: scipy = 0.7071067811865476, expected = 707_106_781. Contract matches.
const SQRT_HALF: u64 = 707_106_781;

// === ln ===

#[test]
fun ln_of_one_is_zero() {
    let r = math::ln(float!());
    assert!(r.is_zero());
    assert!(!r.is_negative());
}

#[test]
fun ln_of_two_matches_snapshot() {
    let r = math::ln(2 * float!());
    assert_eq!(r.magnitude(), LN_2);
    assert!(!r.is_negative());
}

#[test]
fun ln_of_ten_matches_snapshot() {
    let r = math::ln(10 * float!());
    assert_eq!(r.magnitude(), LN_10);
    assert!(!r.is_negative());
}

#[test]
fun ln_of_half_is_negative_ln2() {
    // ln(0.5) = -ln(2); exercises the inverse path (`x < float!()`) inside the contract.
    let r = math::ln(float!() / 2);
    assert_eq!(r.magnitude(), LN_2);
    assert!(r.is_negative());
}

#[test, expected_failure(abort_code = math::EInputZero)]
fun ln_of_zero_aborts() {
    math::ln(0);
    abort 999
}

// === exp ===

#[test]
fun exp_of_zero_is_one() {
    assert_eq!(math::exp(&i64::zero()), float!());
}

#[test]
fun exp_of_one_matches_snapshot() {
    assert_eq!(math::exp(&i64::from_u64(float!())), EXP_1);
}

#[test]
fun exp_of_negative_one_matches_snapshot() {
    assert_eq!(math::exp(&i64::from_parts(float!(), true)), EXP_NEG_1);
}

#[test]
fun exp_of_two_matches_snapshot() {
    assert_eq!(math::exp(&i64::from_u64(2 * float!())), EXP_2);
}

#[test]
fun exp_of_negative_two_matches_snapshot() {
    assert_eq!(math::exp(&i64::from_parts(2 * float!(), true)), EXP_NEG_2);
}

#[test]
fun exp_of_ten_matches_snapshot() {
    // Exercises the shift-by-32 branch in `exp_u128`.
    assert_eq!(math::exp(&i64::from_u64(10 * float!())), EXP_10);
}

#[test]
fun exp_of_negative_ten_matches_snapshot() {
    assert_eq!(math::exp(&i64::from_parts(10 * float!(), true)), EXP_NEG_10);
}

// === normal_cdf ===

#[test]
fun normal_cdf_of_zero_is_half() {
    // Exact: at x=0 the small-range Horner term vanishes, leaving F/2.
    assert_eq!(math::normal_cdf(&i64::zero()), float!() / 2);
}

#[test]
fun normal_cdf_of_half_matches_snapshot() {
    // x=0.5 is below the small-range threshold (0.66291).
    assert_eq!(math::normal_cdf(&i64::from_u64(float!() / 2)), CDF_HALF);
}

#[test]
fun normal_cdf_of_negative_half_matches_snapshot() {
    assert_eq!(math::normal_cdf(&i64::from_parts(float!() / 2, true)), CDF_NEG_HALF);
}

#[test]
fun normal_cdf_of_one_matches_snapshot() {
    // x=1 is above the small-range threshold, exercising the medium-range branch.
    assert_eq!(math::normal_cdf(&i64::from_u64(float!())), CDF_1);
}

#[test]
fun normal_cdf_of_negative_one_matches_snapshot() {
    assert_eq!(math::normal_cdf(&i64::from_parts(float!(), true)), CDF_NEG_1);
}

#[test]
fun normal_cdf_of_two_matches_snapshot() {
    assert_eq!(math::normal_cdf(&i64::from_u64(2 * float!())), CDF_2);
}

#[test]
fun normal_cdf_of_negative_two_matches_snapshot() {
    assert_eq!(math::normal_cdf(&i64::from_parts(2 * float!(), true)), CDF_NEG_2);
}

#[test]
fun normal_cdf_of_three_matches_snapshot() {
    assert_eq!(math::normal_cdf(&i64::from_u64(3 * float!())), CDF_3);
}

#[test]
fun normal_cdf_of_negative_three_matches_snapshot() {
    assert_eq!(math::normal_cdf(&i64::from_parts(3 * float!(), true)), CDF_NEG_3);
}

#[test]
fun normal_cdf_clamps_high_to_one() {
    // |x| > 8 short-circuits to F (1.0) for positive inputs.
    assert_eq!(math::normal_cdf(&i64::from_u64(8 * float!() + 1)), float!());
    assert_eq!(math::normal_cdf(&i64::from_u64(100 * float!())), float!());
}

#[test]
fun normal_cdf_clamps_low_to_zero() {
    // |x| > 8 short-circuits to 0 for negative inputs.
    assert_eq!(math::normal_cdf(&i64::from_parts(8 * float!() + 1, true)), 0);
    assert_eq!(math::normal_cdf(&i64::from_parts(100 * float!(), true)), 0);
}

// === sqrt ===

#[test]
fun sqrt_of_zero_is_zero() {
    assert_eq!(math::sqrt(0, float!()), 0);
}

#[test]
fun sqrt_of_one_is_one() {
    assert_eq!(math::sqrt(float!(), float!()), float!());
}

#[test]
fun sqrt_of_four_is_two() {
    assert_eq!(math::sqrt(4 * float!(), float!()), 2 * float!());
}

#[test]
fun sqrt_of_nine_is_three() {
    assert_eq!(math::sqrt(9 * float!(), float!()), 3 * float!());
}

#[test]
fun sqrt_of_twentyfive_is_five() {
    assert_eq!(math::sqrt(25 * float!(), float!()), 5 * float!());
}

#[test]
fun sqrt_of_two_matches_snapshot() {
    assert_eq!(math::sqrt(2 * float!(), float!()), SQRT_2);
}

#[test]
fun sqrt_of_three_matches_snapshot() {
    assert_eq!(math::sqrt(3 * float!(), float!()), SQRT_3);
}

#[test]
fun sqrt_of_half_matches_snapshot() {
    assert_eq!(math::sqrt(float!() / 2, float!()), SQRT_HALF);
}

#[test, expected_failure(abort_code = math::EInvalidPrecision)]
fun sqrt_precision_zero_aborts() {
    math::sqrt(1, 0);
    abort 999
}

#[test, expected_failure(abort_code = math::EInvalidPrecision)]
fun sqrt_precision_above_float_aborts() {
    math::sqrt(1, float!() + 1);
    abort 999
}

// === mul_div_round_down ===

#[test]
fun mul_div_round_down_truncates() {
    // 10 * 3 / 4 = 7.5 -> 7
    assert_eq!(math::mul_div_round_down(10, 3, 4), 7);
}

#[test]
fun mul_div_round_down_exact() {
    // 12 * 3 / 4 = 9 exactly
    assert_eq!(math::mul_div_round_down(12, 3, 4), 9);
}

#[test]
fun mul_div_round_down_zero_numerator() {
    assert_eq!(math::mul_div_round_down(0, 5, 7), 0);
    assert_eq!(math::mul_div_round_down(5, 0, 7), 0);
}

#[test]
fun mul_div_round_down_uses_u128_intermediate() {
    // a*b would overflow u64; u128 intermediate keeps the result exact.
    let big = std::u64::max_value!();
    assert_eq!(math::mul_div_round_down(big, big, big), big);
}

#[test, expected_failure(abort_code = math::EZeroDivisor)]
fun mul_div_round_down_zero_divisor_aborts() {
    math::mul_div_round_down(1, 1, 0);
    abort 999
}

// === mul_div_round_up ===

#[test]
fun mul_div_round_up_rounds_up_on_remainder() {
    // 10 * 3 / 4 = 7.5 -> 8
    assert_eq!(math::mul_div_round_up(10, 3, 4), 8);
}

#[test]
fun mul_div_round_up_exact_does_not_round() {
    // 12 * 3 / 4 = 9 exactly, no round-up.
    assert_eq!(math::mul_div_round_up(12, 3, 4), 9);
}

#[test]
fun mul_div_round_up_one_unit_remainder_rounds_to_one() {
    // 1 * 1 / 2 = 0.5 -> 1 (smallest possible rounded-up result).
    assert_eq!(math::mul_div_round_up(1, 1, 2), 1);
}

#[test]
fun mul_div_round_up_zero_numerator_stays_zero() {
    // 0 / c has remainder 0, so the up-round must not lift it to 1.
    assert_eq!(math::mul_div_round_up(0, 5, 7), 0);
    assert_eq!(math::mul_div_round_up(5, 0, 7), 0);
}

#[test, expected_failure(abort_code = math::EZeroDivisor)]
fun mul_div_round_up_zero_divisor_aborts() {
    math::mul_div_round_up(1, 1, 0);
    abort 999
}

// === pow10 ===

#[test]
fun pow10_zero_is_one() {
    assert_eq!(math::pow10(0), 1);
}

#[test]
fun pow10_one_is_ten() {
    assert_eq!(math::pow10(1), 10);
}

#[test]
fun pow10_nine_is_one_billion() {
    assert_eq!(math::pow10(9), 1_000_000_000);
}

#[test]
fun pow10_max_is_ten_to_the_eighteen() {
    // 18 is the largest exponent that fits in u64.
    assert_eq!(math::pow10(18), 1_000_000_000_000_000_000);
}

#[test, expected_failure(abort_code = math::EPow10ExponentTooLarge)]
fun pow10_nineteen_aborts() {
    math::pow10(19);
    abort 999
}
