// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::pricing_config_tests;

use deepbook_predict::{constants, pricing_config};
use std::unit_test::assert_eq;

const HALF_PRICE: u64 = 500_000_000;
const ONE_CENT_PRICE: u64 = 10_000_000;
const NO_LIABILITY: u64 = 0;
const FULL_UTILIZATION_LIABILITY: u64 = 1_000_000;
const FULL_UTILIZATION_BALANCE: u64 = 1_000_000;

const HALF_PRICE_BASE_FEE: u64 = 10_000_000; // 2% * sqrt(50% * 50%) = 1%.
const HALF_PRICE_FULL_UTILIZATION_FEE: u64 = 50_000_000;

#[test]
fun defaults_expose_fee_terms() {
    let config = pricing_config::new();

    assert_eq!(config.base_fee(), constants::default_base_fee!());
    assert_eq!(config.min_fee(), constants::default_min_fee!());
    config.destroy_for_testing();
}

#[test]
fun quote_fee_rate_uses_current_fee_math_without_liability() {
    let config = pricing_config::new();

    let fee_rate = config.quote_fee_rate_from_fair_price(
        HALF_PRICE,
        NO_LIABILITY,
        FULL_UTILIZATION_BALANCE,
    );

    assert_eq!(fee_rate, HALF_PRICE_BASE_FEE);
    config.destroy_for_testing();
}

#[test]
fun quote_fee_rate_applies_minimum_fee_floor() {
    let config = pricing_config::new();

    let fee_rate = config.quote_fee_rate_from_fair_price(
        ONE_CENT_PRICE,
        NO_LIABILITY,
        FULL_UTILIZATION_BALANCE,
    );

    assert_eq!(fee_rate, constants::default_min_fee!());
    config.destroy_for_testing();
}

#[test]
fun quote_fee_rate_includes_utilization_fee() {
    let config = pricing_config::new();

    let fee_rate = config.quote_fee_rate_from_fair_price(
        HALF_PRICE,
        FULL_UTILIZATION_LIABILITY,
        FULL_UTILIZATION_BALANCE,
    );

    assert_eq!(fee_rate, HALF_PRICE_FULL_UTILIZATION_FEE);
    config.destroy_for_testing();
}
