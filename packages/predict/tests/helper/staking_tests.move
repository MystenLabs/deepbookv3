// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::staking_tests;

use deepbook_predict::{constants, staking};
use std::unit_test::assert_eq;

// DEEP has 6 decimals; staking math is in raw DEEP units.
const FIFTY_K_DEEP: u64 = 50_000_000_000;
const HUNDRED_K_DEEP: u64 = 100_000_000_000;
// Power levels for the benefit-fraction tests (raw DEEP units).
const TEN_K_POWER: u64 = 10_000_000_000;
const FIFTEEN_K_POWER: u64 = 15_000_000_000;
const FIFTY_K_POWER: u64 = 50_000_000_000;
const HUNDRED_K_POWER: u64 = 100_000_000_000; // == max_benefit_power
const TWO_HUNDRED_K_POWER: u64 = 200_000_000_000;

// === power (2-year horizon, weight squared) ===

#[test]
fun power_full_two_year_lock_equals_stake() {
    // remaining == 2 years -> weight 1 -> power == staked.
    assert_eq!(staking::power(FIFTY_K_DEEP, constants::max_stake_period_ms!(), 0), FIFTY_K_DEEP);
}

#[test]
fun power_one_year_lock_is_quarter_weight() {
    // 1 year of a 2-year horizon -> weight 0.5, squared 0.25: 100k * 0.25 = 25k.
    assert_eq!(staking::power(HUNDRED_K_DEEP, constants::ms_per_year!(), 0), 25_000_000_000);
}

#[test]
fun power_weight_saturates_beyond_two_years() {
    // A three-year remaining lock still weights as 1.
    assert_eq!(staking::power(FIFTY_K_DEEP, 3 * constants::ms_per_year!(), 0), FIFTY_K_DEEP);
}

#[test]
fun power_decays_as_lock_runs_down() {
    // End two years out, evaluated with one year left -> weight 0.5, 0.25 squared.
    let now = constants::max_stake_period_ms!() - constants::ms_per_year!();
    assert_eq!(
        staking::power(HUNDRED_K_DEEP, constants::max_stake_period_ms!(), now),
        25_000_000_000,
    );
}

#[test]
fun power_zero_at_lock_expiry() {
    assert_eq!(staking::power(HUNDRED_K_DEEP, 1_000, 1_000), 0);
    assert_eq!(staking::power(HUNDRED_K_DEEP, 1_000, 2_000), 0);
}

// === fee_discount_fraction: linear to 50% at 100k power ===

#[test]
fun fee_discount_zero_without_power() {
    assert_eq!(staking::fee_discount_fraction(0), 0);
}

#[test]
fun fee_discount_scales_linearly() {
    // 10k power = 10% of max -> 5%; 15k = 15% -> 7.5%; 50k = 50% -> 25%.
    assert_eq!(staking::fee_discount_fraction(TEN_K_POWER), 50_000_000);
    assert_eq!(staking::fee_discount_fraction(FIFTEEN_K_POWER), 75_000_000);
    assert_eq!(staking::fee_discount_fraction(FIFTY_K_POWER), 250_000_000);
}

#[test]
fun fee_discount_caps_at_50pct() {
    assert_eq!(staking::fee_discount_fraction(HUNDRED_K_POWER), 500_000_000);
    assert_eq!(staking::fee_discount_fraction(TWO_HUNDRED_K_POWER), 500_000_000);
}

// === rebate_fraction: linear to 100% at 100k power ===

#[test]
fun rebate_zero_without_power() {
    assert_eq!(staking::rebate_fraction(0), 0);
}

#[test]
fun rebate_scales_linearly() {
    // 10k power -> 10%; 15k -> 15%; 50k -> 50%.
    assert_eq!(staking::rebate_fraction(TEN_K_POWER), 100_000_000);
    assert_eq!(staking::rebate_fraction(FIFTEEN_K_POWER), 150_000_000);
    assert_eq!(staking::rebate_fraction(FIFTY_K_POWER), 500_000_000);
}

#[test]
fun rebate_caps_at_100pct() {
    assert_eq!(staking::rebate_fraction(HUNDRED_K_POWER), 1_000_000_000);
    assert_eq!(staking::rebate_fraction(TWO_HUNDRED_K_POWER), 1_000_000_000);
}
