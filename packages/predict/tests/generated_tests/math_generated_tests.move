// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Generated vector tests — validates math functions against scipy ground truth.
/// For hand-written property tests, see math_tests.move.
#[test_only]
module deepbook_predict::math_generated_tests;

use deepbook_predict::{generated_math as gs, math, precision};
use std::unit_test::assert_eq;

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
    gs::cdf_cases().do_ref!(|c| {
        let result = math::normal_cdf(gs::cdf_input(c), gs::cdf_is_negative(c));
        let expected = gs::cdf_expected(c);
        if (expected == 0) {
            assert_eq!(result, 0);
        } else {
            precision::assert_approx(result, expected);
        };
    });
}
