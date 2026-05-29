// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::staking_tests;

use deepbook_predict::staking;
use std::unit_test::assert_eq;

// Active-stake levels in raw DEEP units (DEEP has 6 decimals).
const TEN_K: u64 = 10_000_000_000;
const FIFTEEN_K: u64 = 15_000_000_000;
const FIFTY_K: u64 = 50_000_000_000;
const HUNDRED_K: u64 = 100_000_000_000; // == default max_benefit_power
const TWO_HUNDRED_K: u64 = 200_000_000_000;
const MAX_BENEFIT_POWER: u64 = 100_000_000_000;

// === fee_discount_fraction: linear to 50% at max_benefit_power ===

#[test]
fun fee_discount_zero_without_stake() {
    assert_eq!(staking::fee_discount_fraction(0, MAX_BENEFIT_POWER), 0);
}

#[test]
fun fee_discount_scales_linearly() {
    // 10k = 10% of max -> 5%; 15k = 15% -> 7.5%; 50k = 50% -> 25%.
    assert_eq!(staking::fee_discount_fraction(TEN_K, MAX_BENEFIT_POWER), 50_000_000);
    assert_eq!(staking::fee_discount_fraction(FIFTEEN_K, MAX_BENEFIT_POWER), 75_000_000);
    assert_eq!(staking::fee_discount_fraction(FIFTY_K, MAX_BENEFIT_POWER), 250_000_000);
}

#[test]
fun fee_discount_caps_at_50pct() {
    // At the max, and above it (more stake earns no extra benefit).
    assert_eq!(staking::fee_discount_fraction(HUNDRED_K, MAX_BENEFIT_POWER), 500_000_000);
    assert_eq!(staking::fee_discount_fraction(TWO_HUNDRED_K, MAX_BENEFIT_POWER), 500_000_000);
}

// === rebate_fraction: linear to 100% at max_benefit_power ===

#[test]
fun rebate_zero_without_stake() {
    assert_eq!(staking::rebate_fraction(0, MAX_BENEFIT_POWER), 0);
}

#[test]
fun rebate_scales_linearly() {
    // 10k -> 10%; 15k -> 15%; 50k -> 50%.
    assert_eq!(staking::rebate_fraction(TEN_K, MAX_BENEFIT_POWER), 100_000_000);
    assert_eq!(staking::rebate_fraction(FIFTEEN_K, MAX_BENEFIT_POWER), 150_000_000);
    assert_eq!(staking::rebate_fraction(FIFTY_K, MAX_BENEFIT_POWER), 500_000_000);
}

#[test]
fun rebate_caps_at_100pct() {
    assert_eq!(staking::rebate_fraction(HUNDRED_K, MAX_BENEFIT_POWER), 1_000_000_000);
    assert_eq!(staking::rebate_fraction(TWO_HUNDRED_K, MAX_BENEFIT_POWER), 1_000_000_000);
}

#[test]
fun benefit_threshold_is_configurable() {
    // Halving the threshold doubles the benefit at a given stake: 10k against a
    // 50k threshold = 20% of max -> 10% fee discount, 20% rebate.
    assert_eq!(staking::fee_discount_fraction(TEN_K, FIFTY_K), 100_000_000);
    assert_eq!(staking::rebate_fraction(TEN_K, FIFTY_K), 200_000_000);
}
