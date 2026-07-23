// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Boundary coverage for the shared numerical-certification predicate
/// (`approx::deviation_within`). The runtime aborts the gates raise are covered
/// end-to-end by the flow tests; this pins the classification edge itself.
#[test_only]
module deepbook_predict::precision_guard_tests;

use fixed_math::{approx, i64};

const CENTER: u64 = 1_000_000_000;
// The ratified deviation bounds at 1e9 scale: 0.1% for a contract price, 1% for
// pool NAV (mirroring `max_contract_price_deviation` / `max_nav_deviation`).
const CONTRACT_MAX_DEVIATION: u64 = 1_000_000;
const NAV_MAX_DEVIATION: u64 = 10_000_000;
// 0.1% of CENTER and one raw unit past it.
const MAX_PRICE_ERROR: u64 = 1_000_000;
const PRICE_ERROR_ABOVE_MAX: u64 = 1_000_001;
// 1% of CENTER and one raw unit past it.
const MAX_NAV_ERROR: u64 = 10_000_000;
const NAV_ERROR_ABOVE_MAX: u64 = 10_000_001;

#[test]
fun contract_price_at_boundary_is_within() {
    let price = approx::from_parts(i64::from_u64(CENTER), MAX_PRICE_ERROR);
    assert!(price.deviation_within(CONTRACT_MAX_DEVIATION));
}

#[test]
fun contract_price_above_boundary_is_not_within() {
    let price = approx::from_parts(i64::from_u64(CENTER), PRICE_ERROR_ABOVE_MAX);
    assert!(!price.deviation_within(CONTRACT_MAX_DEVIATION));
}

#[test]
fun pool_nav_at_boundary_is_within() {
    let nav = approx::from_parts(i64::from_u64(CENTER), MAX_NAV_ERROR);
    assert!(nav.deviation_within(NAV_MAX_DEVIATION));
}

#[test]
fun pool_nav_above_boundary_is_not_within() {
    let nav = approx::from_parts(i64::from_u64(CENTER), NAV_ERROR_ABOVE_MAX);
    assert!(!nav.deviation_within(NAV_MAX_DEVIATION));
}
