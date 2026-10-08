// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Hand-worked cash-need formulas. Probabilities and lambda are 1e9-scaled.
#[test_only]
module deepbook_predict::cash_need_tests;

use deepbook_predict::order_queue;
use std::unit_test::assert_eq;

/// p_min = 0.01, the spec's launch minimum entry probability.
const P_MIN_ONE_PERCENT: u64 = 10_000_000;
/// p_min = 0.3, so 1 / p - 1 = 7 / 3 is not a whole number.
const P_MIN_THIRTY_PERCENT: u64 = 300_000_000;
const P_HALF: u64 = 500_000_000;
/// The largest minimum entry probability the config allows, 1 - 1e-9.
const P_MAX: u64 = 999_999_999;
/// lambda = 0.31, the default backing buffer.
const LAMBDA_DEFAULT: u64 = 310_000_000;
const LAMBDA_ONE: u64 = 1_000_000_000;

const ONE_USDC: u64 = 1_000_000;

// === Exact quantity: ceil(q * (1 - p_min)) + 1 ===

#[test]
fun exact_quantity_whole_product_adds_one() {
    // 1_000_000 * 0.99 = 990_000 exactly, plus 1.
    assert_eq!(order_queue::cash_need_exact_quantity(ONE_USDC, P_MIN_ONE_PERCENT), 990_001);
}

#[test]
fun exact_quantity_rounds_a_fraction_up() {
    // 1_000_001 * 0.99 = 990_000.99, ceil 990_001, plus 1.
    assert_eq!(order_queue::cash_need_exact_quantity(ONE_USDC + 1, P_MIN_ONE_PERCENT), 990_002);
    // 3 * 0.5 = 1.5, ceil 2, plus 1.
    assert_eq!(order_queue::cash_need_exact_quantity(3, P_HALF), 3);
}

#[test]
fun exact_quantity_zero_and_max_probability() {
    // 0 * 0.99 = 0, plus 1.
    assert_eq!(order_queue::cash_need_exact_quantity(0, P_MIN_ONE_PERCENT), 1);
    // 1_000_000 * 1e-9 = 0.001, ceil 1, plus 1.
    assert_eq!(order_queue::cash_need_exact_quantity(ONE_USDC, P_MAX), 2);
}

// === Budget: ceil((b + 1) * (1 / p_min - 1)) + 1 ===

#[test]
fun budget_whole_product_adds_one() {
    // (1_000_000 + 1) * (100 - 1) = 99_000_099 exactly, plus 1.
    assert_eq!(order_queue::cash_need_budget(ONE_USDC, P_MIN_ONE_PERCENT), 99_000_100);
}

#[test]
fun budget_rounds_a_fraction_up() {
    // (999 + 1) * (1 / 0.3 - 1) = 1000 * 7 / 3 = 2333.33..., ceil 2334, plus 1.
    assert_eq!(order_queue::cash_need_budget(999, P_MIN_THIRTY_PERCENT), 2_335);
}

#[test]
fun budget_zero_still_covers_one_raw_unit() {
    // (0 + 1) * 99 = 99, plus 1.
    assert_eq!(order_queue::cash_need_budget(0, P_MIN_ONE_PERCENT), 100);
    // (0 + 1) * (1 / (1 - 1e-9) - 1) = 1e-9 / (1 - 1e-9), ceil 1, plus 1.
    assert_eq!(order_queue::cash_need_budget(0, P_MAX), 2);
}

// === Sell: ceil(q * (1 - lambda)) + 1 ===

#[test]
fun sell_whole_product_adds_one() {
    // 1_000_000 * 0.69 = 690_000 exactly, plus 1.
    assert_eq!(order_queue::cash_need_sell(ONE_USDC, LAMBDA_DEFAULT), 690_001);
}

#[test]
fun sell_rounds_a_fraction_up() {
    // 1_000_001 * 0.69 = 690_000.69, ceil 690_001, plus 1.
    assert_eq!(order_queue::cash_need_sell(ONE_USDC + 1, LAMBDA_DEFAULT), 690_002);
}

#[test]
fun sell_full_lambda_needs_only_the_extra_unit() {
    // 1_000_000 * (1 - 1) = 0, plus 1.
    assert_eq!(order_queue::cash_need_sell(ONE_USDC, LAMBDA_ONE), 1);
}
