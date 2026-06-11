// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::plp_tests;

use deepbook_predict::plp;
use predict_math::math::float_scaling as float;
use std::unit_test::assert_eq;

const FREE_CASH: u64 = 1_200;
const FULLY_VERIFIED_RANGE: u64 = 300;
const FULLY_VERIFIED_FLOOR: u64 = 100;
const SATURATED_FREE_CASH: u64 = 1_000;
const SATURATED_TOTAL_RANGE: u64 = 80;
const SATURATED_TOTAL_FLOOR: u64 = 120;
const SATURATED_NAV: u64 = 1_000;
const SATURATED_BAND: u64 = 80;

const CLOSED_FORM_FREE_CASH: u64 = 950;
const CLOSED_FORM_TOTAL_RANGE: u64 = 350;
const CLOSED_FORM_TOTAL_FLOOR: u64 = 300;
const CLOSED_FORM_VERIFIED_RANGE: u64 = 300;
const CLOSED_FORM_VERIFIED_FLOOR: u64 = 100;
const CLOSED_FORM_NAV: u64 = 750;
const CLOSED_FORM_BAND: u64 = 50;

const NET_ITM_FREE_CASH: u64 = 1_050;
const NET_ITM_TOTAL_RANGE: u64 = 350;
const NET_ITM_TOTAL_FLOOR: u64 = 200;
const NET_ITM_VERIFIED_RANGE: u64 = 100;
const NET_ITM_VERIFIED_FLOOR: u64 = 50;
const NET_ITM_NAV: u64 = 900;
const NET_ITM_BAND: u64 = 150;

const LOW_FREE_CASH: u64 = 50;
const HIGH_LIABILITY_RANGE: u64 = 300;
const HIGH_LIABILITY_FLOOR: u64 = 100;

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
fun active_expiry_nav_and_band_fully_verified_charges_verified_liability() {
    // verified == total:
    //   supply liability = 300 - 100 = 200
    //   NAV = 1_200 - 200 = 1_000
    //   band = 0
    let (nav, band) = plp::active_expiry_nav_and_band(
        FREE_CASH,
        FULLY_VERIFIED_RANGE,
        FULLY_VERIFIED_FLOOR,
        FULLY_VERIFIED_RANGE,
        FULLY_VERIFIED_FLOOR,
    );
    assert_eq!(nav, 1_000);
    assert_eq!(band, 0);
}

#[test]
fun active_expiry_nav_and_band_saturated_unscanned_floor_keeps_supply_mark_high() {
    // Regression: aggregate-clamped liability is 0 because total_floor > total_range.
    // The unscanned bucket cannot create negative liability, so supply NAV stays at
    // free cash while the withdraw band records the recoverable unscanned floor.
    let (nav, band) = plp::active_expiry_nav_and_band(
        SATURATED_FREE_CASH,
        SATURATED_TOTAL_RANGE,
        SATURATED_TOTAL_FLOOR,
        0,
        0,
    );
    assert_eq!(nav, SATURATED_NAV);
    assert_eq!(band, SATURATED_BAND);
}

#[test]
fun active_expiry_nav_and_band_charges_verified_liability_before_unscanned_floor() {
    // verified liability = 300 - 100 = 200
    // unscanned range/floor = 50/200, so unscanned liability = 0 and band = 50
    // NAV = 950 - 200 = 750
    let (nav, band) = plp::active_expiry_nav_and_band(
        CLOSED_FORM_FREE_CASH,
        CLOSED_FORM_TOTAL_RANGE,
        CLOSED_FORM_TOTAL_FLOOR,
        CLOSED_FORM_VERIFIED_RANGE,
        CLOSED_FORM_VERIFIED_FLOOR,
    );
    assert_eq!(nav, CLOSED_FORM_NAV);
    assert_eq!(band, CLOSED_FORM_BAND);
}

#[test]
fun active_expiry_nav_and_band_charges_unscanned_liability_net_of_its_own_floor() {
    // verified liability = 100 - 50 = 50
    // unscanned range/floor = 250/150, so unscanned liability = 100 and band = 150
    // NAV = 1_050 - 150 = 900
    let (nav, band) = plp::active_expiry_nav_and_band(
        NET_ITM_FREE_CASH,
        NET_ITM_TOTAL_RANGE,
        NET_ITM_TOTAL_FLOOR,
        NET_ITM_VERIFIED_RANGE,
        NET_ITM_VERIFIED_FLOOR,
    );
    assert_eq!(nav, NET_ITM_NAV);
    assert_eq!(band, NET_ITM_BAND);
}

#[test]
fun active_expiry_nav_and_band_floors_at_zero_when_liability_exceeds_free_cash() {
    // verified liability = 300 - 100 = 200, free cash = 50 -> NAV floors at 0.
    let (nav, band) = plp::active_expiry_nav_and_band(
        LOW_FREE_CASH,
        HIGH_LIABILITY_RANGE,
        HIGH_LIABILITY_FLOOR,
        HIGH_LIABILITY_RANGE,
        HIGH_LIABILITY_FLOOR,
    );
    assert_eq!(nav, 0);
    assert_eq!(band, 0);
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
