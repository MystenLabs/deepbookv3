// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::pricing_config_tests;

use deepbook_predict::{config_constants, pricing_config};
use std::unit_test::{assert_eq, destroy};

#[test]
fun defaults_expose_fee_terms() {
    let config = pricing_config::new();

    assert_eq!(config.base_fee(), config_constants::default_base_fee!());
    assert_eq!(config.min_fee(), config_constants::default_min_fee!());
    assert_eq!(
        config.utilization_multiplier(),
        config_constants::default_utilization_multiplier!(),
    );
    assert_eq!(config.min_ask_price(), config_constants::default_min_ask_price!());
    assert_eq!(config.max_ask_price(), config_constants::default_max_ask_price!());
    destroy(config);
}

#[test]
fun setters_update_fee_terms() {
    let mut config = pricing_config::new();

    config.set_base_fee(30_000_000);
    config.set_min_fee(2_000_000);
    config.set_utilization_multiplier(3_000_000_000);

    assert_eq!(config.base_fee(), 30_000_000);
    assert_eq!(config.min_fee(), 2_000_000);
    assert_eq!(config.utilization_multiplier(), 3_000_000_000);
    destroy(config);
}
