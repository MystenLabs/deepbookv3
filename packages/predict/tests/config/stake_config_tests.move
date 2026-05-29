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

// === Construction and getter ===

#[test]
fun default_matches_config_constants() {
    let config = stake_config::new();
    assert_eq!(config.lower_benefit_power(), config_constants::default_lower_benefit_power!());
    assert_eq!(config.upper_benefit_power(), config_constants::default_upper_benefit_power!());
    assert_eq!(config.max_fee_discount(), config_constants::default_max_fee_discount!());
    assert_eq!(config.max_rebate_fraction(), config_constants::default_max_rebate_fraction!());
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

// === benefit curve (default config: lower 100k, upper 1.1M, 50% fee, 100% rebate) ===

#[test]
fun fee_discount_follows_two_segment_curve() {
    let config = stake_config::new();
    assert_eq!(config.fee_discount_fraction(0), 0);
    assert_eq!(config.fee_discount_fraction(TWENTY_K), 50_000_000); // ratio 0.1 -> 5%
    assert_eq!(config.fee_discount_fraction(LOWER), 250_000_000); // kink, ratio 0.5 -> 25%
    assert_eq!(config.fee_discount_fraction(THREE_HUNDRED_K), 300_000_000); // ratio 0.6 -> 30%
    assert_eq!(config.fee_discount_fraction(UPPER), 500_000_000); // ratio 1.0 -> 50%
    assert_eq!(config.fee_discount_fraction(TWO_MILLION), 500_000_000); // capped
    destroy(config);
}

#[test]
fun rebate_follows_two_segment_curve() {
    let config = stake_config::new();
    assert_eq!(config.rebate_fraction(0), 0);
    assert_eq!(config.rebate_fraction(TWENTY_K), 100_000_000); // 10%
    assert_eq!(config.rebate_fraction(LOWER), 500_000_000); // 50%
    assert_eq!(config.rebate_fraction(THREE_HUNDRED_K), 600_000_000); // 60%
    assert_eq!(config.rebate_fraction(UPPER), 1_000_000_000); // 100%
    assert_eq!(config.rebate_fraction(TWO_MILLION), 1_000_000_000); // capped
    destroy(config);
}

#[test]
fun benefits_respect_configured_caps() {
    let mut config = stake_config::new();
    config.set_max_fee_discount(250_000_000); // 25%
    config.set_max_rebate_fraction(500_000_000); // 50%

    assert_eq!(config.fee_discount_fraction(UPPER), 250_000_000); // full stake -> 25%
    assert_eq!(config.fee_discount_fraction(LOWER), 125_000_000); // half-benefit -> 12.5%
    assert_eq!(config.rebate_fraction(UPPER), 500_000_000); // full stake -> 50%
    assert_eq!(config.rebate_fraction(LOWER), 250_000_000); // half-benefit -> 25%

    destroy(config);
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
