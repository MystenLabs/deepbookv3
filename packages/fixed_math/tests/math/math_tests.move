// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module fixed_math::math_tests;

use fixed_math::{i64, math::{Self, float_scaling as float}, test_helpers};
use std::unit_test::assert_eq;

// Independent reference values: round(f_true(x) * 1e9), produced by
// tests/helper/reference/generate_constants.py (Python stdlib `math`; NO contract
// input, so these are an independent oracle, not a snapshot of contract output —
// unit-tests rule 1).
//
// Approximate-function points assert the contract is within its documented
// PRECISION BUDGET (math.move "Precision contract") — a per-primitive bound
// derived from downstream pricing sensitivity, NOT measured from contract output:
//   - exp, ln:    relative, 1e-7 (magnitude-scaled) via `assert_within_relative`.
//   - normal_cdf: absolute, 20 units @1e9 (2e-8) via `assert_within`.
//   - sqrt:       absolute, 1 ULP (integer floor-sqrt is near-exact).
// A deviation beyond budget is a genuine finding (see BUGS_FOUND.md). Exact
// points (identities, clamps, perfect squares, Phi(0)) use `assert_eq!`.

// Per-primitive precision budgets — the contract documented in math.move.
// Derived from downstream pricing sensitivity, never from contract output.
const EXP_BUDGET_REL: u64 = 100; // 1e-7 relative (parts per FLOAT_SCALING)
const LN_BUDGET_REL: u64 = 100; // 1e-7 relative (parts per FLOAT_SCALING)
const CDF_BUDGET_ABS: u64 = 20; // 2e-8 of full scale; Cody rational truncation
const SQRT_BUDGET_ABS: u64 = 1; // 1 ULP; integer floor-sqrt

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

// Edge / boundary references (completeness audit) — same independent oracle.
const EXP_20: u64 = 485_165_195_409_790_278; // Decimal-exact (> 2^53)
const EXP_AT_U64_FIT_BOUND: u64 = 18_446_742_212_616_000_662; // e^(EXP_MAX_INPUT/1e9)*1e9, Decimal-exact
const EXP_HALF: u64 = 1_648_721_271; // e^0.5; exercises the n=0 (x < ln2) series-only path
const CDF_066291: u64 = 746_305_902; // Phi at the small/medium split
const CDF_SQRT32: u64 = 999_999_992; // Phi at the medium/clamp split (sqrt(32))
const CDF_4: u64 = 999_968_329;
const CDF_5: u64 = 999_999_713;
const LN_1EM9_MAG: u64 = 20_723_265_837; // |ln(1e-9)|; smallest input x = 1
const LN_U64MAX: u64 = 23_638_153_719; // ln(u64::MAX / 1e9)
const LN_1_5: u64 = 405_465_108; // ln(1.5); x in (F, 2F): non-degenerate Horner series
const SQRT_4F_PREC_ONE: u64 = 63_245; // sqrt(4*F, 1) = isqrt(4e9)
const SQRT_U64MAX_PREC_ONE: u64 = 4_294_967_295; // sqrt(u64::MAX, 1) = isqrt(u64::MAX) = 2^32-1

// Input boundaries mirrored from math.move private constants (for branch-edge tests).
const EXP_MAX_INPUT: u64 = 23_638_153_618; // = math::EXP_MAX_INPUT (budget-conservative u64-fit bound)
const CDF_SMALL_THRESHOLD: u64 = 662_910_000; // small/medium split in normal_cdf
const CDF_MEDIUM_THRESHOLD: u64 = 5_656_854_249; // medium/clamp split = sqrt(32) * 1e9

// === Fixed-Point Helpers ===

#[test]
fun mul_floors_scaled_product() {
    // 1.5 * 2.25 = 3.375
    assert_eq!(math::mul(float!() + float!() / 2, 2 * float!() + float!() / 4), 3_375_000_000);
}

#[test]
fun mul_rounds_down_to_integer_unit() {
    // floor(1 * 1 / 1e9) = 0
    assert_eq!(math::mul(1, 1), 0);
}

#[test]
fun div_floors_scaled_quotient() {
    // floor(5 / 2 * 1e9) = 2.5e9
    assert_eq!(math::div(5 * float!(), 2 * float!()), 2_500_000_000);
}

#[test]
fun div_rounds_down_to_integer_unit() {
    // floor(1 * 1e9 / 3) = 333_333_333
    assert_eq!(math::div(1, 3), 333_333_333);
}

#[test]
fun mul_div_down_floors_raw_integer_ratio() {
    // floor(10 * 10 / 6) = 16
    assert_eq!(math::mul_div_down(10, 10, 6), 16);
}

#[test]
fun mul_div_down_uses_u128_intermediate() {
    // floor(10_000_000_000 * 10_000_000_000 / 10_000_000_000) = 10_000_000_000.
    // The product is 1e20, above u64::MAX, so the helper must widen before multiplying.
    assert_eq!(math::mul_div_down(10_000_000_000, 10_000_000_000, 10_000_000_000), 10_000_000_000);
}

#[test]
fun mul_div_up_ceils_raw_integer_ratio() {
    // ceil(10 * 10 / 6) = ceil(16.666...) = 17 (mul_div_down gives 16).
    assert_eq!(math::mul_div_up(10, 10, 6), 17);
}

#[test]
fun mul_div_up_exact_division_does_not_round() {
    // 10 * 10 / 5 = 20 exactly; a spurious +1 would wrongly return 21.
    assert_eq!(math::mul_div_up(10, 10, 5), 20);
}

#[test]
fun mul_div_up_rounds_smallest_remainder_up() {
    // ceil(1 * 1 / 2) = ceil(0.5) = 1: the boundary where 1 unit matters.
    assert_eq!(math::mul_div_up(1, 1, 2), 1);
}

#[test]
fun mul_div_up_of_zero_is_zero() {
    // ceil(0 / 6) = 0: a zero numerator never rounds up to 1.
    assert_eq!(math::mul_div_up(0, 1_000_000_000, 6), 0);
}

#[test]
fun mul_div_up_at_float_scaling_rounds_dust_up() {
    // ceil(1 * 1 / 1e9) = 1: the live-redeem floor deduction. `mul(1, 1)` rounds
    // this same sub-unit dust DOWN to 0, so the round-up form is what biases the
    // deduction toward the pool.
    assert_eq!(math::mul_div_up(1, 1, float!()), 1);
    assert_eq!(math::mul(1, 1), 0);
}

#[test]
fun mul_div_up_uses_u128_intermediate() {
    // ceil(10_000_000_000 * 10_000_000_000 / 10_000_000_000) = 10_000_000_000.
    // The product is 1e20, above u64::MAX, so the helper must widen before multiplying.
    assert_eq!(math::mul_div_up(10_000_000_000, 10_000_000_000, 10_000_000_000), 10_000_000_000);
}

#[test, expected_failure(abort_code = math::EInputZero)]
fun mul_div_up_zero_denominator_aborts() {
    math::mul_div_up(10, 10, 0);
    abort 999
}

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
    test_helpers::assert_within_relative(r.magnitude(), LN_2, LN_BUDGET_REL);
    assert!(!r.is_negative());
}

#[test]
fun ln_of_ten_within_reference() {
    let r = math::ln(10 * float!());
    test_helpers::assert_within_relative(r.magnitude(), LN_10, LN_BUDGET_REL);
    assert!(!r.is_negative());
}

#[test]
fun ln_of_half_is_negative_ln2() {
    // ln(0.5) = -ln(2); exercises the inverse path (`x < float!()`) inside the contract.
    let r = math::ln(float!() / 2);
    test_helpers::assert_within_relative(r.magnitude(), LN_2, LN_BUDGET_REL);
    assert!(r.is_negative());
}

#[test]
fun ln_of_smallest_input_is_large_negative() {
    // x = 1 (value 1e-9): the maximal reciprocal (inv = 1e18) on the inverse path.
    let r = math::ln(1);
    test_helpers::assert_within_relative(r.magnitude(), LN_1EM9_MAG, LN_BUDGET_REL);
    assert!(r.is_negative());
}

#[test]
fun ln_of_u64_max_within_reference() {
    // Largest input: exercises normalize's high shift count.
    let r = math::ln(std::u64::max_value!());
    test_helpers::assert_within_relative(r.magnitude(), LN_U64MAX, LN_BUDGET_REL);
    assert!(!r.is_negative());
}

#[test]
fun ln_just_below_one_is_near_zero() {
    // The inverse/direct split boundary. True ln(1 - 1e-9) ~ -1e-9, within 1 ULP of
    // zero, so only the magnitude (not the sign) is resolvable at this granularity.
    assert!(math::ln(float!() - 1).magnitude() <= 1);
}

#[test]
fun ln_just_above_one_is_near_zero() {
    assert!(math::ln(float!() + 1).magnitude() <= 1);
}

#[test]
fun ln_of_one_point_five_within_reference() {
    // x in (F, 2F): the normalize n=0 case where the z^k Horner series actually runs
    // (unlike F+1, where z rounds to 0 and the series is degenerate).
    let r = math::ln(float!() + float!() / 2);
    test_helpers::assert_within_relative(r.magnitude(), LN_1_5, LN_BUDGET_REL);
    assert!(!r.is_negative());
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
fun exp_of_one_within_reference() {
    test_helpers::assert_within_relative(
        math::exp(&i64::from_u64(float!())),
        EXP_1,
        EXP_BUDGET_REL,
    );
}

#[test]
fun exp_of_negative_one_within_reference() {
    test_helpers::assert_within_relative(
        math::exp(&i64::from_parts(float!(), true)),
        EXP_NEG_1,
        EXP_BUDGET_REL,
    );
}

#[test]
fun exp_of_two_within_reference() {
    test_helpers::assert_within_relative(
        math::exp(&i64::from_u64(2 * float!())),
        EXP_2,
        EXP_BUDGET_REL,
    );
}

#[test]
fun exp_of_negative_two_within_reference() {
    test_helpers::assert_within_relative(
        math::exp(&i64::from_parts(2 * float!(), true)),
        EXP_NEG_2,
        EXP_BUDGET_REL,
    );
}

#[test]
fun exp_of_ten_within_reference() {
    // Large-magnitude point: the absolute error (~107k units) is ~4.9e-9 relative,
    // within the 1e-7 budget. exp's large-positive path is unused by pricing.
    test_helpers::assert_within_relative(
        math::exp(&i64::from_u64(10 * float!())),
        EXP_10,
        EXP_BUDGET_REL,
    );
}

#[test]
fun exp_of_negative_ten_within_reference() {
    test_helpers::assert_within_relative(
        math::exp(&i64::from_parts(10 * float!(), true)),
        EXP_NEG_10,
        EXP_BUDGET_REL,
    );
}

#[test, expected_failure(abort_code = math::EExpOverflow)]
fun exp_above_u64_fit_bound_aborts() {
    // e^24 * 1e9 exceeds u64::MAX; positive inputs past the u64-fit bound abort
    // rather than silently wrapping in the `<<` reduction.
    math::exp(&i64::from_u64(24 * float!()));
    abort 999
}

#[test]
fun exp_large_negative_does_not_overflow() {
    // The overflow guard is one-sided: e^-x < 1 for x past the bound, rounding to 0.
    assert_eq!(math::exp(&i64::from_parts(24 * float!(), true)), 0);
}

#[test]
fun exp_of_twenty_within_reference() {
    // Large but safely-valid positive arg (e^20 * 1e9 < u64::MAX).
    test_helpers::assert_within_relative(
        math::exp(&i64::from_u64(20 * float!())),
        EXP_20,
        EXP_BUDGET_REL,
    );
}

#[test]
fun exp_at_u64_fit_bound_returns_within_reference() {
    // The exact guard boundary: e^x * 1e9 just fits u64, so this must NOT abort.
    // If it cast-aborts instead, EXP_MAX_INPUT is set a hair too loose.
    test_helpers::assert_within_relative(
        math::exp(&i64::from_u64(EXP_MAX_INPUT)),
        EXP_AT_U64_FIT_BOUND,
        EXP_BUDGET_REL,
    );
}

#[test, expected_failure(abort_code = math::EExpOverflow)]
fun exp_just_above_u64_fit_bound_aborts() {
    // One past the bound: the named guard rejects it, before any cast overflow.
    math::exp(&i64::from_u64(EXP_MAX_INPUT + 1));
    abort 999
}

#[test]
fun exp_of_half_uses_series_only() {
    // x = 0.5 < ln2, so n = 0: pure Taylor series, no binary shift.
    test_helpers::assert_within_relative(
        math::exp(&i64::from_u64(float!() / 2)),
        EXP_HALF,
        EXP_BUDGET_REL,
    );
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
    test_helpers::assert_within(
        math::normal_cdf(&i64::from_u64(float!() / 2)),
        CDF_HALF,
        CDF_BUDGET_ABS,
    );
}

#[test]
fun normal_cdf_of_negative_half_within_reference() {
    test_helpers::assert_within(
        math::normal_cdf(&i64::from_parts(float!() / 2, true)),
        CDF_NEG_HALF,
        CDF_BUDGET_ABS,
    );
}

#[test]
fun normal_cdf_of_one_within_reference() {
    // x=1 is above the small-range threshold, exercising the medium-range branch.
    test_helpers::assert_within(math::normal_cdf(&i64::from_u64(float!())), CDF_1, CDF_BUDGET_ABS);
}

#[test]
fun normal_cdf_of_negative_one_within_reference() {
    test_helpers::assert_within(
        math::normal_cdf(&i64::from_parts(float!(), true)),
        CDF_NEG_1,
        CDF_BUDGET_ABS,
    );
}

#[test]
fun normal_cdf_of_two_within_reference() {
    test_helpers::assert_within(
        math::normal_cdf(&i64::from_u64(2 * float!())),
        CDF_2,
        CDF_BUDGET_ABS,
    );
}

#[test]
fun normal_cdf_of_negative_two_within_reference() {
    test_helpers::assert_within(
        math::normal_cdf(&i64::from_parts(2 * float!(), true)),
        CDF_NEG_2,
        CDF_BUDGET_ABS,
    );
}

#[test]
fun normal_cdf_of_three_within_reference() {
    test_helpers::assert_within(
        math::normal_cdf(&i64::from_u64(3 * float!())),
        CDF_3,
        CDF_BUDGET_ABS,
    );
}

#[test]
fun normal_cdf_of_negative_three_within_reference() {
    test_helpers::assert_within(
        math::normal_cdf(&i64::from_parts(3 * float!(), true)),
        CDF_NEG_3,
        CDF_BUDGET_ABS,
    );
}

#[test]
fun normal_cdf_at_small_medium_threshold() {
    // x = SMALL_THRESHOLD (0.66291): the small/medium branch split, medium side.
    test_helpers::assert_within(
        math::normal_cdf(&i64::from_u64(CDF_SMALL_THRESHOLD)),
        CDF_066291,
        CDF_BUDGET_ABS,
    );
}

#[test]
fun normal_cdf_just_below_small_threshold() {
    // Small side of the split — continuity across the branch (within budget of ST).
    test_helpers::assert_within(
        math::normal_cdf(&i64::from_u64(CDF_SMALL_THRESHOLD - 1)),
        CDF_066291,
        CDF_BUDGET_ABS,
    );
}

#[test]
fun normal_cdf_at_medium_threshold_clamps_within_budget() {
    // x >= MEDIUM_THRESHOLD (sqrt(32)) clamps to F; true Phi = CDF_SQRT32, so the
    // clamp must stay within the cdf budget of truth (no out-of-budget discontinuity).
    let v = math::normal_cdf(&i64::from_u64(CDF_MEDIUM_THRESHOLD));
    assert_eq!(v, float!());
    test_helpers::assert_within(v, CDF_SQRT32, CDF_BUDGET_ABS);
}

#[test]
fun normal_cdf_just_below_medium_threshold() {
    // Medium side at its extreme: exp(-x^2/2) with x near sqrt(32).
    test_helpers::assert_within(
        math::normal_cdf(&i64::from_u64(CDF_MEDIUM_THRESHOLD - 1)),
        CDF_SQRT32,
        CDF_BUDGET_ABS,
    );
}

#[test]
fun normal_cdf_of_four_within_reference() {
    test_helpers::assert_within(
        math::normal_cdf(&i64::from_u64(4 * float!())),
        CDF_4,
        CDF_BUDGET_ABS,
    );
}

#[test]
fun normal_cdf_of_five_within_reference() {
    test_helpers::assert_within(
        math::normal_cdf(&i64::from_u64(5 * float!())),
        CDF_5,
        CDF_BUDGET_ABS,
    );
}

#[test]
fun normal_cdf_large_negative_clamps_to_zero() {
    // x in [sqrt(32), 8] negative: the internal large-range clamp (return 0), distinct
    // from the public |x|>8 short-circuit. True Phi(-6) ~ 1e-9, within budget of 0.
    assert_eq!(math::normal_cdf(&i64::from_parts(6 * float!(), true)), 0);
}

#[test]
fun normal_cdf_at_eight_boundary() {
    // x_mag == 8F exactly: the public `> 8F` guard is strict, so this falls through
    // to the internal large-range clamp (F for +, 0 for -). Pins the off-by-one edge.
    assert_eq!(math::normal_cdf(&i64::from_u64(8 * float!())), float!());
    assert_eq!(math::normal_cdf(&i64::from_parts(8 * float!(), true)), 0);
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
    test_helpers::assert_within(math::sqrt(2 * float!(), float!()), SQRT_2, SQRT_BUDGET_ABS);
}

#[test]
fun sqrt_of_three_within_reference() {
    test_helpers::assert_within(math::sqrt(3 * float!(), float!()), SQRT_3, SQRT_BUDGET_ABS);
}

#[test]
fun sqrt_of_half_within_reference() {
    test_helpers::assert_within(math::sqrt(float!() / 2, float!()), SQRT_HALF, SQRT_BUDGET_ABS);
}

// `precision` < F (multiplier > 1) is never used in production (all callers pass
// float_scaling), but it is public surface: sqrt(x, P) computes sqrt(x * P) raw.

#[test]
fun sqrt_with_half_precision() {
    // precision = F/2: sqrt(4 * 0.5) = sqrt(2). Independent: isqrt(4e9 * 5e8).
    test_helpers::assert_within(math::sqrt(4 * float!(), float!() / 2), SQRT_2, SQRT_BUDGET_ABS);
}

#[test]
fun sqrt_with_half_precision_perfect_square() {
    // sqrt(2 * 0.5) = sqrt(1) = 1 exactly.
    assert_eq!(math::sqrt(2 * float!(), float!() / 2), float!());
}

#[test]
fun sqrt_with_quarter_precision_perfect_square() {
    // sqrt(1 * 0.25) = sqrt(0.25) = 0.5 exactly.
    assert_eq!(math::sqrt(float!(), float!() / 4), float!() / 2);
}

#[test]
fun sqrt_with_min_precision() {
    // precision = 1 (max multiplier): sqrt(4F, 1) = isqrt(4e9) = 63_245.
    test_helpers::assert_within(math::sqrt(4 * float!(), 1), SQRT_4F_PREC_ONE, SQRT_BUDGET_ABS);
}

#[test]
fun sqrt_of_u64_max_min_precision() {
    // Largest input at max multiplier: scaled ~ 2^123 bits, the high-bit Newton path.
    // sqrt(u64::MAX, 1) = isqrt(u64::MAX) = 2^32 - 1.
    test_helpers::assert_within(
        math::sqrt(std::u64::max_value!(), 1),
        SQRT_U64MAX_PREC_ONE,
        SQRT_BUDGET_ABS,
    );
}

// Note: sqrt_u128's `x < 4` fast-path and its `g*g > x` floor correction are private
// and unreachable through the public *F-scaled wrapper (scaled is always 0 or a
// multiple of 1e9 >= 1e9, on which the Newton iteration never overshoots), so they
// have no public test by construction — defensive code for the raw u128 helper.

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
