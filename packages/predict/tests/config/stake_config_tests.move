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
    assert_eq!(config.max_fee_discount(), config_constants::default_max_fee_discount!());
    assert_eq!(config.max_rebate_fraction(), config_constants::default_max_rebate_fraction!());
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

// === set_max_fee_discount (0..50%) ===

#[test]
fun set_max_fee_discount_updates_and_accepts_boundaries() {
    let mut config = stake_config::new();
    config.set_max_fee_discount(250_000_000); // 25%
    assert_eq!(config.max_fee_discount(), 250_000_000);

    config.set_max_fee_discount(config_constants::min_max_fee_discount!()); // 0%
    assert_eq!(config.max_fee_discount(), 0);
    config.set_max_fee_discount(config_constants::max_max_fee_discount!()); // 50%
    assert_eq!(config.max_fee_discount(), config_constants::max_max_fee_discount!());

    destroy(config);
}

#[test, expected_failure(abort_code = config_constants::EInvalidMaxFeeDiscount)]
fun set_max_fee_discount_above_ceiling_aborts() {
    let mut config = stake_config::new();
    config.set_max_fee_discount(config_constants::max_max_fee_discount!() + 1); // > 50%
    abort 999
}

// === set_max_rebate_fraction (0..100%) ===

#[test]
fun set_max_rebate_fraction_updates_and_accepts_boundaries() {
    let mut config = stake_config::new();
    config.set_max_rebate_fraction(500_000_000); // 50%
    assert_eq!(config.max_rebate_fraction(), 500_000_000);

    config.set_max_rebate_fraction(config_constants::min_max_rebate_fraction!()); // 0%
    assert_eq!(config.max_rebate_fraction(), 0);
    config.set_max_rebate_fraction(config_constants::max_max_rebate_fraction!()); // 100%
    assert_eq!(config.max_rebate_fraction(), config_constants::max_max_rebate_fraction!());

    destroy(config);
}

#[test, expected_failure(abort_code = config_constants::EInvalidMaxRebateFraction)]
fun set_max_rebate_fraction_above_ceiling_aborts() {
    let mut config = stake_config::new();
    config.set_max_rebate_fraction(config_constants::max_max_rebate_fraction!() + 1); // > 100%
    abort 999
}
