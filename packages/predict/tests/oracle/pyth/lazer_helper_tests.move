// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::lazer_helper_tests;

use deepbook_predict::lazer_helper;
use pyth_lazer::{i16, i64};
use std::unit_test::assert_eq;

// Target scaling for the package is 1e9; `normalize_pyth_price` brings
// `(magnitude, exponent)` Pyth pairs into that scale via `magnitude * 10^(exponent + 9)`.

#[test]
fun negative_exponent_within_target_scales_up() {
    // BTC-style: 65_000.12345678 USD published as (6_500_012_345_678, -8).
    // Target shift = 9 + (-8) = +1, so the value scales up by 10:
    // 6_500_012_345_678 * 10 = 65_000_123_456_780, which is 65_000.12345678 * 1e9.
    let normalized = lazer_helper::normalize_pyth_price_for_testing(
        i64::new(6_500_012_345_678, false),
        i16::new(8, true),
    );
    assert_eq!(normalized, 65_000_123_456_780);
}

#[test]
fun negative_exponent_equal_to_target_is_identity() {
    // exponent = -9 exactly: shift = 0 so the magnitude passes through.
    let normalized = lazer_helper::normalize_pyth_price_for_testing(
        i64::new(123_456_789, false),
        i16::new(9, true),
    );
    assert_eq!(normalized, 123_456_789);
}

#[test]
fun negative_exponent_beyond_target_divides_down() {
    // exponent = -12: shift = -3 so we divide the magnitude by 1_000.
    // 12_345_678_901 / 1_000 = 12_345_678 (floor div per integer arithmetic).
    let normalized = lazer_helper::normalize_pyth_price_for_testing(
        i64::new(12_345_678_901, false),
        i16::new(12, true),
    );
    assert_eq!(normalized, 12_345_678);
}

#[test]
fun negative_exponent_beyond_target_rounds_toward_zero() {
    // Sub-unit precision is lost: 5 / 1_000 = 0 (integer division).
    let normalized = lazer_helper::normalize_pyth_price_for_testing(
        i64::new(5, false),
        i16::new(12, true),
    );
    assert_eq!(normalized, 0);
}

#[test]
fun zero_exponent_scales_up_by_target() {
    // exp = 0: shift = +9, so 1 -> 1_000_000_000 (1.0 in package scale).
    let normalized = lazer_helper::normalize_pyth_price_for_testing(
        i64::new(1, false),
        i16::new(0, false),
    );
    assert_eq!(normalized, 1_000_000_000);
}

#[test]
fun positive_exponent_scales_up_by_target_plus_exp() {
    // exp = +2: shift = +11, so 3 -> 3 * 10^11 = 300_000_000_000.
    let normalized = lazer_helper::normalize_pyth_price_for_testing(
        i64::new(3, false),
        i16::new(2, false),
    );
    assert_eq!(normalized, 300_000_000_000);
}

#[test]
fun zero_magnitude_normalizes_to_zero() {
    let normalized = lazer_helper::normalize_pyth_price_for_testing(
        i64::new(0, false),
        i16::new(8, true),
    );
    assert_eq!(normalized, 0);
}

#[test, expected_failure(abort_code = lazer_helper::ELazerNegativePrice)]
fun negative_price_aborts() {
    lazer_helper::normalize_pyth_price_for_testing(
        i64::new(1_000, true), // negative
        i16::new(8, true),
    );
    abort 999
}
