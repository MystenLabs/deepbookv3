// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Validation bounds for `protocol_reserve_profit_share`. The value is a field of
/// `ProtocolConfig` (folded from the former `fee_config` module); its bound lives
/// in `config_constants` and is asserted by the protocol_config admin setter.
#[test_only]
module deepbook_predict::fee_config_tests;

use deepbook_predict::{config_constants, constants::float_scaling as float};

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
