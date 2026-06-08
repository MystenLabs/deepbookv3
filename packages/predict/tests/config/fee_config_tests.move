// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Validation bounds for pool fee config fields stored on `ProtocolConfig`.
#[test_only]
module deepbook_predict::fee_config_tests;

use deepbook_predict::{config_constants, math::float_scaling as float};
use std::unit_test::assert_eq;

const WITHDRAW_FEE_ALPHA_DEFAULT: u64 = 250_000_000; // 25%
const WITHDRAW_FEE_ALPHA_MIN: u64 = 50_000_000; // 5%

#[test]
fun reserve_profit_share_accepts_zero_and_full() {
    config_constants::assert_protocol_reserve_profit_share(0);
    config_constants::assert_protocol_reserve_profit_share(float!());
}

#[test, expected_failure(abort_code = config_constants::EInvalidProtocolReserveProfitShare)]
fun reserve_profit_share_above_float_aborts() {
    config_constants::assert_protocol_reserve_profit_share(float!() + 1);
    abort 999
}

#[test]
fun withdraw_fee_alpha_default_and_bounds_match_policy() {
    assert_eq!(config_constants::default_withdraw_fee_alpha!(), WITHDRAW_FEE_ALPHA_DEFAULT);
    assert_eq!(config_constants::min_withdraw_fee_alpha!(), WITHDRAW_FEE_ALPHA_MIN);
    assert_eq!(config_constants::max_withdraw_fee_alpha!(), float!());
}

#[test]
fun withdraw_fee_alpha_accepts_min_default_and_full() {
    config_constants::assert_withdraw_fee_alpha(config_constants::min_withdraw_fee_alpha!());
    config_constants::assert_withdraw_fee_alpha(config_constants::default_withdraw_fee_alpha!());
    config_constants::assert_withdraw_fee_alpha(config_constants::max_withdraw_fee_alpha!());
}

#[test, expected_failure(abort_code = config_constants::EInvalidWithdrawFeeAlpha)]
fun withdraw_fee_alpha_below_min_aborts() {
    config_constants::assert_withdraw_fee_alpha(WITHDRAW_FEE_ALPHA_MIN - 1);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidWithdrawFeeAlpha)]
fun withdraw_fee_alpha_above_max_aborts() {
    config_constants::assert_withdraw_fee_alpha(float!() + 1);
    abort 999
}
