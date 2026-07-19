// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Stake benefit-power scalar and relational guards.
#[test_only]
module deepbook_predict::mechanics_stake_config_guard_tests;

use deepbook_predict::{config_constants, stake_config};
use std::unit_test::{assert_eq, destroy};

const RELATIONAL_LOWER: u64 = 100_000_000_000;
const RAW_UNIT: u64 = 1;
const DOUBLE: u64 = 2;
const UNIT_REBATE: u64 = 1;

#[test]
fun scalar_endpoints_and_relational_one_over_are_accepted() {
    let mut config = stake_config::new();
    config.set_benefit_powers(
        config_constants::min_lower_benefit_power!(),
        config_constants::min_upper_benefit_power!(),
    );
    assert_eq!(
        config.rebate_amount(UNIT_REBATE, config_constants::min_upper_benefit_power!()),
        UNIT_REBATE,
    );
    config.set_benefit_powers(
        config_constants::max_lower_benefit_power!(),
        config_constants::max_upper_benefit_power!(),
    );
    assert_eq!(
        config.rebate_amount(UNIT_REBATE, config_constants::max_upper_benefit_power!()),
        UNIT_REBATE,
    );
    config.set_benefit_powers(RELATIONAL_LOWER, DOUBLE * RELATIONAL_LOWER + RAW_UNIT);
    assert_eq!(
        config.rebate_amount(
            UNIT_REBATE,
            DOUBLE * RELATIONAL_LOWER + RAW_UNIT,
        ),
        UNIT_REBATE,
    );
    destroy(config);
}

#[test, expected_failure(abort_code = config_constants::EInvalidLowerBenefitPower)]
fun lower_one_below_min_aborts() {
    stake_config::new().set_benefit_powers(
        config_constants::min_lower_benefit_power!() - RAW_UNIT,
        config_constants::min_upper_benefit_power!(),
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidLowerBenefitPower)]
fun lower_one_above_max_aborts() {
    stake_config::new().set_benefit_powers(
        config_constants::max_lower_benefit_power!() + RAW_UNIT,
        config_constants::max_upper_benefit_power!(),
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidUpperBenefitPower)]
fun upper_one_below_min_aborts() {
    stake_config::new().set_benefit_powers(
        config_constants::min_lower_benefit_power!(),
        config_constants::min_upper_benefit_power!() - RAW_UNIT,
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidUpperBenefitPower)]
fun upper_one_above_max_aborts() {
    stake_config::new().set_benefit_powers(
        config_constants::min_lower_benefit_power!(),
        config_constants::max_upper_benefit_power!() + RAW_UNIT,
    );
    abort 999
}

#[test, expected_failure(abort_code = stake_config::EInvalidBenefitPowers)]
fun upper_equal_to_twice_lower_aborts() {
    stake_config::new().set_benefit_powers(RELATIONAL_LOWER, DOUBLE * RELATIONAL_LOWER);
    abort 999
}
