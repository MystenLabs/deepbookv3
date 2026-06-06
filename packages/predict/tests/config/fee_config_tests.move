// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::fee_config_tests;

use deepbook_predict::{config_constants, constants::float_scaling as float, fee_config};
use std::unit_test::{assert_eq, destroy};

const THIRTY_PERCENT: u64 = 300_000_000;

// === Construction and getters ===

#[test]
fun defaults_match_config_constants() {
    let config = fee_config::new();

    assert_eq!(
        config.protocol_reserve_profit_share(),
        config_constants::default_protocol_reserve_profit_share!(),
    );
    destroy(config);
}

// === set_protocol_reserve_profit_share ===

#[test]
fun set_protocol_reserve_profit_share_updates_value() {
    let mut config = fee_config::new();

    config.set_protocol_reserve_profit_share(THIRTY_PERCENT);

    assert_eq!(config.protocol_reserve_profit_share(), THIRTY_PERCENT);
    destroy(config);
}

#[test]
fun set_protocol_reserve_profit_share_accepts_zero() {
    let mut config = fee_config::new();
    config.set_protocol_reserve_profit_share(0);
    assert_eq!(config.protocol_reserve_profit_share(), 0);
    destroy(config);
}

#[test]
fun set_protocol_reserve_profit_share_accepts_full_protocol_reserve() {
    let mut config = fee_config::new();
    config.set_protocol_reserve_profit_share(float!());
    assert_eq!(config.protocol_reserve_profit_share(), float!());
    destroy(config);
}

#[test, expected_failure(abort_code = config_constants::EInvalidProtocolReserveProfitShare)]
fun set_protocol_reserve_profit_share_above_float_aborts() {
    let mut config = fee_config::new();
    config.set_protocol_reserve_profit_share(float!() + 1);
    abort 999
}
