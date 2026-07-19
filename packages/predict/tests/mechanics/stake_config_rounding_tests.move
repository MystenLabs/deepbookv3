// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Stake-benefit curve segments and first-positive floor rounding.
#[test_only]
module deepbook_predict::scope_mechanics__intent_rounding__stake_config_tests;

use deepbook_predict::{config_constants, stake_config};
use std::unit_test::{assert_eq, destroy};

const LOWER: u64 = 100_000_000_000;
const UPPER: u64 = 300_000_000_000;
const FEE_AMOUNT: u64 = 8;
const SMALL_FEE_AMOUNT: u64 = 4;
const ZERO_STAKE: u64 = 0;
const FIRST_SEGMENT_MIDPOINT: u64 = LOWER / 2;
const SECOND_SEGMENT_MIDPOINT: u64 = 2 * LOWER;
const ABOVE_UPPER: u64 = UPPER + 1;
const LAST_ZERO_REBATE_STAKE: u64 = FIRST_SEGMENT_MIDPOINT - 1;
const ZERO_REBATE: u64 = 0;
const QUARTER_REBATE: u64 = 2;
const HALF_REBATE: u64 = 4;
const THREE_QUARTER_REBATE: u64 = 6;
const FULL_REBATE: u64 = 8;
const ZERO_DISCOUNT_FEE: u64 = 8;
const QUARTER_DISCOUNT_FEE: u64 = 7;
const HALF_DISCOUNT_FEE: u64 = 6;
const THREE_QUARTER_DISCOUNT_FEE: u64 = 5;
const FULL_DISCOUNT_FEE: u64 = 4;
const FIRST_POSITIVE_REBATE: u64 = 1;

#[test]
fun default_curve_hits_half_and_full_benefit_thresholds() {
    let config = stake_config::new();
    assert_eq!(
        config.rebate_amount(FEE_AMOUNT, config_constants::default_lower_benefit_power!()),
        HALF_REBATE,
    );
    assert_eq!(
        config.rebate_amount(FEE_AMOUNT, config_constants::default_upper_benefit_power!()),
        FULL_REBATE,
    );
    destroy(config);
}

#[test]
fun configured_curve_hits_zero_quarter_half_three_quarters_and_full() {
    let mut config = stake_config::new();
    config.set_benefit_powers(LOWER, UPPER);
    assert_eq!(config.rebate_amount(FEE_AMOUNT, ZERO_STAKE), ZERO_REBATE);
    assert_eq!(config.rebate_amount(FEE_AMOUNT, FIRST_SEGMENT_MIDPOINT), QUARTER_REBATE);
    assert_eq!(config.rebate_amount(FEE_AMOUNT, LOWER), HALF_REBATE);
    assert_eq!(config.rebate_amount(FEE_AMOUNT, SECOND_SEGMENT_MIDPOINT), THREE_QUARTER_REBATE);
    assert_eq!(config.rebate_amount(FEE_AMOUNT, UPPER), FULL_REBATE);
    assert_eq!(config.rebate_amount(FEE_AMOUNT, ABOVE_UPPER), FULL_REBATE);
    assert_eq!(config.fee_amount_after_discount(FEE_AMOUNT, ZERO_STAKE), ZERO_DISCOUNT_FEE);
    assert_eq!(
        config.fee_amount_after_discount(FEE_AMOUNT, FIRST_SEGMENT_MIDPOINT),
        QUARTER_DISCOUNT_FEE,
    );
    assert_eq!(config.fee_amount_after_discount(FEE_AMOUNT, LOWER), HALF_DISCOUNT_FEE);
    assert_eq!(
        config.fee_amount_after_discount(FEE_AMOUNT, SECOND_SEGMENT_MIDPOINT),
        THREE_QUARTER_DISCOUNT_FEE,
    );
    assert_eq!(config.fee_amount_after_discount(FEE_AMOUNT, UPPER), FULL_DISCOUNT_FEE);
    destroy(config);
}

#[test]
fun rebate_first_positive_boundary_is_exact() {
    let mut config = stake_config::new();
    config.set_benefit_powers(LOWER, UPPER);
    assert_eq!(config.rebate_amount(SMALL_FEE_AMOUNT, LAST_ZERO_REBATE_STAKE), ZERO_REBATE);
    assert_eq!(
        config.rebate_amount(SMALL_FEE_AMOUNT, FIRST_SEGMENT_MIDPOINT),
        FIRST_POSITIVE_REBATE,
    );
    destroy(config);
}
