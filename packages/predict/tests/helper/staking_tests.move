// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::staking_tests;

use deepbook_predict::{constants, staking};
use std::unit_test::assert_eq;

// DEEP has 6 decimals; staking math is in raw DEEP units.
const FIFTY_K_DEEP: u64 = 50_000_000_000;
const HUNDRED_K_DEEP: u64 = 100_000_000_000;
// 365/5 of a year in ms; weight 0.2, squared 0.04.
const FIFTH_YEAR_MS: u64 = 6_307_200_000;

// === power ===

#[test]
fun power_full_year_lock_equals_stake() {
    // remaining == 1 year -> weight 1 -> power == staked.
    assert_eq!(staking::power(FIFTY_K_DEEP, constants::ms_per_year!(), 0), FIFTY_K_DEEP);
}

#[test]
fun power_scales_quadratically_with_remaining_lock() {
    // weight 0.2, squared 0.04: 100k DEEP * 0.04 = 4k DEEP.
    assert_eq!(staking::power(HUNDRED_K_DEEP, FIFTH_YEAR_MS, 0), 4_000_000_000);
}

#[test]
fun power_weight_saturates_beyond_a_year() {
    // A two-year remaining lock still weights as 1 (no benefit beyond a year).
    assert_eq!(staking::power(FIFTY_K_DEEP, 2 * constants::ms_per_year!(), 0), FIFTY_K_DEEP);
}

#[test]
fun power_decays_as_lock_runs_down() {
    // End one year out, evaluated with a fifth of a year left -> 0.04 weight.
    let now = constants::ms_per_year!() - FIFTH_YEAR_MS;
    assert_eq!(staking::power(HUNDRED_K_DEEP, constants::ms_per_year!(), now), 4_000_000_000);
}

#[test]
fun power_zero_at_lock_expiry() {
    assert_eq!(staking::power(HUNDRED_K_DEEP, 1_000, 1_000), 0);
    assert_eq!(staking::power(HUNDRED_K_DEEP, 1_000, 2_000), 0);
}

// === fee_discount_fraction: 5% per 10k tier, capped at 50% ===

#[test]
fun fee_discount_zero_just_below_first_tier() {
    assert_eq!(staking::fee_discount_fraction(constants::stake_tier_step!() - 1), 0);
}

#[test]
fun fee_discount_one_tier_is_5pct() {
    // 5% in FLOAT_SCALING.
    assert_eq!(staking::fee_discount_fraction(constants::stake_tier_step!()), 50_000_000);
}

#[test]
fun fee_discount_five_tiers_is_25pct() {
    assert_eq!(staking::fee_discount_fraction(5 * constants::stake_tier_step!()), 250_000_000);
}

#[test]
fun fee_discount_caps_at_50pct() {
    // 10 tiers = 50%; power above the top tier earns no more.
    assert_eq!(staking::fee_discount_fraction(10 * constants::stake_tier_step!()), 500_000_000);
    assert_eq!(staking::fee_discount_fraction(100 * constants::stake_tier_step!()), 500_000_000);
}

// === rebate_fraction: 10% per 10k tier, capped at 100% ===

#[test]
fun rebate_zero_just_below_first_tier() {
    assert_eq!(staking::rebate_fraction(constants::stake_tier_step!() - 1), 0);
}

#[test]
fun rebate_one_tier_is_10pct() {
    assert_eq!(staking::rebate_fraction(constants::stake_tier_step!()), 100_000_000);
}

#[test]
fun rebate_five_tiers_is_50pct() {
    assert_eq!(staking::rebate_fraction(5 * constants::stake_tier_step!()), 500_000_000);
}

#[test]
fun rebate_caps_at_100pct() {
    assert_eq!(staking::rebate_fraction(10 * constants::stake_tier_step!()), 1_000_000_000);
    assert_eq!(staking::rebate_fraction(100 * constants::stake_tier_step!()), 1_000_000_000);
}
