// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::stake_config_tests;

use deepbook_predict::{config_constants, stake_config};
use std::unit_test::{assert_eq, destroy};

// === Construction and getter ===

#[test]
fun default_matches_config_constants() {
    let config = stake_config::new();
    assert_eq!(config.max_benefit_power(), config_constants::default_max_benefit_power!());
    destroy(config);
}

// === set_max_benefit_power ===

#[test]
fun set_updates_value() {
    let mut config = stake_config::new();
    config.set_max_benefit_power(250_000_000_000); // 250k DEEP
    assert_eq!(config.max_benefit_power(), 250_000_000_000);
    destroy(config);
}

#[test]
fun set_accepts_boundaries() {
    let mut config = stake_config::new();

    config.set_max_benefit_power(config_constants::min_max_benefit_power!());
    assert_eq!(config.max_benefit_power(), config_constants::min_max_benefit_power!());

    config.set_max_benefit_power(config_constants::max_max_benefit_power!());
    assert_eq!(config.max_benefit_power(), config_constants::max_max_benefit_power!());

    destroy(config);
}

#[test, expected_failure(abort_code = config_constants::EInvalidMaxBenefitPower)]
fun set_below_min_aborts() {
    let mut config = stake_config::new();
    config.set_max_benefit_power(config_constants::min_max_benefit_power!() - 1);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidMaxBenefitPower)]
fun set_above_max_aborts() {
    let mut config = stake_config::new();
    config.set_max_benefit_power(config_constants::max_max_benefit_power!() + 1);
    abort 999
}
