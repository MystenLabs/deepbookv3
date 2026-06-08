// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::plp_tests;

use deepbook_predict::{math::float_scaling as float, plp};
use std::unit_test::assert_eq;

const NAV_OPTIMISTIC: u64 = 1_000;
const FULLY_VERIFIED_RANGE: u64 = 300;
const FULLY_VERIFIED_FLOOR: u64 = 100;
const NOTHING_VERIFIED_RANGE: u64 = 80;
const NOTHING_VERIFIED_FLOOR: u64 = 120;
/// D_max = 120, unscanned_range = 80, Q = 40, NAV = 1_000 - 40.
const NOTHING_VERIFIED_NAV: u64 = 960;

const CLOSED_FORM_NAV_OPTIMISTIC: u64 = 900;
const CLOSED_FORM_TOTAL_RANGE: u64 = 350;
const CLOSED_FORM_TOTAL_FLOOR: u64 = 300;
const CLOSED_FORM_VERIFIED_RANGE: u64 = 300;
const CLOSED_FORM_VERIFIED_FLOOR: u64 = 100;
/// cash_minus_rebate = 950 because nav_optimistic = 950 - (350 - 300).
/// Q = (300 - 100) - (350 - 300) = 150, so conservative NAV = 900 - 150.
/// Closed form: 950 - (300 - 100) = 750.
const CLOSED_FORM_NAV: u64 = 750;

const NET_ITM_NAV_OPTIMISTIC: u64 = 900;
const NET_ITM_TOTAL_RANGE: u64 = 350;
const NET_ITM_TOTAL_FLOOR: u64 = 200;
const NET_ITM_VERIFIED_RANGE: u64 = 100;
const NET_ITM_VERIFIED_FLOOR: u64 = 50;

const WITHDRAW_FEE_ALPHA_25_PCT: u64 = 250_000_000;
const HIGH_BAND: u64 = 10_000;
const FEE_TEST_LP_AMOUNT: u64 = 100;
const FEE_TEST_TOTAL_SUPPLY: u64 = 1_000;
const FEE_TEST_GROSS_PAYOUT: u64 = 500;
const FEE_TEST_NAV_CAP: u64 = 125;

// `protocol_reserve_profit_share` is 1e9-scaled (`float!()` == 1.0).
// `plp::lp_pool_value(idle, credits, debits, share, active)` returns the
// LP-attributable pool value = max(0, gross - exclusion), where
// gross = idle + active and exclusion = share * max(0, (credits + active) - debits).
// Expected values below are derived by hand from that definition.

#[test]
fun conservative_active_nav_fully_verified_keeps_optimistic_nav() {
    // verified == total:
    //   D_max = max(0, 100 - 100) = 0
    //   Q = 0
    assert_eq!(
        plp::conservative_active_nav(
            NAV_OPTIMISTIC,
            FULLY_VERIFIED_RANGE,
            FULLY_VERIFIED_FLOOR,
            FULLY_VERIFIED_RANGE,
            FULLY_VERIFIED_FLOOR,
        ),
        NAV_OPTIMISTIC,
    );
}

#[test]
fun conservative_active_nav_nothing_verified_haircuts_net_underwater() {
    // nothing verified:
    //   D_max = 120
    //   unscanned_range = 80
    //   Q = 40
    assert_eq!(
        plp::conservative_active_nav(
            NAV_OPTIMISTIC,
            NOTHING_VERIFIED_RANGE,
            NOTHING_VERIFIED_FLOOR,
            0,
            0,
        ),
        NOTHING_VERIFIED_NAV,
    );
}

#[test]
fun conservative_active_nav_q_positive_matches_closed_form() {
    // Q > 0:
    //   total_range - total_floor = 350 - 300 = 50
    //   cash_minus_rebate = nav_optimistic + liability = 900 + 50 = 950
    //   survivor exact liability = verified_range - verified_floor = 300 - 100 = 200
    //   conservative NAV = 950 - 200 = 750
    assert_eq!(
        plp::conservative_active_nav(
            CLOSED_FORM_NAV_OPTIMISTIC,
            CLOSED_FORM_TOTAL_RANGE,
            CLOSED_FORM_TOTAL_FLOOR,
            CLOSED_FORM_VERIFIED_RANGE,
            CLOSED_FORM_VERIFIED_FLOOR,
        ),
        CLOSED_FORM_NAV,
    );
}

#[test]
fun conservative_active_nav_net_itm_unscanned_keeps_optimistic_nav() {
    // unscanned borrowed amount is covered by unscanned option value:
    //   D_max = 200 - 50 = 150
    //   unscanned_range = 350 - 100 = 250
    //   Q = max(0, 150 - 250) = 0
    assert_eq!(
        plp::conservative_active_nav(
            NET_ITM_NAV_OPTIMISTIC,
            NET_ITM_TOTAL_RANGE,
            NET_ITM_TOTAL_FLOOR,
            NET_ITM_VERIFIED_RANGE,
            NET_ITM_VERIFIED_FLOOR,
        ),
        NET_ITM_NAV_OPTIMISTIC,
    );
}

#[test]
fun conservative_active_nav_haircut_exceeding_optimistic_floors_at_zero() {
    // Stress: the unverified-underwater haircut Q exceeds the optimistic NAV, so
    // the active expiry must contribute 0 (never negative — the final subtraction
    // must saturate, not underflow-brick the whole sync).
    //   nav_optimistic = 30, total_floor = 100, verified = 0 -> D_max = 100
    //   unscanned_range = 0 - 0 = 0 -> Q = 100 ; result = max(0, 30 - 100) = 0
    assert_eq!(plp::conservative_active_nav(30, 0, 100, 0, 0), 0);
}

#[test]
fun conservative_active_nav_haircut_equal_to_optimistic_is_zero() {
    // Boundary: Q == nav_optimistic exactly -> 0.
    //   nav_optimistic = 100, total_floor = 200, verified = 0 -> D_max = 200
    //   unscanned_range = 100 - 0 = 100 -> Q = 100 ; result = 100 - 100 = 0
    assert_eq!(plp::conservative_active_nav(100, 100, 200, 0, 0), 0);
}

#[test]
fun withdraw_fee_caps_to_alpha_times_gross_payout() {
    // Band fee = 25% * 10_000 * 10% = 250.
    // NAV cap  = 25% * 500 = 125.
    assert_eq!(
        plp::withdraw_fee(
            WITHDRAW_FEE_ALPHA_25_PCT,
            HIGH_BAND,
            FEE_TEST_LP_AMOUNT,
            FEE_TEST_TOTAL_SUPPLY,
            FEE_TEST_GROSS_PAYOUT,
        ),
        FEE_TEST_NAV_CAP,
    );
}

#[test]
fun lp_pool_value_floors_at_zero_when_exclusion_exceeds_gross() {
    // Documented R1 underflow scenario: an LP withdrew realized idle cash against a
    // high active mark, draining idle to 0; the active mark then collapsed (traders
    // won). The realized-profit exclusion `share * (credits - debits)` is sticky and
    // survives, so exclusion > gross. LP value must floor at 0, not underflow-abort
    // (which would brick all PLP supply/withdraw pool-wide).
    //   idle = 0, credits = 900, debits = 800, share = 50%, active = 0
    //   gross     = 0 + 0 = 0
    //   exclusion = 50% * ((900 + 0) - 800) = 0.5 * 100 = 50
    //   lp value  = max(0, 0 - 50) = 0
    let half_share = float!() / 2;
    assert_eq!(plp::lp_pool_value(0, 900, 800, half_share, 0), 0);
}

#[test]
fun lp_pool_value_excludes_protocol_profit_share() {
    // Realized profit of 200 swept to idle; protocol's 50% share is excluded.
    //   idle = 1000, credits = 200, debits = 0, share = 50%, active = 0
    //   gross     = 1000
    //   exclusion = 50% * ((200 + 0) - 0) = 100
    //   lp value  = 1000 - 100 = 900
    let half_share = float!() / 2;
    assert_eq!(plp::lp_pool_value(1000, 200, 0, half_share, 0), 900);
}

#[test]
fun lp_pool_value_counts_active_mark_before_collapse() {
    // Same accounting as the floor scenario but BEFORE the active mark collapses:
    // the live mark props up gross, so lp value is positive (no clamp).
    //   idle = 0, credits = 100, debits = 0, share = 50%, active = 300
    //   gross     = 0 + 300 = 300
    //   exclusion = 50% * ((100 + 300) - 0) = 200
    //   lp value  = 300 - 200 = 100
    let half_share = float!() / 2;
    assert_eq!(plp::lp_pool_value(0, 100, 0, half_share, 300), 100);
}

#[test]
fun lp_pool_value_no_exclusion_when_credits_below_debits() {
    // More cash sent than received (pool net-funded an expiry): no pending profit,
    // so nothing is excluded and lp value is the full gross.
    //   idle = 1000, credits = 50, debits = 100, share = 50%, active = 0
    //   gross     = 1000; (credits + active) = 50 <= debits 100 -> exclusion = 0
    //   lp value  = 1000
    let half_share = float!() / 2;
    assert_eq!(plp::lp_pool_value(1000, 50, 100, half_share, 0), 1000);
}

#[test]
fun lp_pool_value_floors_at_zero_when_exclusion_equals_gross() {
    // Boundary: exclusion clamps to exactly gross (positive gross) -> lp value 0.
    //   idle = 50, credits = 100, debits = 0, share = 100%, active = 0
    //   gross     = 50
    //   exclusion = 100% * (100 - 0) = 100, clamped to gross 50
    //   lp value  = 50 - 50 = 0
    let full_share = float!();
    assert_eq!(plp::lp_pool_value(50, 100, 0, full_share, 0), 0);
}
