// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::pricing_tests;

use deepbook_predict::{constants::float_scaling as float, pricing};
use std::unit_test::assert_eq;

const DAY_MS: u64 = 86_400_000;
const TWO_X: u64 = 2_000_000_000;

#[test]
fun multiplier_disabled_when_window_zero() {
    // window == 0 -> ramp off for any time-to-expiry, including 0 (no zero-divisor).
    assert_eq!(pricing::expiry_fee_multiplier_for_testing(0, TWO_X, 0), float!());
    assert_eq!(pricing::expiry_fee_multiplier_for_testing(0, TWO_X, DAY_MS), float!());
}

#[test]
fun multiplier_disabled_when_max_is_one() {
    // max == 1x -> ramp term is 0, so 1x everywhere inside the window.
    assert_eq!(pricing::expiry_fee_multiplier_for_testing(DAY_MS, float!(), 0), float!());
    assert_eq!(pricing::expiry_fee_multiplier_for_testing(DAY_MS, float!(), DAY_MS / 2), float!());
}

#[test]
fun multiplier_is_one_at_and_beyond_window() {
    // The ramp has not started at the window boundary, and is off outside it.
    assert_eq!(pricing::expiry_fee_multiplier_for_testing(DAY_MS, TWO_X, DAY_MS), float!());
    assert_eq!(pricing::expiry_fee_multiplier_for_testing(DAY_MS, TWO_X, 2 * DAY_MS), float!());
}

#[test]
fun multiplier_ramps_linearly_within_window() {
    // Halfway through the window: 1 + (2 - 1) * 0.5 = 1.5x.
    assert_eq!(
        pricing::expiry_fee_multiplier_for_testing(DAY_MS, TWO_X, DAY_MS / 2),
        1_500_000_000,
    );
    // At expiry (ttx == 0): full max multiplier.
    assert_eq!(pricing::expiry_fee_multiplier_for_testing(DAY_MS, TWO_X, 0), TWO_X);
}

#[test]
fun multiplier_rounds_down() {
    // window = 3ms, max = 2x. ttx = 1: 1 + 1x * 2/3 = 1 + 666_666_666 (floored) = 1_666_666_666.
    assert_eq!(pricing::expiry_fee_multiplier_for_testing(3, TWO_X, 1), 1_666_666_666);
    // ttx = 2: 1 + 1x * 1/3 = 1 + 333_333_333 = 1_333_333_333.
    assert_eq!(pricing::expiry_fee_multiplier_for_testing(3, TWO_X, 2), 1_333_333_333);
}
