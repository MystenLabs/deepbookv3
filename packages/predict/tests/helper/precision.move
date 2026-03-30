// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Temporary precision helpers for comparing contract integer math
/// against scipy ground-truth constants.
///
/// WHY TOLERANCES EXIST:
/// The contract implements ln, exp, and normal_cdf using integer
/// arithmetic (1e9 fixed-point, u128 internally). Each division
/// truncates, and errors compound through the pricing pipeline.
/// With Cody's rational CDF approximation, the error chain is:
///
///   ln (1-3 units off at 1e9)
///   → exp (0-2 units off at 1e9)
///   → normal_cdf (0-5 units off at 1e9, via Cody rational approx)
///   → binary_price (up to ~10 units off at 1e9)
///
/// Final prices in USDC (1e6) absorb most math error.
///
/// WHEN TO REMOVE:
/// These helpers are temporary. Remove them when ln/exp/cdf are
/// replaced with native Sui math functions, then revert all call
/// sites back to assert_eq!.
#[test_only]
module deepbook_predict::precision;

/// Assert that `actual` is within 0.00001% of `expected`, with a minimum
/// tolerance of 1 unit. Use for all precision comparisons across scales.
///
/// 0.00001% = 1 / 10_000_000, so we check: diff <= max(1, expected / 10_000_000).
/// At expected=1_000_000_000 (1e9 scale) this allows up to 100 units.
/// At expected=500_000_000 this allows 50 units.
/// At expected=50_000 (USDC scale) this allows 1 unit (the minimum).
public fun assert_approx(actual: u64, expected: u64) {
    let diff = if (actual > expected) {
        actual - expected
    } else {
        expected - actual
    };
    let tolerance = expected / 10_000_000;
    let tolerance = if (tolerance > 0) { tolerance } else { 1 };
    assert!(diff <= tolerance);
}
