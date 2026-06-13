// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::stake_config_tests;

use deepbook_predict::{config_constants, stake_config};
use std::unit_test::{assert_eq, destroy};

// Active-stake levels in raw DEEP units; LOWER/UPPER match the StakeConfig defaults.
const TWENTY_K: u64 = 20_000_000_000;
const LOWER: u64 = 100_000_000_000; // default lower_benefit_power
const THREE_HUNDRED_K: u64 = 300_000_000_000;
const UPPER: u64 = 1_100_000_000_000; // default upper_benefit_power
const TWO_MILLION: u64 = 2_000_000_000_000;
const FEE_AMOUNT: u64 = 1_000_000_000;

// === Construction and getter ===

#[test]
fun default_matches_config_constants() {
    let config = stake_config::new();
    assert_eq!(config.lower_benefit_power(), config_constants::default_lower_benefit_power!());
    assert_eq!(config.upper_benefit_power(), config_constants::default_upper_benefit_power!());
    destroy(config);
}

// === set_benefit_powers ===

#[test]
fun set_benefit_powers_updates_both() {
    let mut config = stake_config::new();
    config.set_benefit_powers(200_000_000_000, 1_000_000_000_000); // 200k / 1M (1M > 400k)
    assert_eq!(config.lower_benefit_power(), 200_000_000_000);
    assert_eq!(config.upper_benefit_power(), 1_000_000_000_000);
    destroy(config);
}

#[test]
fun set_benefit_powers_accepts_boundaries() {
    let mut config = stake_config::new();

    // Min lower with min upper: 100k > 2*10k.
    config.set_benefit_powers(
        config_constants::min_lower_benefit_power!(),
        config_constants::min_upper_benefit_power!(),
    );
    assert_eq!(config.lower_benefit_power(), config_constants::min_lower_benefit_power!());
    assert_eq!(config.upper_benefit_power(), config_constants::min_upper_benefit_power!());

    // Max lower with max upper: 50M > 2*1M.
    config.set_benefit_powers(
        config_constants::max_lower_benefit_power!(),
        config_constants::max_upper_benefit_power!(),
    );
    assert_eq!(config.lower_benefit_power(), config_constants::max_lower_benefit_power!());
    assert_eq!(config.upper_benefit_power(), config_constants::max_upper_benefit_power!());

    destroy(config);
}

#[test, expected_failure(abort_code = config_constants::EInvalidBenefitPowers)]
fun set_benefit_powers_non_steeper_upper_aborts() {
    // upper == 2*lower is not strictly greater -> rejected.
    let mut config = stake_config::new();
    config.set_benefit_powers(100_000_000_000, 200_000_000_000);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidLowerBenefitPower)]
fun set_benefit_powers_lower_below_min_aborts() {
    let mut config = stake_config::new();
    config.set_benefit_powers(
        config_constants::min_lower_benefit_power!() - 1,
        config_constants::default_upper_benefit_power!(),
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidUpperBenefitPower)]
fun set_benefit_powers_upper_below_min_aborts() {
    // lower valid (50k), upper below the 100k floor.
    let mut config = stake_config::new();
    config.set_benefit_powers(50_000_000_000, config_constants::min_upper_benefit_power!() - 1);
    abort 999
}

// === benefit curve (default config: lower 100k, upper 1.1M; fee cap 50%, rebate uncapped) ===

#[test]
fun fee_amount_after_discount_follows_two_segment_curve() {
    let config = stake_config::new();
    assert_eq!(config.fee_amount_after_discount(FEE_AMOUNT, 0), 1_000_000_000);
    assert_eq!(config.fee_amount_after_discount(FEE_AMOUNT, TWENTY_K), 950_000_000);
    assert_eq!(config.fee_amount_after_discount(FEE_AMOUNT, LOWER), 750_000_000);
    assert_eq!(config.fee_amount_after_discount(FEE_AMOUNT, THREE_HUNDRED_K), 700_000_000);
    assert_eq!(config.fee_amount_after_discount(FEE_AMOUNT, UPPER), 500_000_000);
    assert_eq!(config.fee_amount_after_discount(FEE_AMOUNT, TWO_MILLION), 500_000_000);
    destroy(config);
}
