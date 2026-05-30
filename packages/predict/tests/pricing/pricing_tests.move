// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::pricing_tests;

use deepbook_predict::{
    constants::{float_scaling as float, expiry_fee_window_ms as window},
    pricing
};
use std::unit_test::assert_eq;

const TWO_X: u64 = 2_000_000_000;

#[test]
fun multiplier_disabled_when_max_is_one() {
    // max == 1x -> ramp term is 0, so 1x everywhere inside the window.
    assert_eq!(pricing::expiry_fee_multiplier(float!(), 0), float!());
    assert_eq!(pricing::expiry_fee_multiplier(float!(), window!() / 2), float!());
}

#[test]
fun multiplier_is_one_at_and_beyond_window() {
    // The ramp has not started at the window boundary, and is off outside it.
    assert_eq!(pricing::expiry_fee_multiplier(TWO_X, window!()), float!());
    assert_eq!(pricing::expiry_fee_multiplier(TWO_X, 2 * window!()), float!());
}

#[test]
fun multiplier_ramps_linearly_within_window() {
    // Halfway through the window: 1 + (2 - 1) * 0.5 = 1.5x.
    assert_eq!(pricing::expiry_fee_multiplier(TWO_X, window!() / 2), 1_500_000_000);
    // At expiry (ttx == 0): full max multiplier.
    assert_eq!(pricing::expiry_fee_multiplier(TWO_X, 0), TWO_X);
}

#[test]
fun multiplier_rounds_down() {
    // ttx = window/3 -> 1 + 1x * 2/3 = 1 + 666_666_666 (floored) = 1_666_666_666.
    assert_eq!(pricing::expiry_fee_multiplier(TWO_X, window!() / 3), 1_666_666_666);
    // ttx = 2*window/3 -> 1 + 1x * 1/3 = 1 + 333_333_333 (floored) = 1_333_333_333.
    assert_eq!(pricing::expiry_fee_multiplier(TWO_X, 2 * window!() / 3), 1_333_333_333);
}
