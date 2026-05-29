// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::staking_tests;

use deepbook_predict::staking;
use std::unit_test::assert_eq;

// Active-stake levels in raw DEEP units (DEEP has 6 decimals).
const TWENTY_K: u64 = 20_000_000_000;
const LOWER: u64 = 100_000_000_000; // 100k DEEP, default lower threshold (50% of max)
const THREE_HUNDRED_K: u64 = 300_000_000_000;
const UPPER: u64 = 1_100_000_000_000; // 1.1M DEEP, default upper threshold (100% of max)
const TWO_MILLION: u64 = 2_000_000_000_000;
const MAX_FEE_DISCOUNT: u64 = 500_000_000; // 50%
const MAX_REBATE: u64 = 1_000_000_000; // 100%

// === fee_discount_fraction: two-segment curve scaled by max_fee_discount ===

#[test]
fun fee_discount_zero_without_stake() {
    assert_eq!(staking::fee_discount_fraction(0, LOWER, UPPER, MAX_FEE_DISCOUNT), 0);
}

#[test]
fun fee_discount_lower_segment() {
    // 20k of a 100k lower -> ratio 0.5*0.2 = 0.1 -> 0.1 * 50% = 5%.
    assert_eq!(
        staking::fee_discount_fraction(TWENTY_K, LOWER, UPPER, MAX_FEE_DISCOUNT),
        50_000_000,
    );
    // At the kink (100k) -> ratio 0.5 -> 25%.
    assert_eq!(staking::fee_discount_fraction(LOWER, LOWER, UPPER, MAX_FEE_DISCOUNT), 250_000_000);
}

#[test]
fun fee_discount_upper_segment() {
    // 300k: 200k into a 1M upper segment -> ratio 0.5 + 0.5*0.2 = 0.6 -> 30%.
    assert_eq!(
        staking::fee_discount_fraction(THREE_HUNDRED_K, LOWER, UPPER, MAX_FEE_DISCOUNT),
        300_000_000,
    );
}

#[test]
fun fee_discount_caps_at_upper() {
    // At upper (1.1M) and above -> ratio 1.0 -> 50%.
    assert_eq!(staking::fee_discount_fraction(UPPER, LOWER, UPPER, MAX_FEE_DISCOUNT), 500_000_000);
    assert_eq!(
        staking::fee_discount_fraction(TWO_MILLION, LOWER, UPPER, MAX_FEE_DISCOUNT),
        500_000_000,
    );
}

#[test]
fun fee_discount_respects_configured_cap() {
    // 25% cap: full stake -> 25%, kink -> 12.5%.
    assert_eq!(staking::fee_discount_fraction(UPPER, LOWER, UPPER, 250_000_000), 250_000_000);
    assert_eq!(staking::fee_discount_fraction(LOWER, LOWER, UPPER, 250_000_000), 125_000_000);
}

// === rebate_fraction: two-segment curve scaled by max_rebate_fraction ===

#[test]
fun rebate_zero_without_stake() {
    assert_eq!(staking::rebate_fraction(0, LOWER, UPPER, MAX_REBATE), 0);
}

#[test]
fun rebate_lower_segment() {
    // 20k -> ratio 0.1 -> 10%; kink -> ratio 0.5 -> 50%.
    assert_eq!(staking::rebate_fraction(TWENTY_K, LOWER, UPPER, MAX_REBATE), 100_000_000);
    assert_eq!(staking::rebate_fraction(LOWER, LOWER, UPPER, MAX_REBATE), 500_000_000);
}

#[test]
fun rebate_upper_segment() {
    // 300k -> ratio 0.6 -> 60%.
    assert_eq!(staking::rebate_fraction(THREE_HUNDRED_K, LOWER, UPPER, MAX_REBATE), 600_000_000);
}

#[test]
fun rebate_caps_at_upper() {
    assert_eq!(staking::rebate_fraction(UPPER, LOWER, UPPER, MAX_REBATE), 1_000_000_000);
    assert_eq!(staking::rebate_fraction(TWO_MILLION, LOWER, UPPER, MAX_REBATE), 1_000_000_000);
}

#[test]
fun rebate_respects_configured_cap() {
    // 50% cap: full stake -> 50%, kink -> 25%.
    assert_eq!(staking::rebate_fraction(UPPER, LOWER, UPPER, 500_000_000), 500_000_000);
    assert_eq!(staking::rebate_fraction(LOWER, LOWER, UPPER, 500_000_000), 250_000_000);
}
