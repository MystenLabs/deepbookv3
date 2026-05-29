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
const MAX_FEE_DISCOUNT: u64 = 500_000_000; // 50%
const MAX_REBATE: u64 = 1_000_000_000; // 100%

// === fee_discount_fraction: linear to max_fee_discount at max_benefit_power ===

#[test]
fun fee_discount_zero_without_stake() {
    assert_eq!(staking::fee_discount_fraction(0, MAX_BENEFIT_POWER, MAX_FEE_DISCOUNT), 0);
}

#[test]
fun fee_discount_scales_linearly() {
    // 10k = 10% of max -> 5%; 15k = 15% -> 7.5%; 50k = 50% -> 25%.
    assert_eq!(
        staking::fee_discount_fraction(TEN_K, MAX_BENEFIT_POWER, MAX_FEE_DISCOUNT),
        50_000_000,
    );
    assert_eq!(
        staking::fee_discount_fraction(FIFTEEN_K, MAX_BENEFIT_POWER, MAX_FEE_DISCOUNT),
        75_000_000,
    );
    assert_eq!(
        staking::fee_discount_fraction(FIFTY_K, MAX_BENEFIT_POWER, MAX_FEE_DISCOUNT),
        250_000_000,
    );
}

#[test]
fun fee_discount_caps_at_max() {
    // At the max, and above it (more stake earns no extra benefit).
    assert_eq!(
        staking::fee_discount_fraction(HUNDRED_K, MAX_BENEFIT_POWER, MAX_FEE_DISCOUNT),
        500_000_000,
    );
    assert_eq!(
        staking::fee_discount_fraction(TWO_HUNDRED_K, MAX_BENEFIT_POWER, MAX_FEE_DISCOUNT),
        500_000_000,
    );
}

#[test]
fun fee_discount_respects_configured_cap() {
    // A 25% cap: full stake -> 25%, half stake -> 12.5%.
    assert_eq!(
        staking::fee_discount_fraction(HUNDRED_K, MAX_BENEFIT_POWER, 250_000_000),
        250_000_000,
    );
    assert_eq!(
        staking::fee_discount_fraction(FIFTY_K, MAX_BENEFIT_POWER, 250_000_000),
        125_000_000,
    );
}

// === rebate_fraction: linear to max_rebate_fraction at max_benefit_power ===

#[test]
fun rebate_zero_without_stake() {
    assert_eq!(staking::rebate_fraction(0, MAX_BENEFIT_POWER, MAX_REBATE), 0);
}

#[test]
fun rebate_scales_linearly() {
    // 10k -> 10%; 15k -> 15%; 50k -> 50%.
    assert_eq!(staking::rebate_fraction(TEN_K, MAX_BENEFIT_POWER, MAX_REBATE), 100_000_000);
    assert_eq!(staking::rebate_fraction(FIFTEEN_K, MAX_BENEFIT_POWER, MAX_REBATE), 150_000_000);
    assert_eq!(staking::rebate_fraction(FIFTY_K, MAX_BENEFIT_POWER, MAX_REBATE), 500_000_000);
}

#[test]
fun rebate_caps_at_max() {
    assert_eq!(staking::rebate_fraction(HUNDRED_K, MAX_BENEFIT_POWER, MAX_REBATE), 1_000_000_000);
    assert_eq!(
        staking::rebate_fraction(TWO_HUNDRED_K, MAX_BENEFIT_POWER, MAX_REBATE),
        1_000_000_000,
    );
}

#[test]
fun rebate_respects_configured_cap() {
    // A 50% cap: full stake -> 50%, half stake -> 25%.
    assert_eq!(staking::rebate_fraction(HUNDRED_K, MAX_BENEFIT_POWER, 500_000_000), 500_000_000);
    assert_eq!(staking::rebate_fraction(FIFTY_K, MAX_BENEFIT_POWER, 500_000_000), 250_000_000);
}

#[test]
fun benefit_threshold_is_configurable() {
    // Halving the threshold doubles the benefit at a given stake: 10k against a
    // 50k threshold = 20% of max -> 10% fee discount, 20% rebate.
    assert_eq!(staking::fee_discount_fraction(TEN_K, FIFTY_K, MAX_FEE_DISCOUNT), 100_000_000);
    assert_eq!(staking::rebate_fraction(TEN_K, FIFTY_K, MAX_REBATE), 200_000_000);
}
