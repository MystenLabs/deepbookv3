// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::plp_tests;

use deepbook_predict::{constants::float_scaling as float, plp};
use std::unit_test::assert_eq;

// `protocol_reserve_profit_share` is 1e9-scaled (`float!()` == 1.0).
// `plp::lp_pool_value(idle, credits, debits, share, active)` returns the
// LP-attributable pool value = max(0, gross - exclusion), where
// gross = idle + active and exclusion = share * max(0, (credits + active) - debits).
// Expected values below are derived by hand from that definition.

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
