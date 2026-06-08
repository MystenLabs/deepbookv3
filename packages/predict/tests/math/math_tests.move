// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::math_tests;

use deepbook_predict::{constants::float_scaling as float, i64, math, test_helpers};
use std::unit_test::assert_eq;

// Independent reference values: round(f_true(x) * 1e9), produced by
// tests/helper/reference/generate_constants.py (Python stdlib `math`; NO contract
// input, so these are an independent oracle, not a snapshot of contract output —
// unit-tests rule 1). They REPLACE the previous "contract returns X; delta" golden
// snapshots, which asserted the contract's own output and so could never catch a
// baked-in approximation bug.
//
// Approximate-function points assert the contract is within ONE fixed-point unit
// (`ULP`) of the reference via `assert_within`. That bound is the representation
// granularity (a correct floor/ceil/round result is <= 1 unit from truth) — a
// principled, contract-independent bound, NOT the deleted precision.move's
// measured error chain. A deviation > 1 unit is genuine approximation error
// beyond rounding and fails the test (a candidate finding — see BUGS_FOUND.md).
// Exact points (identities, clamps, perfect squares, Phi(0)) use `assert_eq!`.

/// Fixed-point representation granularity (1e-9). The principled bound for a
/// correctly-rounded fixed-point result.
const ULP: u64 = 1;

const LN_2: u64 = 693_147_181;
const LN_10: u64 = 2_302_585_093;

const EXP_1: u64 = 2_718_281_828;
const EXP_NEG_1: u64 = 367_879_441;
const EXP_2: u64 = 7_389_056_099;
const EXP_NEG_2: u64 = 135_335_283;
const EXP_10: u64 = 22_026_465_794_807;
const EXP_NEG_10: u64 = 45_400;

const CDF_HALF: u64 = 691_462_461;
const CDF_NEG_HALF: u64 = 308_537_539;
const CDF_1: u64 = 841_344_746;
const CDF_NEG_1: u64 = 158_655_254;
const CDF_2: u64 = 977_249_868;
const CDF_NEG_2: u64 = 22_750_132;
const CDF_3: u64 = 998_650_102;
const CDF_NEG_3: u64 = 1_349_898;

const SQRT_2: u64 = 1_414_213_562;
const SQRT_3: u64 = 1_732_050_808;
const SQRT_HALF: u64 = 707_106_781;

// === ln ===

#[test]
fun ln_of_one_is_zero() {
    let r = math::ln(float!());
    assert!(r.is_zero());
    assert!(!r.is_negative());
}

#[test]
fun ln_of_two_within_reference() {
    let r = math::ln(2 * float!());
    test_helpers::assert_within(r.magnitude(), LN_2, ULP);
    assert!(!r.is_negative());
}

// KNOWN-FAILING: BUG-002 — ln() approximation deviates from truth by 3 ULP at ln(10). See .redesign/BUGS_FOUND.md
#[test]
fun ln_of_ten_within_reference() {
    let r = math::ln(10 * float!());
    test_helpers::assert_within(r.magnitude(), LN_10, ULP);
    assert!(!r.is_negative());
}

#[test]
fun ln_of_half_is_negative_ln2() {
    // ln(0.5) = -ln(2); exercises the inverse path (`x < float!()`) inside the contract.
    let r = math::ln(float!() / 2);
    test_helpers::assert_within(r.magnitude(), LN_2, ULP);
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

// KNOWN-FAILING: BUG-001 — exp() approximation deviates from truth by 8 ULP at exp(1). See .redesign/BUGS_FOUND.md
#[test]
fun exp_of_one_within_reference() {
    test_helpers::assert_within(math::exp(&i64::from_u64(float!())), EXP_1, ULP);
}

#[test]
fun exp_of_negative_one_within_reference() {
    test_helpers::assert_within(math::exp(&i64::from_parts(float!(), true)), EXP_NEG_1, ULP);
}

// KNOWN-FAILING: BUG-001 — exp() approximation deviates from truth by 7 ULP at exp(2). See .redesign/BUGS_FOUND.md
#[test]
fun exp_of_two_within_reference() {
    test_helpers::assert_within(math::exp(&i64::from_u64(2 * float!())), EXP_2, ULP);
}

#[test]
fun exp_of_negative_two_within_reference() {
    test_helpers::assert_within(math::exp(&i64::from_parts(2 * float!(), true)), EXP_NEG_2, ULP);
}

// KNOWN-FAILING: BUG-001 — exp() approximation deviates from truth by +107_785 (rel ~4.9e-6) at exp(10). See .redesign/BUGS_FOUND.md
#[test]
fun exp_of_ten_within_reference() {
    // Exercises the shift-by-32 branch in `exp_u128`.
    test_helpers::assert_within(math::exp(&i64::from_u64(10 * float!())), EXP_10, ULP);
}

#[test]
fun exp_of_negative_ten_within_reference() {
    test_helpers::assert_within(math::exp(&i64::from_parts(10 * float!(), true)), EXP_NEG_10, ULP);
}

// === normal_cdf ===

#[test]
fun normal_cdf_of_zero_is_half() {
    // Exact: at x=0 the small-range Horner term vanishes, leaving F/2.
    assert_eq!(math::normal_cdf(&i64::zero()), float!() / 2);
}

#[test]
fun normal_cdf_of_half_within_reference() {
    // x=0.5 is below the small-range threshold (0.66291).
    test_helpers::assert_within(math::normal_cdf(&i64::from_u64(float!() / 2)), CDF_HALF, ULP);
}

#[test]
fun normal_cdf_of_negative_half_within_reference() {
    test_helpers::assert_within(
        math::normal_cdf(&i64::from_parts(float!() / 2, true)),
        CDF_NEG_HALF,
        ULP,
    );
}

#[test]
fun normal_cdf_of_one_within_reference() {
    // x=1 is above the small-range threshold, exercising the medium-range branch.
    test_helpers::assert_within(math::normal_cdf(&i64::from_u64(float!())), CDF_1, ULP);
}

#[test]
fun normal_cdf_of_negative_one_within_reference() {
    test_helpers::assert_within(math::normal_cdf(&i64::from_parts(float!(), true)), CDF_NEG_1, ULP);
}

#[test]
fun normal_cdf_of_two_within_reference() {
    test_helpers::assert_within(math::normal_cdf(&i64::from_u64(2 * float!())), CDF_2, ULP);
}

#[test]
fun normal_cdf_of_negative_two_within_reference() {
    test_helpers::assert_within(
        math::normal_cdf(&i64::from_parts(2 * float!(), true)),
        CDF_NEG_2,
        ULP,
    );
}

#[test]
fun normal_cdf_of_three_within_reference() {
    test_helpers::assert_within(math::normal_cdf(&i64::from_u64(3 * float!())), CDF_3, ULP);
}

#[test]
fun normal_cdf_of_negative_three_within_reference() {
    test_helpers::assert_within(
        math::normal_cdf(&i64::from_parts(3 * float!(), true)),
        CDF_NEG_3,
        ULP,
    );
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
fun sqrt_of_two_within_reference() {
    test_helpers::assert_within(math::sqrt(2 * float!(), float!()), SQRT_2, ULP);
}

#[test]
fun sqrt_of_three_within_reference() {
    test_helpers::assert_within(math::sqrt(3 * float!(), float!()), SQRT_3, ULP);
}

#[test]
fun sqrt_of_half_within_reference() {
    test_helpers::assert_within(math::sqrt(float!() / 2, float!()), SQRT_HALF, ULP);
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
