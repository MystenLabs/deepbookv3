// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Exact unit coverage for the flush's pure share-pricing math: `supply_shares`
/// (DUSDC -> PLP) and `withdraw_dusdc` (PLP -> DUSDC). Every expected value is the
/// long-division result computed by hand in the comment, independent of the
/// contract's `mul_div_down`. Covers bootstrap, proportional rounding-down,
/// wiped-pool (value 0), zero-supply, and dust-below-one edges.
#[test_only]
module deepbook_predict::lp_share_math_tests;

use deepbook_predict::plp;
use std::unit_test::assert_eq;

// === supply_shares ===

#[test]
fun bootstrap_mints_one_to_one() {
    // No shares yet and an empty NAV: the first supplier mints 1:1.
    assert_eq!(plp::supply_shares(10_000_000, 0, 0), 10_000_000);
}

#[test, expected_failure(abort_code = deepbook_predict::plp::EBootstrapNavNotEmpty)]
fun bootstrap_with_nonempty_nav_aborts() {
    // Zero shares but a positive NAV is a broken invariant: minting 1:1 would be
    // mispriced, so the bootstrap branch aborts rather than mint free shares.
    let _ = plp::supply_shares(10_000_000, 0, 1);
    abort 999
}

#[test]
fun priced_supply_rounds_down() {
    // 1_000_000 DUSDC at mark = value/supply = 7e6/3e6:
    //   1_000_000 * 3_000_000 / 7_000_000 = 3e12 / 7e6 = 428_571.43 -> 428_571
    assert_eq!(plp::supply_shares(1_000_000, 3_000_000, 7_000_000), 428_571);
}

#[test]
fun exact_supply_no_rounding() {
    // 2_000_000 * 3_000_000 / 6_000_000 = 6e12 / 6e6 = 1_000_000 exactly.
    assert_eq!(plp::supply_shares(2_000_000, 3_000_000, 6_000_000), 1_000_000);
}

#[test]
fun wiped_pool_yields_zero_shares() {
    // Shares outstanding but value collapsed to 0: cannot price, so 0 shares
    // (the caller refunds the supply instead of minting).
    assert_eq!(plp::supply_shares(10_000_000, 5_000_000, 0), 0);
}

#[test]
fun dust_supply_below_one_share_rounds_to_zero() {
    // amount * supply < value: 5 * 1_000_000 = 5e6 < 5_000_001 -> 0 shares.
    assert_eq!(plp::supply_shares(5, 1_000_000, 5_000_001), 0);
}

// === withdraw_dusdc ===

#[test]
fun proportional_withdraw_rounds_down() {
    // 1_000_000 PLP at mark = value/supply = 5e6/3e6:
    //   1_000_000 * 5_000_000 / 3_000_000 = 5e12 / 3e6 = 1_666_666.67 -> 1_666_666
    assert_eq!(plp::withdraw_dusdc(1_000_000, 3_000_000, 5_000_000), 1_666_666);
}

#[test]
fun exact_withdraw_no_rounding() {
    // 2_000_000 * 6_000_000 / 4_000_000 = 12e12 / 4e6 = 3_000_000 exactly.
    assert_eq!(plp::withdraw_dusdc(2_000_000, 4_000_000, 6_000_000), 3_000_000);
}

#[test]
fun zero_supply_yields_zero_dusdc() {
    // No shares can exist to redeem against a zero supply.
    assert_eq!(plp::withdraw_dusdc(1_000_000, 0, 5_000_000), 0);
}

#[test]
fun wiped_pool_yields_zero_dusdc() {
    // Value collapsed to 0: the redemption pays nothing (caller refunds the PLP).
    assert_eq!(plp::withdraw_dusdc(1_000_000, 3_000_000, 0), 0);
}
