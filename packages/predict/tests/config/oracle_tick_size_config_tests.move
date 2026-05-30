// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::oracle_tick_size_config_tests;

use deepbook_predict::config_constants;

const BTC_SPOT: u64 = 100_000_000_000_000; // $100,000 in 1e9 price scaling
const ZERO_SPOT: u64 = 0;
const VALID_BTC_TICK_SIZE: u64 = 1_000_000_000; // $1.00; spot spans 100,000 ticks
const TOO_SMALL_BTC_TICK_SIZE: u64 = 10_000; // $0.00001; spot spans far above the max tick budget
const TOO_LARGE_BTC_TICK_SIZE: u64 = 3_000_000_000; // $3.00; spot spans fewer than grid_ticks/2 ticks
const UNALIGNED_TICK_SIZE: u64 = VALID_BTC_TICK_SIZE + 1;

#[test]
fun assert_oracle_tick_size_accepts_valid_granularity() {
    config_constants::assert_oracle_tick_size(VALID_BTC_TICK_SIZE);
    assert!(VALID_BTC_TICK_SIZE % deepbook_predict::constants::oracle_tick_size_unit!() == 0);
}

#[test, expected_failure(abort_code = config_constants::EInvalidOracleTickSize)]
fun assert_oracle_tick_size_unaligned_aborts() {
    config_constants::assert_oracle_tick_size(UNALIGNED_TICK_SIZE);
    abort 999
}

#[test]
fun assert_oracle_tick_size_covers_spot_accepts_boundary() {
    config_constants::assert_oracle_tick_size_covers_spot(VALID_BTC_TICK_SIZE, BTC_SPOT);
    assert!(
        BTC_SPOT / VALID_BTC_TICK_SIZE == deepbook_predict::constants::oracle_strike_grid_ticks!(),
    );
}

#[test, expected_failure(abort_code = config_constants::EOracleTickSizeTooSmallForSpot)]
fun assert_oracle_tick_size_covers_spot_aborts_when_too_small() {
    config_constants::assert_oracle_tick_size_covers_spot(TOO_SMALL_BTC_TICK_SIZE, BTC_SPOT);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EOracleTickSizeTooLargeForSpot)]
fun assert_oracle_tick_size_covers_spot_aborts_when_too_large() {
    config_constants::assert_oracle_tick_size_covers_spot(TOO_LARGE_BTC_TICK_SIZE, BTC_SPOT);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidOracleSpot)]
fun assert_oracle_tick_size_covers_spot_aborts_without_spot() {
    config_constants::assert_oracle_tick_size_covers_spot(VALID_BTC_TICK_SIZE, ZERO_SPOT);
    abort 999
}
