// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Generated vector tests — validates math functions against scipy ground truth.
/// For hand-written property tests, see math_tests.move.
#[test_only]
module deepbook_predict::math_generated_tests;

use deepbook_predict::{generated_math as gs, math, precision};
use std::unit_test::assert_eq;

// Below this threshold, CDF values are in the deep tail where the contract
// clamps at sqrt(32). Scipy and the contract may differ by more than
// assert_approx tolerance, so we only check both are near 0 (or near FLOAT).
const CDF_TAIL_THRESHOLD: u64 = 1_000;

#[test]
fun ln_matches_scipy() {
    gs::ln_cases().do_ref!(|c| {
        let (mag, neg) = math::ln(gs::ln_input(c));
        precision::assert_approx(mag, gs::ln_expected_mag(c));
        assert_eq!(neg, gs::ln_expected_neg(c));
    });
}

#[test]
fun exp_matches_scipy() {
    gs::exp_cases().do_ref!(|c| {
        let result = math::exp(gs::exp_input(c), gs::exp_is_negative(c));
        let expected = gs::exp_expected(c);
        if (expected == 0) {
            assert_eq!(result, 0);
        } else {
            precision::assert_approx(result, expected);
        };
    });
}

#[test]
fun cdf_matches_scipy() {
    let f: u64 = 1_000_000_000;
    gs::cdf_cases().do_ref!(|c| {
        let result = math::normal_cdf(gs::cdf_input(c), gs::cdf_is_negative(c));
        let expected = gs::cdf_expected(c);
        if (expected < CDF_TAIL_THRESHOLD) {
            assert!(result < CDF_TAIL_THRESHOLD);
        } else if (expected > f - CDF_TAIL_THRESHOLD) {
            assert!(result > f - CDF_TAIL_THRESHOLD);
        } else {
            precision::assert_approx(result, expected);
        };
    });
}

#[test]
fun exp_overflow_inputs_above_max() {
    // Verify all generated overflow inputs are above MAX_EXP_INPUT.
    // Actual abort coverage is in math_tests::exp_overflow_aborts.
    gs::exp_overflow_cases().do!(|x| {
        assert!(x > 23_638_153_699);
    });
}
