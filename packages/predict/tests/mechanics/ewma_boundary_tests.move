// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Fixed-point headroom at the EWMA gas-price squared-deviation boundary.
#[test_only]
module deepbook_predict::scope_mechanics__intent_boundary__ewma_tests;

use fixed_math::math;
use std::unit_test::assert_eq;

const HIGHEST_FITTING_GAS_PRICE: u64 = 135_818;
const FIRST_OVERFLOWING_GAS_PRICE: u64 = 135_819;
const HIGHEST_FITTING_SQUARE: u64 = 18_446_529_124_000_000_000;
const FIRST_OVERFLOWING_SQUARE: u128 = 18_446_800_761_000_000_000;

#[test]
fun squared_gas_price_headroom_ends_between_adjacent_inputs() {
    let scale = math::float_scaling!();
    let fitting_diff = HIGHEST_FITTING_GAS_PRICE * scale;
    assert_eq!(math::mul(fitting_diff, fitting_diff), HIGHEST_FITTING_SQUARE);

    let overflowing_diff = (FIRST_OVERFLOWING_GAS_PRICE as u128) * (scale as u128);
    let overflowing_square = overflowing_diff * overflowing_diff / (scale as u128);
    assert_eq!(overflowing_square, FIRST_OVERFLOWING_SQUARE);
    assert!(overflowing_square > (std::u64::max_value!() as u128));
}
