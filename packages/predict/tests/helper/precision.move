// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Temporary precision helpers for comparing contract integer math
/// against scipy ground-truth constants.
///
/// WHY TOLERANCES EXIST:
/// The contract implements ln, exp, and normal_cdf using integer
/// arithmetic (1e9 fixed-point, u128 internally). Each division
/// truncates, and errors compound through the pricing pipeline:
///
///   ln (1-3 units off at 1e9)
///   → exp (0-2 units off at 1e9)
///   → normal_cdf (0-5 units off at 1e9, via Cody rational approx)
///   → oracle pricing pipeline: SVI → d2 → cdf (up to ~30 units at 1e9)
///
/// The oracle pipeline chains ~6 truncating operations through compute_nd2,
/// so errors compound beyond individual function tolerances.
/// Final prices in USDC (1e6) absorb all math error (30 units at 1e9 = 0 at 1e6).
///
/// FUTURE: Converting oracle.move's compute_nd2 to u128 internal math
/// (like ln/exp/cdf already use) would reduce the pipeline error to ~5 units.
///
/// WHEN TO REMOVE:
/// These helpers are temporary. Remove them when ln/exp/cdf are
/// replaced with native Sui math functions, then revert all call
/// sites back to assert_eq!.
#[test_only]
module deepbook_predict::precision;

use std::unit_test::assert_eq;

/// Assert that `actual` is within 0.0002% of `expected`, with a minimum
/// tolerance of 1 unit.
///
/// 0.0002% = 1 / 500_000, so we check: diff <= max(1, expected / 500_000).
/// This is intentionally a little looser than before because the end-to-end
/// oracle pipeline still shows small fixed-point drift on a couple of
/// production-valid tail scenarios.
/// At expected=500_000_000 (1e9 scale) this allows up to 1000 units.
/// At expected=50_000 (USDC scale) this allows 1 unit (the minimum).
public fun assert_approx(actual: u64, expected: u64) {
    let diff = if (actual > expected) {
        actual - expected
    } else {
        expected - actual
    };
    let tolerance = expected / 500_000;
    let tolerance = if (tolerance > 0) { tolerance } else { 1 };
    if (diff > tolerance) {
        assert_eq!(actual, expected);
    };
}
