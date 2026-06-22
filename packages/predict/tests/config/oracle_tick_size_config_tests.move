// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::market_tick_size_config_tests;

use deepbook_predict::{config_constants, constants};

const VALID_BTC_TICK_SIZE: u64 = 1_000_000_000; // $1.00; spot spans 100,000 ticks
const UNALIGNED_TICK_SIZE: u64 = VALID_BTC_TICK_SIZE + 1;

/// Smallest `market_tick_size_unit` (10_000) multiple that overflows the raw
/// strike `pos_inf_tick * tick_size`. The largest non-overflowing tick size is
/// `floor(u64::max / pos_inf_tick) = floor((2^64 - 1) / (2^24 - 1)) = 2^40 + 2^16
/// = 1_099_511_693_312` (since `(2^24 - 1)(2^40 + 2^16) = 2^64 - 2^16`, leaving
/// remainder 65_535 < pos_inf_tick). The next multiple of 10_000 strictly above
/// that limit is `1_099_511_700_000`, which clears the alignment check and so
/// triggers the overflow bound specifically.
const OVERFLOWING_ALIGNED_TICK_SIZE: u64 = 1_099_511_700_000;

#[test]
fun assert_market_tick_size_bounds_accepts_valid_granularity() {
    config_constants::assert_market_tick_size_bounds(VALID_BTC_TICK_SIZE);
    assert!(VALID_BTC_TICK_SIZE % constants::market_tick_size_unit!() == 0);
}

#[test, expected_failure(abort_code = config_constants::EInvalidMarketTickSize)]
fun assert_market_tick_size_bounds_zero_aborts() {
    config_constants::assert_market_tick_size_bounds(0);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidMarketTickSize)]
fun assert_market_tick_size_bounds_unaligned_aborts() {
    config_constants::assert_market_tick_size_bounds(UNALIGNED_TICK_SIZE);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidMarketTickSize)]
fun assert_market_tick_size_bounds_raw_strike_overflow_aborts() {
    // Aligned to `market_tick_size_unit` so the multiple-of-unit check passes and
    // the `tick_size <= u64::max / pos_inf_tick` overflow bound is what fires.
    config_constants::assert_market_tick_size_bounds(OVERFLOWING_ALIGNED_TICK_SIZE);
    abort 999
}
