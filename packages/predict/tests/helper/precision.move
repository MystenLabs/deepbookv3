// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Temporary precision helpers for comparing contract integer math
/// against scipy ground-truth constants.
///
/// WHY TOLERANCES EXIST:
/// The contract implements ln, exp, and normal_cdf using integer
/// arithmetic (1e9 fixed-point). Each operation truncates, and errors
/// compound through the pricing pipeline:
///
///   ln (1-3 units off at 1e9)
///   → exp (1-36 units off at 1e9)
///   → normal_cdf (1-70 units off at 1e9)
///   → binary_price (up to 74 units off at 1e9)
///
/// However, final prices are in USDC (1e6). The 1e9→1e6 scaling
/// absorbs the math error: 74 units at 1e9 = 0.074 at 1e6 < 1 cent.
///
/// WHEN TO REMOVE:
/// These helpers are temporary. Remove them when ln/exp/cdf are
/// replaced with native Sui math functions, then revert all call
/// sites back to assert_eq!.
///
/// Run `python3 tests/generated_tests/precision_report.py` to see
/// the current gap report across all test assertions.
#[test_only]
module deepbook_predict::precision;

/// Assert that `actual` is within 0.001% of `expected`.
/// Use for math primitives (ln, exp, cdf) and oracle pricing
/// where values are at 1e9 scale.
///
/// 0.001% = 1 / 100_000, so we check: diff * 100_000 <= expected.
/// At expected=500_000_000 this allows a gap of up to 5_000 units,
/// which is well above the observed max of 74.
public fun assert_approx_rel(actual: u64, expected: u64) {
    let diff = if (actual > expected) {
        actual - expected
    } else {
        expected - actual
    };
    assert!(diff * 100_000 <= expected, 0);
}

/// Assert that `actual` is within `max_diff` units of `expected`.
/// Use for end-to-end outcomes (mint cost, redeem payout) where
/// values are at 1e6 USDC scale — the 1e9→1e6 scaling absorbs
/// math layer error, so only 1 unit of absolute tolerance is needed.
public fun assert_approx_abs(actual: u64, expected: u64, max_diff: u64) {
    let diff = if (actual > expected) {
        actual - expected
    } else {
        expected - actual
    };
    assert!(diff <= max_diff);
}
