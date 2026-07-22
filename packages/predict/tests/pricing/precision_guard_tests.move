// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Boundary coverage for the runtime numerical-certification guards.
#[test_only]
module deepbook_predict::precision_guard_tests;

use deepbook_predict::{plp, strike_exposure};
use fixed_math::{approx, i64};
use std::unit_test::assert_eq;

const E_UNEXPECTED_SUCCESS: u64 = 999;
const CENTER: u64 = 1_000_000_000;
// 0.1% of CENTER, hand-derived: 1_000_000_000 * 0.001 = 1_000_000.
const MAX_PRICE_ERROR: u64 = 1_000_000;
const PRICE_ERROR_ABOVE_MAX: u64 = 1_000_001;
// 1% of CENTER, hand-derived: 1_000_000_000 * 0.01 = 10_000_000.
const MAX_NAV_ERROR: u64 = 10_000_000;
const NAV_ERROR_ABOVE_MAX: u64 = 10_000_001;

#[test]
fun contract_price_precision_at_boundary_is_admitted() {
    assert_eq!(strike_exposure::max_contract_price_error(CENTER), MAX_PRICE_ERROR);
    let price = approx::from_parts(i64::from_u64(CENTER), MAX_PRICE_ERROR);
    strike_exposure::assert_contract_price_precision(&price);
}

#[test, expected_failure(abort_code = strike_exposure::EPriceTooImprecise)]
fun contract_price_precision_above_boundary_aborts() {
    let price = approx::from_parts(i64::from_u64(CENTER), PRICE_ERROR_ABOVE_MAX);
    strike_exposure::assert_contract_price_precision(&price);
    abort E_UNEXPECTED_SUCCESS
}

#[test]
fun pool_nav_precision_at_boundary_is_admitted() {
    assert_eq!(plp::max_nav_error(CENTER), MAX_NAV_ERROR);
    let nav = approx::from_parts(i64::from_u64(CENTER), MAX_NAV_ERROR);
    plp::assert_nav_precision(&nav);
}

#[test, expected_failure(abort_code = plp::ENavTooImprecise)]
fun pool_nav_precision_above_boundary_aborts() {
    let nav = approx::from_parts(i64::from_u64(CENTER), NAV_ERROR_ABOVE_MAX);
    plp::assert_nav_precision(&nav);
    abort E_UNEXPECTED_SUCCESS
}
