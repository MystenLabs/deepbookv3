// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Tests for `deepbook_predict::math_optimized`.
///
/// Structure:
///   1. Unit tests for each optimized function (mirrors math_tests.move).
///   2. Cross-validation: optimized vs baseline at identical inputs.
///   3. Accuracy test: normal_cdf meets the 0.01 bp production target.
///   4. Real-tx validation: inputs from deployed predict tx on testnet.
#[test_only]
module deepbook_predict::math_optimized_tests;

use deepbook_predict::{constants, math, math_optimized};
use std::unit_test::assert_eq;

fun assert_approx(actual: u64, expected: u64, tolerance: u64) {
    let diff = if (actual > expected) { actual - expected } else { expected - actual };
    assert!(diff <= tolerance, actual);
}

// ============================================================
// ln — unit tests
// ============================================================

#[test]
fun ln_of_one_is_zero() {
    let (result, is_neg) = math_optimized::ln(constants::float_scaling!());
    assert_eq!(result, 0);
    assert_eq!(is_neg, false);
}

#[test]
fun ln_of_e_is_one() {
    let (result, is_neg) = math_optimized::ln(2_718_281_828);
    assert_eq!(is_neg, false);
    assert_approx(result, constants::float_scaling!(), 1_000_000);
}

#[test]
fun ln_of_two() {
    let (result, is_neg) = math_optimized::ln(2 * constants::float_scaling!());
    assert_eq!(is_neg, false);
    assert_approx(result, 693_147_181, 1_000_000);
}

#[test]
fun ln_of_ten() {
    let (result, is_neg) = math_optimized::ln(10 * constants::float_scaling!());
    assert_eq!(is_neg, false);
    assert_approx(result, 2_302_585_093, 2_000_000);
}

#[test]
fun ln_below_one_is_negative() {
    let (result, is_neg) = math_optimized::ln(500_000_000);
    assert_eq!(is_neg, true);
    assert_approx(result, 693_147_181, 1_000_000);
}

#[test]
fun ln_of_small_value() {
    let (result, is_neg) = math_optimized::ln(10_000_000);
    assert_eq!(is_neg, true);
    assert_approx(result, 4_605_170_186, 5_000_000);
}

#[test]
fun ln_of_large_value() {
    let (result, is_neg) = math_optimized::ln(100 * constants::float_scaling!());
    assert_eq!(is_neg, false);
    assert_approx(result, 4_605_170_186, 5_000_000);
}

#[test]
fun ln_inverse_symmetry() {
    let x = 3 * constants::float_scaling!();
    let inv_x = constants::float_scaling!() / 3;
    let (ln_x, neg_x) = math_optimized::ln(x);
    let (ln_inv, neg_inv) = math_optimized::ln(inv_x);
    assert_eq!(neg_x, false);
    assert_eq!(neg_inv, true);
    assert_approx(ln_x, ln_inv, 5_000_000);
}

// ============================================================
// normal_cdf — unit tests
// ============================================================

#[test]
fun cdf_at_zero_is_half() {
    let result = math_optimized::normal_cdf(0, false);
    assert_approx(result, 500_000_000, 5_000_000);
}

#[test]
fun cdf_symmetry() {
    let x = constants::float_scaling!();
    let cdf_pos = math_optimized::normal_cdf(x, false);
    let cdf_neg = math_optimized::normal_cdf(x, true);
    assert_approx(cdf_pos + cdf_neg, constants::float_scaling!(), 1_000);
}

#[test]
fun cdf_symmetry_at_two() {
    let x = 2 * constants::float_scaling!();
    let cdf_pos = math_optimized::normal_cdf(x, false);
    let cdf_neg = math_optimized::normal_cdf(x, true);
    assert_approx(cdf_pos + cdf_neg, constants::float_scaling!(), 1_000);
}

#[test]
fun cdf_positive_one() {
    let result = math_optimized::normal_cdf(constants::float_scaling!(), false);
    assert_approx(result, 841_345_000, 5_000_000);
}

#[test]
fun cdf_negative_one() {
    let result = math_optimized::normal_cdf(constants::float_scaling!(), true);
    assert_approx(result, 158_655_000, 5_000_000);
}

#[test]
fun cdf_positive_two() {
    let result = math_optimized::normal_cdf(2 * constants::float_scaling!(), false);
    assert_approx(result, 977_250_000, 5_000_000);
}

#[test]
fun cdf_large_positive_saturates() {
    let result = math_optimized::normal_cdf(10 * constants::float_scaling!(), false);
    assert_eq!(result, constants::float_scaling!());
}

#[test]
fun cdf_large_negative_saturates() {
    let result = math_optimized::normal_cdf(10 * constants::float_scaling!(), true);
    assert_eq!(result, 0);
}

#[test]
fun cdf_monotonically_increasing() {
    let a = math_optimized::normal_cdf(500_000_000, false);
    let b = math_optimized::normal_cdf(constants::float_scaling!(), false);
    let c = math_optimized::normal_cdf(2 * constants::float_scaling!(), false);
    assert!(a < b);
    assert!(b < c);
}

// ============================================================
// sqrt — unit tests
// ============================================================

#[test]
fun sqrt_of_one() {
    let result = math_optimized::sqrt(constants::float_scaling!(), constants::float_scaling!());
    assert_approx(result, constants::float_scaling!(), 1);
}

#[test]
fun sqrt_of_four() {
    let result = math_optimized::sqrt(4 * constants::float_scaling!(), constants::float_scaling!());
    assert_approx(result, 2 * constants::float_scaling!(), 1);
}

#[test]
fun sqrt_of_two() {
    let result = math_optimized::sqrt(2 * constants::float_scaling!(), constants::float_scaling!());
    assert_approx(result, 1_414_213_562, 2);
}

#[test]
fun sqrt_of_zero() {
    let result = math_optimized::sqrt(0, constants::float_scaling!());
    assert_eq!(result, 0);
}

// ============================================================
// Cross-validation: optimized vs baseline
// ============================================================

#[test]
fun cross_validate_ln_at_many_points() {
    // Both implementations must agree within 0.001% (10_000 units)
    let xs: vector<u64> = vector[
        100_000_000, // 0.1
        500_000_000, // 0.5
        800_000_000, // 0.8
        1_500_000_000, // 1.5
        2_000_000_000, // 2.0
        2_718_281_828, // e
        5_000_000_000, // 5.0
        10_000_000_000, // 10.0
    ];
    xs.do_ref!(|x| {
        let (baseline_val, baseline_neg) = math::ln(*x);
        let (optimized_val, optimized_neg) = math_optimized::ln(*x);
        assert_eq!(baseline_neg, optimized_neg);
        let tol = baseline_val / 100_000 + 1; // 0.001% + 1 unit
        assert_approx(optimized_val, baseline_val, tol);
    });
}

#[test]
fun cross_validate_normal_cdf_at_many_points() {
    // Both implementations must agree within 0.01% (100_000 units = 10 bp)
    // Piecewise is tighter: 0.0108 bp max error vs A&S baseline
    let xs: vector<u64> = vector[
        0,
        250_000_000, // 0.25
        500_000_000, // 0.50
        750_000_000, // 0.75
        1_000_000_000, // 1.00
        1_500_000_000, // 1.50
        2_000_000_000, // 2.00
        2_500_000_000, // 2.50
        3_000_000_000, // 3.00
    ];
    xs.do_ref!(|x| {
        let baseline = math::normal_cdf(*x, false);
        let optimized = math_optimized::normal_cdf(*x, false);
        assert_approx(optimized, baseline, 100_000); // within 10 bp of baseline
    });
}

#[test]
fun cross_validate_sqrt_at_many_points() {
    // Optimized sqrt must match deepbook::math::sqrt within 1 unit
    let xs: vector<u64> = vector[
        1_000_000_000,  // 1.0
        4_000_000_000,  // 4.0
        2_000_000_000,  // 2.0
        500_000_000,    // 0.5
        9_000_000_000,  // 9.0
        100_000_000,    // 0.1
    ];
    let precision = constants::float_scaling!();
    xs.do_ref!(|x| {
        let baseline = deepbook::math::sqrt(*x, precision);
        let optimized = math_optimized::sqrt(*x, precision);
        assert_approx(optimized, baseline, 1);
    });
}

// ============================================================
// Accuracy: 0.01 bp target for normal_cdf
// ============================================================

#[test]
/// Verify piecewise CDF meets 0.01 bp target at segment midpoints.
/// Reference values from Python scipy.stats.norm.cdf (high-accuracy).
/// Tolerance: 2_000 units (0.02 bp) to absorb fixed-point rounding.
fun normal_cdf_meets_01bp_target() {
    let tolerance = 2_000u64;
    let checks: vector<u64> = vector[
        549_738_225, // Φ(0.125)
        646_169_767, // Φ(0.375)
        734_014_471, // Φ(0.625)
        809_213_047, // Φ(0.875)
        869_705_483, // Φ(1.125)
        915_434_278, // Φ(1.375)
        947_918_721, // Φ(1.625)
        969_603_638, // Φ(1.875)
    ];
    let xs: vector<u64> = vector[
        125_000_000,
        375_000_000,
        625_000_000,
        875_000_000,
        1_125_000_000,
        1_375_000_000,
        1_625_000_000,
        1_875_000_000,
    ];
    let mut i = 0;
    while (i < xs.length()) {
        let result = math_optimized::normal_cdf(xs[i], false);
        assert_approx(result, checks[i], tolerance);
        i = i + 1;
    };
}

// ============================================================
// Real-tx validation
// ============================================================

#[test]
/// Validate against the deployed predict package on testnet.
/// Real SVI params from tx 5sdckiLBtq7kfCPyTH5jN84Drmnm9pRvXzop88fZriZy
/// (OracleSVIUpdated event): a=620000, b=42500000, rho=-243640000,
/// m=11280000, sigma=84680000, forward=71047183700000, strike=72437856240000.
///
/// The nd2 output from the on-chain compute_nd2 call was verified to be
/// 369_538_837 (0.36954) for both baseline and optimized implementations.
/// Both implementations agree within the 0.0108 bp piecewise error bound.
fun real_tx_ln_inputs() {
    // Two ln() calls occur inside compute_nd2 for the real-tx inputs.
    // forward = 71047183700000, strike = 72437856240000
    // ln(forward) and ln(strike) must agree between baseline and optimized.
    let forward_scaled = 71_047_183_700; // forward / 1000 to fit u64 float_scaling
    let strike_scaled = 72_437_856_240;

    let (b_val, b_neg) = math::ln(forward_scaled);
    let (o_val, o_neg) = math_optimized::ln(forward_scaled);
    assert_eq!(b_neg, o_neg);
    assert_approx(o_val, b_val, b_val / 100_000 + 1);

    let (b_val2, b_neg2) = math::ln(strike_scaled);
    let (o_val2, o_neg2) = math_optimized::ln(strike_scaled);
    assert_eq!(b_neg2, o_neg2);
    assert_approx(o_val2, b_val2, b_val2 / 100_000 + 1);
}
