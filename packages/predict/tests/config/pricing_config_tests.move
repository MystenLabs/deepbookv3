// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::pricing_config_tests;

use deepbook_predict::{constants, pricing};
use std::unit_test::assert_eq;

const CONFIG_ID: address = @0x42;

#[test]
fun defaults_expose_fee_terms() {
    let config = pricing::new();

    assert_eq!(config.base_fee(), constants::default_base_fee!());
    assert_eq!(config.min_fee(), constants::default_min_fee!());
    assert_eq!(config.utilization_multiplier(), constants::default_utilization_multiplier!());
    assert_eq!(config.min_ask_price(), constants::default_min_ask_price!());
    assert_eq!(config.max_ask_price(), constants::default_max_ask_price!());
    config.destroy_for_testing();
}

#[test]
fun setters_update_fee_terms() {
    let mut config = pricing::new();
    let config_id = object::id_from_address(CONFIG_ID);

    config.set_base_fee(config_id, 30_000_000);
    config.set_min_fee(config_id, 2_000_000);
    config.set_utilization_multiplier(config_id, 3_000_000_000);

    assert_eq!(config.base_fee(), 30_000_000);
    assert_eq!(config.min_fee(), 2_000_000);
    assert_eq!(config.utilization_multiplier(), 3_000_000_000);
    config.destroy_for_testing();
}
