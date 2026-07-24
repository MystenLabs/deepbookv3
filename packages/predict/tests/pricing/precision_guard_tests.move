// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Boundary coverage for the shared numerical-certification predicate
/// (`approx::true_relative_deviation_within`). The runtime aborts the gates raise
/// are covered end-to-end by the flow tests; this pins the classification edge.
#[test_only]
module deepbook_predict::precision_guard_tests;

use deepbook_predict::plp;
use fixed_math::{approx, i64};

const EUnexpectedSuccess: u64 = 999;
const CENTER: u64 = 1_000_000_000;
// The ratified deviation bounds at 1e9 scale: 0.1% for a contract price, 1% for
// pool NAV (mirroring `max_contract_price_deviation` / `max_nav_deviation`).
const CONTRACT_MAX_DEVIATION: u64 = 1_000_000;
const NAV_MAX_DEVIATION: u64 = 10_000_000;
// Largest integer errors satisfying `error <= deviation * (center - error) / 1e9`,
// and one raw unit past each boundary.
const MAX_PRICE_ERROR: u64 = 999_000;
const PRICE_ERROR_ABOVE_MAX: u64 = 999_001;
const MAX_NAV_ERROR: u64 = 9_900_990;
const NAV_ERROR_ABOVE_MAX: u64 = 9_900_991;

#[test]
fun contract_price_at_boundary_is_within() {
    let price = approx::from_certified_parts(i64::from_u64(CENTER), MAX_PRICE_ERROR);
    assert!(price.true_relative_deviation_within(CONTRACT_MAX_DEVIATION));
}

#[test]
fun contract_price_above_boundary_is_not_within() {
    let price = approx::from_certified_parts(i64::from_u64(CENTER), PRICE_ERROR_ABOVE_MAX);
    assert!(!price.true_relative_deviation_within(CONTRACT_MAX_DEVIATION));
}

#[test]
fun pool_nav_at_boundary_is_within() {
    let nav = approx::from_certified_parts(i64::from_u64(CENTER), MAX_NAV_ERROR);
    assert!(nav.true_relative_deviation_within(NAV_MAX_DEVIATION));
}

#[test]
fun pool_nav_above_boundary_is_not_within() {
    let nav = approx::from_certified_parts(i64::from_u64(CENTER), NAV_ERROR_ABOVE_MAX);
    assert!(!nav.true_relative_deviation_within(NAV_MAX_DEVIATION));
}

#[test, expected_failure(abort_code = plp::ENavTooImprecise)]
fun pool_nav_with_unrepresentable_supply_ask_aborts() {
    let nav = approx::from_certified_parts(
        i64::from_u64(std::u64::max_value!()),
        1,
    );
    let (_, _) = plp::pool_nav_bid_ask(&nav);
    abort EUnexpectedSuccess
}
