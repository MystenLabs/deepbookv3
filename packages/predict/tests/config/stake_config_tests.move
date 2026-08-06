// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::stake_config_tests;

use deepbook_predict::{config_constants, stake_config};
use std::unit_test::{assert_eq, destroy};

// Active-stake levels in raw DEEP units.
const TWENTY_K: u64 = 20_000_000_000;
const THREE_HUNDRED_K: u64 = 300_000_000_000;
const TWO_MILLION: u64 = 2_000_000_000_000;
const FEE_AMOUNT: u64 = 1_000_000_000;
const CUSTOM_LOWER: u64 = 200_000_000_000;
const CUSTOM_UPPER: u64 = 1_000_000_000_000;
const NO_DISCOUNT_FEE: u64 = 1_000_000_000;
const TWENTY_K_DISCOUNTED_FEE: u64 = 950_000_000;
const HALF_BENEFIT_FEE: u64 = 750_000_000;
const THREE_HUNDRED_K_DISCOUNTED_FEE: u64 = 700_000_000;
const FULL_BENEFIT_FEE: u64 = 500_000_000;

// Rebate expectations on the default curve: `eligible x benefit_ratio`, with no
// staking-side cap. Ratios are 0.1 / 0.5 / 0.6 / 1.0 at the stakes above.
const ELIGIBLE_REBATE: u64 = 1_000_000_000;
const NO_REBATE: u64 = 0;
const TWENTY_K_REBATE: u64 = 100_000_000;
const HALF_BENEFIT_REBATE: u64 = 500_000_000;
const THREE_HUNDRED_K_REBATE: u64 = 600_000_000;
const FULL_BENEFIT_REBATE: u64 = 1_000_000_000;

// A market's snapshotted benefit switch, as passed by `ExpiryMarket`.
const BENEFITS_OFF: bool = false;
const BENEFITS_ON: bool = true;

// === Template seed: the programme ships disabled ===

#[test]
fun new_config_template_ships_disabled() {
    let config = stake_config::new();
    assert_eq!(config.template_benefits_enabled(), false);
    destroy(config);
}

#[test]
fun set_template_benefits_enabled_flips_the_seed() {
    let mut config = stake_config::new();
    config.set_template_benefits_enabled(true);
    assert_eq!(config.template_benefits_enabled(), true);
    config.set_template_benefits_enabled(false);
    assert_eq!(config.template_benefits_enabled(), false);
    destroy(config);
}

#[test]
fun template_seed_does_not_change_the_curve_for_a_snapshotted_market() {
    // The seed only decides what a NEW market snapshots. A market that snapshotted
    // `true` keeps its benefits after the template is turned off, and vice versa.
    let mut config = stake_config::new();
    config.set_template_benefits_enabled(false);
    assert_eq!(
        config.fee_amount_after_discount(FEE_AMOUNT, TWO_MILLION, BENEFITS_ON),
        FULL_BENEFIT_FEE,
    );
    config.set_template_benefits_enabled(true);
    assert_eq!(
        config.fee_amount_after_discount(FEE_AMOUNT, TWO_MILLION, BENEFITS_OFF),
        NO_DISCOUNT_FEE,
    );
    destroy(config);
}

// === A market that snapshotted the programme off ===

#[test]
fun disabled_market_charges_the_undiscounted_fee_at_every_stake() {
    let config = stake_config::new();
    assert_eq!(config.fee_amount_after_discount(FEE_AMOUNT, 0, BENEFITS_OFF), NO_DISCOUNT_FEE);
    assert_eq!(
        config.fee_amount_after_discount(FEE_AMOUNT, TWENTY_K, BENEFITS_OFF),
        NO_DISCOUNT_FEE,
    );
    assert_eq!(
        config.fee_amount_after_discount(
            FEE_AMOUNT,
            config_constants::default_lower_benefit_power!(),
            BENEFITS_OFF,
        ),
        NO_DISCOUNT_FEE,
    );
    assert_eq!(
        config.fee_amount_after_discount(
            FEE_AMOUNT,
            config_constants::default_upper_benefit_power!(),
            BENEFITS_OFF,
        ),
        NO_DISCOUNT_FEE,
    );
    // Past the top of the curve, where full benefits would otherwise apply.
    assert_eq!(
        config.fee_amount_after_discount(FEE_AMOUNT, TWO_MILLION, BENEFITS_OFF),
        NO_DISCOUNT_FEE,
    );
    destroy(config);
}

#[test]
fun disabled_market_pays_no_rebate_at_every_stake() {
    let config = stake_config::new();
    assert_eq!(config.rebate_amount(ELIGIBLE_REBATE, 0, BENEFITS_OFF), NO_REBATE);
    assert_eq!(config.rebate_amount(ELIGIBLE_REBATE, TWENTY_K, BENEFITS_OFF), NO_REBATE);
    assert_eq!(
        config.rebate_amount(
            ELIGIBLE_REBATE,
            config_constants::default_upper_benefit_power!(),
            BENEFITS_OFF,
        ),
        NO_REBATE,
    );
    assert_eq!(config.rebate_amount(ELIGIBLE_REBATE, TWO_MILLION, BENEFITS_OFF), NO_REBATE);
    destroy(config);
}

// === set_benefit_powers (thresholds stay live) ===

#[test]
fun set_benefit_powers_updates_curve() {
    let mut config = stake_config::new();
    config.set_benefit_powers(CUSTOM_LOWER, CUSTOM_UPPER);
    assert_eq!(
        config.fee_amount_after_discount(FEE_AMOUNT, CUSTOM_LOWER, BENEFITS_ON),
        HALF_BENEFIT_FEE,
    );
    assert_eq!(
        config.fee_amount_after_discount(FEE_AMOUNT, CUSTOM_UPPER, BENEFITS_ON),
        FULL_BENEFIT_FEE,
    );
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
    assert_eq!(
        config.fee_amount_after_discount(
            FEE_AMOUNT,
            config_constants::min_lower_benefit_power!(),
            BENEFITS_ON,
        ),
        HALF_BENEFIT_FEE,
    );
    assert_eq!(
        config.fee_amount_after_discount(
            FEE_AMOUNT,
            config_constants::min_upper_benefit_power!(),
            BENEFITS_ON,
        ),
        FULL_BENEFIT_FEE,
    );

    // Max lower with max upper: 50M > 2*1M.
    config.set_benefit_powers(
        config_constants::max_lower_benefit_power!(),
        config_constants::max_upper_benefit_power!(),
    );
    assert_eq!(
        config.fee_amount_after_discount(
            FEE_AMOUNT,
            config_constants::max_lower_benefit_power!(),
            BENEFITS_ON,
        ),
        HALF_BENEFIT_FEE,
    );
    assert_eq!(
        config.fee_amount_after_discount(
            FEE_AMOUNT,
            config_constants::max_upper_benefit_power!(),
            BENEFITS_ON,
        ),
        FULL_BENEFIT_FEE,
    );

    destroy(config);
}

#[test, expected_failure(abort_code = stake_config::EInvalidBenefitPowers)]
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

// === Benefit curve for a market that snapshotted the programme on ===
// (default config: lower 100k, upper 1.1M; fee cap 50%, rebate uncapped)

#[test]
fun fee_amount_after_discount_follows_two_segment_curve() {
    let config = stake_config::new();
    assert_eq!(config.fee_amount_after_discount(FEE_AMOUNT, 0, BENEFITS_ON), NO_DISCOUNT_FEE);
    assert_eq!(
        config.fee_amount_after_discount(FEE_AMOUNT, TWENTY_K, BENEFITS_ON),
        TWENTY_K_DISCOUNTED_FEE,
    );
    assert_eq!(
        config.fee_amount_after_discount(
            FEE_AMOUNT,
            config_constants::default_lower_benefit_power!(),
            BENEFITS_ON,
        ),
        HALF_BENEFIT_FEE,
    );
    assert_eq!(
        config.fee_amount_after_discount(FEE_AMOUNT, THREE_HUNDRED_K, BENEFITS_ON),
        THREE_HUNDRED_K_DISCOUNTED_FEE,
    );
    assert_eq!(
        config.fee_amount_after_discount(
            FEE_AMOUNT,
            config_constants::default_upper_benefit_power!(),
            BENEFITS_ON,
        ),
        FULL_BENEFIT_FEE,
    );
    assert_eq!(
        config.fee_amount_after_discount(FEE_AMOUNT, TWO_MILLION, BENEFITS_ON),
        FULL_BENEFIT_FEE,
    );
    destroy(config);
}

#[test]
fun rebate_amount_follows_two_segment_curve() {
    let config = stake_config::new();
    assert_eq!(config.rebate_amount(ELIGIBLE_REBATE, 0, BENEFITS_ON), NO_REBATE);
    assert_eq!(config.rebate_amount(ELIGIBLE_REBATE, TWENTY_K, BENEFITS_ON), TWENTY_K_REBATE);
    assert_eq!(
        config.rebate_amount(
            ELIGIBLE_REBATE,
            config_constants::default_lower_benefit_power!(),
            BENEFITS_ON,
        ),
        HALF_BENEFIT_REBATE,
    );
    assert_eq!(
        config.rebate_amount(ELIGIBLE_REBATE, THREE_HUNDRED_K, BENEFITS_ON),
        THREE_HUNDRED_K_REBATE,
    );
    assert_eq!(
        config.rebate_amount(
            ELIGIBLE_REBATE,
            config_constants::default_upper_benefit_power!(),
            BENEFITS_ON,
        ),
        FULL_BENEFIT_REBATE,
    );
    assert_eq!(
        config.rebate_amount(ELIGIBLE_REBATE, TWO_MILLION, BENEFITS_ON),
        FULL_BENEFIT_REBATE,
    );
    destroy(config);
}
