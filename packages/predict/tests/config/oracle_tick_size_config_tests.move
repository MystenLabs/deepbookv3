// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::oracle_tick_size_config_tests;

use deepbook_predict::{config_constants, constants};

const VALID_BTC_TICK_SIZE: u64 = 1_000_000_000; // $1.00; spot spans 100,000 ticks
const UNALIGNED_TICK_SIZE: u64 = VALID_BTC_TICK_SIZE + 1;

#[test]
fun assert_oracle_tick_size_accepts_valid_granularity() {
    config_constants::assert_oracle_tick_size(VALID_BTC_TICK_SIZE);
    assert!(VALID_BTC_TICK_SIZE % constants::oracle_tick_size_unit!() == 0);
}

#[test, expected_failure(abort_code = config_constants::EInvalidOracleTickSize)]
fun assert_oracle_tick_size_unaligned_aborts() {
    config_constants::assert_oracle_tick_size(UNALIGNED_TICK_SIZE);
    abort 999
}
