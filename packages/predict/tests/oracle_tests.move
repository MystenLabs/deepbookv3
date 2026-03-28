// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::oracle_tests;

use deepbook_predict::{
    generated_oracle as go,
    oracle::{Self, new_price_data, new_svi_params, new_curve_point},
    oracle_helper,
    precision
};
use std::unit_test::{assert_eq, destroy};
use sui::clock;

const FLOAT: u64 = 1_000_000_000;

// === Time constants (must stay in sync with constants module) ===
const MS_PER_YEAR: u64 = 31_536_000_000;
const STALENESS_THRESHOLD_MS: u64 = 30_000;
const HALF_YEAR_MS: u64 = 15_768_000_000;

// === Common test SVI params ===
const SVI_SIGMA_0_25: u64 = 250_000_000;

// === Interest rates ===
const RATE_5_PCT: u64 = 50_000_000;
const RATE_10_PCT: u64 = 100_000_000;

// === Expected values from scipy (generate.py) ===
const DISCOUNT_5PCT_1YR: u64 = 951_229_424; // e^(-0.05*1.0)
const DISCOUNT_10PCT_HALF_YR: u64 = 951_229_424; // e^(-0.10*0.5)
const PARTIAL_10PCT_UP_ATM: u64 = 388_768_372; // UP price at rate=10%, partial year
const PARTIAL_10PCT_DN_ATM: u64 = 580_019_318; // DN price at rate=10%, partial year

// === Helpers ===

fun get_scenario(idx: u64): go::OracleScenario {
    go::scenarios()[idx]
}

fun run_oracle_scenario(idx: u64) {
    let scenarios = go::scenarios();
    let s = &scenarios[idx];
    let ctx = &mut tx_context::dummy();
    let (oracle, clock) = oracle_helper::create_from_scenario(s, ctx);

    s.strike_points().do_ref!(|sp| {
        precision::assert_approx(
            oracle.get_binary_price(sp.strike(), true, &clock),
            sp.expected_up(),
        );
        precision::assert_approx(
            oracle.get_binary_price(sp.strike(), false, &clock),
            sp.expected_dn(),
        );
    });

    destroy(oracle);
    destroy(clock);
}

// ============================================================
// Construction and Getters
// ============================================================

#[test]
fun create_test_oracle_initial_state() {
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, 0, 0, false, 0, false, 0);
    let prices = new_price_data(0, 0);
    let oracle = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi,
        prices,
        0,
        100_000,
        0,
        ctx,
    );

    assert_eq!(oracle.underlying_asset(), b"BTC".to_string());
    assert_eq!(oracle.spot_price(), 0);
    assert_eq!(oracle.forward_price(), 0);
    assert_eq!(oracle.expiry(), 100_000);
    assert_eq!(oracle.risk_free_rate(), 0);
    assert_eq!(oracle.timestamp(), 0);
    assert!(oracle.settlement_price().is_none());
    // create_test_oracle sets active=true
    assert_eq!(oracle.is_active(), true);
    assert_eq!(oracle.is_settled(), false);

    destroy(oracle);
}

#[test]
fun create_test_oracle_with_nonzero_params() {
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(100, 200, 300, true, 400, false, 500);
    let prices = new_price_data(50 * FLOAT, 51 * FLOAT);
    let oracle = oracle::create_test_oracle(
        b"ETH".to_string(),
        svi,
        prices,
        42,
        999_999,
        12345,
        ctx,
    );

    assert_eq!(oracle.underlying_asset(), b"ETH".to_string());
    assert_eq!(oracle.spot_price(), 50 * FLOAT);
    assert_eq!(oracle.forward_price(), 51 * FLOAT);
    assert_eq!(oracle.expiry(), 999_999);
    assert_eq!(oracle.risk_free_rate(), 42);
    assert_eq!(oracle.timestamp(), 12345);

    destroy(oracle);
}

#[test]
fun curve_point_getters() {
    let pt = new_curve_point(50 * FLOAT, 600_000_000, 400_000_000);
    assert_eq!(pt.strike(), 50 * FLOAT);
    assert_eq!(pt.up_price(), 600_000_000);
    assert_eq!(pt.dn_price(), 400_000_000);
}

// ============================================================
// Staleness
// ============================================================

#[test]
fun is_stale_returns_false_when_fresh() {
    let ctx = &mut tx_context::dummy();
    let (oracle, mut clock) = oracle_helper::create_simple_oracle(
        50 * FLOAT,
        50 * FLOAT,
        1_000_000,
        10_000,
        ctx,
    );

    // now=15_000 <= 10_000 + STALENESS_THRESHOLD_MS = 40_000
    clock.set_for_testing(15_000);
    assert_eq!(oracle.is_stale(&clock), false);

    destroy(oracle);
    destroy(clock);
}

#[test]
fun is_stale_returns_true_when_stale() {
    let ctx = &mut tx_context::dummy();
    let (oracle, mut clock) = oracle_helper::create_simple_oracle(
        50 * FLOAT,
        50 * FLOAT,
        1_000_000,
        10_000,
        ctx,
    );

    // now=40_001 > 10_000 + STALENESS_THRESHOLD_MS = 40_000
    clock.set_for_testing(10_000 + STALENESS_THRESHOLD_MS + 1);
    assert_eq!(oracle.is_stale(&clock), true);

    destroy(oracle);
    destroy(clock);
}

#[test]
fun is_stale_boundary_exactly_at_threshold() {
    let ctx = &mut tx_context::dummy();
    let (oracle, mut clock) = oracle_helper::create_simple_oracle(
        50 * FLOAT,
        50 * FLOAT,
        1_000_000,
        10_000,
        ctx,
    );

    // now = 10_000 + STALENESS_THRESHOLD_MS; not strictly greater, NOT stale
    clock.set_for_testing(10_000 + STALENESS_THRESHOLD_MS);
    assert_eq!(oracle.is_stale(&clock), false);

    destroy(oracle);
    destroy(clock);
}

#[test, expected_failure(abort_code = oracle::EOracleStale)]
fun assert_not_stale_aborts_when_stale() {
    let ctx = &mut tx_context::dummy();
    let (oracle, mut clock) = oracle_helper::create_simple_oracle(
        50 * FLOAT,
        50 * FLOAT,
        1_000_000,
        10_000,
        ctx,
    );

    clock.set_for_testing(10_000 + STALENESS_THRESHOLD_MS + 1);
    oracle.assert_not_stale(&clock);

    abort
}

// ============================================================
// Settlement (get_binary_price -- settled path)
// ============================================================

#[test]
fun settled_above_strike_up_wins() {
    let ctx = &mut tx_context::dummy();
    let (mut oracle, clock) = oracle_helper::create_simple_oracle(0, 0, 100_000, 0, ctx);

    // Settle at 60, strike at 50: settlement > strike, UP wins
    oracle.settle_test_oracle(60 * FLOAT);

    let up_price = oracle.get_binary_price(50 * FLOAT, true, &clock);
    let dn_price = oracle.get_binary_price(50 * FLOAT, false, &clock);

    assert_eq!(up_price, FLOAT);
    assert_eq!(dn_price, 0);

    destroy(oracle);
    destroy(clock);
}

#[test]
fun settled_below_strike_dn_wins() {
    let ctx = &mut tx_context::dummy();
    let (mut oracle, clock) = oracle_helper::create_simple_oracle(0, 0, 100_000, 0, ctx);

    // Settle at 40, strike at 50: settlement < strike, DN wins
    oracle.settle_test_oracle(40 * FLOAT);

    let up_price = oracle.get_binary_price(50 * FLOAT, true, &clock);
    let dn_price = oracle.get_binary_price(50 * FLOAT, false, &clock);

    assert_eq!(up_price, 0);
    assert_eq!(dn_price, FLOAT);

    destroy(oracle);
    destroy(clock);
}

#[test]
fun settled_at_strike_dn_wins() {
    // ATM settles as DOWN win: settlement_price > strike is false when equal
    let ctx = &mut tx_context::dummy();
    let (mut oracle, clock) = oracle_helper::create_simple_oracle(0, 0, 100_000, 0, ctx);

    oracle.settle_test_oracle(50 * FLOAT);

    let up_price = oracle.get_binary_price(50 * FLOAT, true, &clock);
    let dn_price = oracle.get_binary_price(50 * FLOAT, false, &clock);

    assert_eq!(up_price, 0);
    assert_eq!(dn_price, FLOAT);

    destroy(oracle);
    destroy(clock);
}

#[test]
fun settled_various_strikes() {
    let ctx = &mut tx_context::dummy();
    let (mut oracle, clock) = oracle_helper::create_simple_oracle(0, 0, 100_000, 0, ctx);

    oracle.settle_test_oracle(100 * FLOAT);

    // Strike 99: settlement > strike, UP wins
    assert_eq!(oracle.get_binary_price(99 * FLOAT, true, &clock), FLOAT);
    assert_eq!(oracle.get_binary_price(99 * FLOAT, false, &clock), 0);

    // Strike 100: settlement == strike, DN wins
    assert_eq!(oracle.get_binary_price(100 * FLOAT, true, &clock), 0);
    assert_eq!(oracle.get_binary_price(100 * FLOAT, false, &clock), FLOAT);

    // Strike 101: settlement < strike, DN wins
    assert_eq!(oracle.get_binary_price(101 * FLOAT, true, &clock), 0);
    assert_eq!(oracle.get_binary_price(101 * FLOAT, false, &clock), FLOAT);

    // Strike 1: settlement >> strike, UP wins
    assert_eq!(oracle.get_binary_price(1 * FLOAT, true, &clock), FLOAT);
    assert_eq!(oracle.get_binary_price(1 * FLOAT, false, &clock), 0);

    destroy(oracle);
    destroy(clock);
}

#[test]
fun settled_up_plus_dn_always_one() {
    // For settled oracle, exactly one side wins: UP + DN = FLOAT always
    let ctx = &mut tx_context::dummy();
    let (mut oracle, clock) = oracle_helper::create_simple_oracle(0, 0, 100_000, 0, ctx);

    oracle.settle_test_oracle(75 * FLOAT);

    let strikes = vector[1, 50, 74, 75, 76, 100, 200];
    strikes.do!(|s| {
        let strike = s * FLOAT;
        let up = oracle.get_binary_price(strike, true, &clock);
        let dn = oracle.get_binary_price(strike, false, &clock);
        assert_eq!(up + dn, FLOAT);
    });

    destroy(oracle);
    destroy(clock);
}

// ============================================================
// is_settled and is_active
// ============================================================

#[test]
fun is_settled_true_after_settle() {
    let ctx = &mut tx_context::dummy();
    let (mut oracle, clock) = oracle_helper::create_simple_oracle(0, 0, 100_000, 0, ctx);

    oracle.settle_test_oracle(50 * FLOAT);

    assert_eq!(oracle.is_settled(), true);
    assert_eq!(oracle.is_active(), false);
    assert_eq!(oracle.settlement_price().destroy_some(), 50 * FLOAT);

    destroy(oracle);
    destroy(clock);
}

// ============================================================
// Live pricing properties
// ============================================================

#[test]
fun live_up_monotonically_decreasing_with_strike() {
    // UP price decreases as strike increases (higher strike = less likely to finish above)
    let s = get_scenario(0); // STD: 4 strikes at d2 = -2, -1, 0, +1
    let points = s.strike_points();

    // Monotonicity: ITM_D1(3) > ATM(2) > OTM_D1(1) > OTM_D2(0)
    assert!(points[3].expected_up() > points[2].expected_up());
    assert!(points[2].expected_up() > points[1].expected_up());
    assert!(points[1].expected_up() > points[0].expected_up());
}

#[test]
fun live_discount_is_one_past_expiry() {
    // Past expiry but not settled: compute_discount returns 1.0
    // Even though rate=5%, discount clamps to 1.0 when time_to_expiry <= 0.
    // So prices should match the zero-rate scenario (scenario 0 ATM).
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, FLOAT, 0, false, 0, false, SVI_SIGMA_0_25);
    let forward = 100 * FLOAT;
    let prices = new_price_data(forward, forward);
    let oracle = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi,
        prices,
        RATE_5_PCT,
        100_000,
        0,
        ctx,
    );

    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(200_000); // past expiry

    // Scenario 0 (STD) has rate=0, same SVI params, same forward.
    // ATM strike for STD is at index 2.
    let s = get_scenario(0);
    let atm = &s.strike_points()[2];

    let up = oracle.get_binary_price(atm.strike(), true, &clock);
    let dn = oracle.get_binary_price(atm.strike(), false, &clock);

    precision::assert_approx(up, atm.expected_up());
    precision::assert_approx(dn, atm.expected_dn());

    destroy(oracle);
    destroy(clock);
}

// ============================================================
// SVI parameter sensitivity (cross-scenario comparisons)
// ============================================================

#[test]
fun nonzero_a_lowers_atm_up_price() {
    // Adding a > 0 increases total_var → higher |d2| at ATM → lower UP price
    let ctx = &mut tx_context::dummy();
    let (oracle_std, clock) = oracle_helper::create_std_oracle(ctx);

    let std = get_scenario(0);
    let std_atm = &std.strike_points()[2];
    let a_scenario = get_scenario(4); // NONZERO_A
    let a_atm = &a_scenario.strike_points()[0];

    precision::assert_approx(
        oracle_std.get_binary_price(std_atm.strike(), true, &clock),
        std_atm.expected_up(),
    );

    // Higher a → lower ATM UP (from generated ground truth)
    assert!(a_atm.expected_up() < std_atm.expected_up());

    destroy(oracle_std);
    destroy(clock);
}

#[test]
fun negative_rho_shifts_otm_strikes() {
    // rho=-0.3 skews the smile, changing which strikes produce a given d2.
    // At d2=0 (ATM), rho doesn't affect the price (rho*(k-m)=0 when k=m=0).
    // But the OTM strikes that produce d2=-2 differ between rho=0 and rho=-0.3.
    let std = get_scenario(0);
    let rho_scenario = get_scenario(5); // NEG_RHO

    // OTM_D2 strike (index 0): same d2 target, different strikes
    assert!(std.strike_points()[0].strike() != rho_scenario.strike_points()[0].strike());
}

#[test]
fun nonzero_m_shifts_otm_strikes() {
    // m=0.1 shifts the SVI surface center, changing which strikes produce a given d2.
    let std = get_scenario(0);
    let m_scenario = get_scenario(6); // NONZERO_M

    // OTM_D2 strike (index 0): same d2 target, different strikes
    assert!(std.strike_points()[0].strike() != m_scenario.strike_points()[0].strike());
}

// ============================================================
// Discount computation
// ============================================================

#[test]
fun discount_positive_rate_half_year() {
    // rate=10%, half year: UP + DN = e^(-0.10*0.5) = DISCOUNT_10PCT_HALF_YR
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, FLOAT, 0, false, 0, false, SVI_SIGMA_0_25);
    let forward = 100 * FLOAT;
    let prices = new_price_data(forward, forward);

    let oracle = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi,
        prices,
        RATE_10_PCT,
        HALF_YEAR_MS,
        0,
        ctx,
    );

    let clock = clock::create_for_testing(ctx);
    let up = oracle.get_binary_price(forward, true, &clock);
    let dn = oracle.get_binary_price(forward, false, &clock);

    assert_eq!(up + dn, DISCOUNT_10PCT_HALF_YR);

    destroy(oracle);
    destroy(clock);
}

#[test]
fun exact_discount_with_partial_year() {
    // rate=10%, expiry=20B ms, clock=10B ms → t ≈ 0.317 years
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, FLOAT, 0, false, 0, false, SVI_SIGMA_0_25);
    let forward = 100 * FLOAT;
    let prices = new_price_data(forward, forward);
    let oracle = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi,
        prices,
        RATE_10_PCT,
        20_000_000_000,
        0,
        ctx,
    );

    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(10_000_000_000);

    precision::assert_approx(
        oracle.get_binary_price(forward, true, &clock),
        PARTIAL_10PCT_UP_ATM,
    );
    precision::assert_approx(
        oracle.get_binary_price(forward, false, &clock),
        PARTIAL_10PCT_DN_ATM,
    );

    destroy(oracle);
    destroy(clock);
}

// ============================================================
// build_curve
// ============================================================

#[test]
fun build_curve_settled_oracle() {
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, FLOAT, 0, false, 0, false, SVI_SIGMA_0_25);
    let forward = 100 * FLOAT;
    let prices = new_price_data(forward, forward);
    let mut oracle = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi,
        prices,
        0,
        100_000,
        0,
        ctx,
    );

    oracle.settle_test_oracle(100 * FLOAT);

    let clock = clock::create_for_testing(ctx);
    let curve = oracle.build_curve(50 * FLOAT, 150 * FLOAT, &clock);

    // Settled oracle returns 2-point step function
    assert_eq!(curve.length(), 2);

    let p0 = &curve[0];
    assert_eq!(p0.strike(), 100 * FLOAT - 1);
    assert_eq!(p0.up_price(), FLOAT);
    assert_eq!(p0.dn_price(), 0);

    let p1 = &curve[1];
    assert_eq!(p1.strike(), 100 * FLOAT);
    assert_eq!(p1.up_price(), 0);
    assert_eq!(p1.dn_price(), FLOAT);

    destroy(oracle);
    destroy(clock);
}

#[test]
fun build_curve_settled_at_75() {
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, FLOAT, 0, false, 0, false, SVI_SIGMA_0_25);
    let prices = new_price_data(100 * FLOAT, 100 * FLOAT);
    let mut oracle = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi,
        prices,
        0,
        100_000,
        0,
        ctx,
    );
    oracle.settle_test_oracle(75 * FLOAT);

    let clock = clock::create_for_testing(ctx);
    let curve = oracle.build_curve(50 * FLOAT, 150 * FLOAT, &clock);

    assert_eq!(curve.length(), 2);
    assert_eq!(curve[0].strike(), 75 * FLOAT - 1);
    assert_eq!(curve[0].up_price(), FLOAT);
    assert_eq!(curve[0].dn_price(), 0);
    assert_eq!(curve[1].strike(), 75 * FLOAT);
    assert_eq!(curve[1].up_price(), 0);
    assert_eq!(curve[1].dn_price(), FLOAT);

    destroy(oracle);
    destroy(clock);
}

#[test]
fun build_curve_single_strike() {
    let ctx = &mut tx_context::dummy();
    let (oracle, clock) = oracle_helper::create_std_oracle(ctx);
    let curve = oracle.build_curve(100 * FLOAT, 100 * FLOAT, &clock);

    assert_eq!(curve.length(), 1);
    let pt = &curve[0];
    assert_eq!(pt.strike(), 100 * FLOAT);
    assert_eq!(pt.up_price() + pt.dn_price(), FLOAT);

    destroy(oracle);
    destroy(clock);
}

#[test]
fun build_curve_live_sorted_and_complement() {
    let ctx = &mut tx_context::dummy();
    let (oracle, clock) = oracle_helper::create_std_oracle(ctx);
    let curve = oracle.build_curve(50 * FLOAT, 150 * FLOAT, &clock);

    let len = curve.length();
    assert!(len >= 3); // at least min, forward, max

    let mut i = 0;
    while (i < len - 1) {
        // Sorted by strike
        assert!(curve[i].strike() < curve[i + 1].strike());
        // UP prices monotonically non-increasing
        assert!(curve[i].up_price() >= curve[i + 1].up_price());
        i = i + 1;
    };

    // Complement: UP + DN = FLOAT (rate=0 → discount=1.0)
    i = 0;
    while (i < len) {
        assert_eq!(curve[i].up_price() + curve[i].dn_price(), FLOAT);
        i = i + 1;
    };

    destroy(oracle);
    destroy(clock);
}

#[test]
fun build_curve_includes_forward_when_in_range() {
    let ctx = &mut tx_context::dummy();
    let (oracle, clock) = oracle_helper::create_std_oracle(ctx);
    let forward = 100 * FLOAT;
    let curve = oracle.build_curve(50 * FLOAT, 150 * FLOAT, &clock);

    let mut found = false;
    curve.do_ref!(|pt| {
        if (pt.strike() == forward) found = true;
    });
    assert!(found);

    destroy(oracle);
    destroy(clock);
}

#[test]
fun build_curve_no_duplicate_when_forward_at_boundary() {
    let ctx = &mut tx_context::dummy();
    let (oracle, clock) = oracle_helper::create_std_oracle(ctx);
    let forward = 100 * FLOAT;
    let curve = oracle.build_curve(forward, 150 * FLOAT, &clock);

    // All strikes must be strictly increasing (no duplicates)
    let len = curve.length();
    let mut i = 0;
    while (i < len - 1) {
        assert!(curve[i].strike() < curve[i + 1].strike());
        i = i + 1;
    };

    destroy(oracle);
    destroy(clock);
}

#[test]
fun build_curve_endpoints_match_min_max() {
    let ctx = &mut tx_context::dummy();
    let (oracle, clock) = oracle_helper::create_std_oracle(ctx);
    let min_strike = 50 * FLOAT;
    let max_strike = 150 * FLOAT;
    let curve = oracle.build_curve(min_strike, max_strike, &clock);

    assert_eq!(curve[0].strike(), min_strike);
    assert_eq!(curve[curve.length() - 1].strike(), max_strike);

    destroy(oracle);
    destroy(clock);
}

#[test]
fun build_curve_forward_outside_range() {
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, FLOAT, 0, false, 0, false, SVI_SIGMA_0_25);
    let forward = 200 * FLOAT; // outside [50,150]
    let prices = new_price_data(forward, forward);
    let oracle = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi,
        prices,
        0,
        1_000_000,
        0,
        ctx,
    );

    let clock = clock::create_for_testing(ctx);
    let curve = oracle.build_curve(50 * FLOAT, 150 * FLOAT, &clock);

    assert!(curve.length() >= 2);
    assert_eq!(curve[0].strike(), 50 * FLOAT);
    assert_eq!(curve[curve.length() - 1].strike(), 150 * FLOAT);

    let len = curve.length();
    let mut i = 0;
    while (i < len - 1) {
        assert!(curve[i].strike() < curve[i + 1].strike());
        i = i + 1;
    };

    destroy(oracle);
    destroy(clock);
}

#[test]
fun build_curve_with_positive_rate_complement() {
    // With positive rate, UP + DN = discount < FLOAT
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, FLOAT, 0, false, 0, false, SVI_SIGMA_0_25);
    let forward = 100 * FLOAT;
    let prices = new_price_data(forward, forward);

    let oracle = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi,
        prices,
        RATE_5_PCT,
        MS_PER_YEAR,
        0,
        ctx,
    );

    let clock = clock::create_for_testing(ctx);
    let curve = oracle.build_curve(50 * FLOAT, 150 * FLOAT, &clock);

    let len = curve.length();
    let mut i = 0;
    while (i < len) {
        let sum = curve[i].up_price() + curve[i].dn_price();
        precision::assert_approx(sum, DISCOUNT_5PCT_1YR);
        i = i + 1;
    };

    destroy(oracle);
    destroy(clock);
}

// ============================================================
// Edge cases
// ============================================================

#[test]
fun live_forward_one_unit_above_strike() {
    let ctx = &mut tx_context::dummy();
    let (oracle, clock) = oracle_helper::create_std_oracle(ctx);
    let forward = 100 * FLOAT;
    let strike = forward - 1;

    let up = oracle.get_binary_price(strike, true, &clock);
    let dn = oracle.get_binary_price(strike, false, &clock);

    assert_eq!(up + dn, FLOAT);

    destroy(oracle);
    destroy(clock);
}

// Aborts with VM arithmetic error (division by zero in math::div) — no named constant
#[test, expected_failure]
fun live_price_with_zero_forward_aborts() {
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, FLOAT, 0, false, 0, false, SVI_SIGMA_0_25);
    let prices = new_price_data(0, 0);
    let oracle = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi,
        prices,
        0,
        1_000_000,
        0,
        ctx,
    );

    let clock = clock::create_for_testing(ctx);
    oracle.get_binary_price(50 * FLOAT, true, &clock);

    abort
}

// ============================================================
// Positive-path: activate, update_prices, update_svi
// ============================================================

#[test]
fun activate_succeeds_with_registered_cap() {
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, FLOAT, 0, false, 0, false, SVI_SIGMA_0_25);
    let prices = new_price_data(100 * FLOAT, 100 * FLOAT);
    let mut oracle = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi,
        prices,
        0,
        1_000_000,
        0,
        ctx,
    );
    oracle.set_active_for_testing(false);
    assert_eq!(oracle.is_active(), false);

    let cap = oracle::create_oracle_cap(ctx);
    oracle::register_cap(&mut oracle, &cap);
    let clock = clock::create_for_testing(ctx);

    oracle.activate(&cap, &clock);
    assert_eq!(oracle.is_active(), true);

    destroy(oracle);
    destroy(cap);
    destroy(clock);
}

#[test]
fun update_prices_updates_spot_and_forward() {
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, FLOAT, 0, false, 0, false, SVI_SIGMA_0_25);
    let prices = new_price_data(100 * FLOAT, 100 * FLOAT);
    let mut oracle = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi,
        prices,
        0,
        1_000_000,
        0,
        ctx,
    );
    let cap = oracle::create_oracle_cap(ctx);
    oracle::register_cap(&mut oracle, &cap);
    let clock = clock::create_for_testing(ctx);

    let new_prices = new_price_data(105 * FLOAT, 106 * FLOAT);
    oracle.update_prices(&cap, new_prices, &clock);

    assert_eq!(oracle.spot_price(), 105 * FLOAT);
    assert_eq!(oracle.forward_price(), 106 * FLOAT);

    destroy(oracle);
    destroy(cap);
    destroy(clock);
}

#[test]
fun update_prices_past_expiry_settles_oracle() {
    // update_prices past expiry freezes settlement price from spot
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, FLOAT, 0, false, 0, false, SVI_SIGMA_0_25);
    let prices = new_price_data(100 * FLOAT, 100 * FLOAT);
    let mut oracle = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi,
        prices,
        0,
        100_000,
        0,
        ctx,
    );
    let cap = oracle::create_oracle_cap(ctx);
    oracle::register_cap(&mut oracle, &cap);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(200_000); // past expiry

    let new_prices = new_price_data(105 * FLOAT, 106 * FLOAT);
    oracle.update_prices(&cap, new_prices, &clock);

    assert_eq!(oracle.is_settled(), true);
    assert_eq!(oracle.is_active(), false);
    // Settlement price comes from the new spot
    assert_eq!(oracle.settlement_price().destroy_some(), 105 * FLOAT);

    destroy(oracle);
    destroy(cap);
    destroy(clock);
}

#[test]
fun update_svi_updates_rate_and_timestamp() {
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, FLOAT, 0, false, 0, false, SVI_SIGMA_0_25);
    let prices = new_price_data(100 * FLOAT, 100 * FLOAT);
    let mut oracle = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi,
        prices,
        0,
        1_000_000,
        0,
        ctx,
    );
    let cap = oracle::create_oracle_cap(ctx);
    oracle::register_cap(&mut oracle, &cap);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(5_000);

    let new_svi = new_svi_params(100, FLOAT, 0, false, 0, false, SVI_SIGMA_0_25);
    oracle.update_svi(&cap, new_svi, RATE_5_PCT, &clock);

    assert_eq!(oracle.risk_free_rate(), RATE_5_PCT);
    assert_eq!(oracle.timestamp(), 5_000);

    destroy(oracle);
    destroy(cap);
    destroy(clock);
}

// ============================================================
// Abort code coverage
// ============================================================

#[test, expected_failure(abort_code = oracle::EInvalidOracleCap)]
fun activate_with_unauthorized_cap_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut oracle, cap, clock) = oracle_helper::create_oracle_with_unregistered_cap(ctx);
    oracle.set_active_for_testing(false);

    oracle.activate(&cap, &clock);

    abort
}

#[test, expected_failure(abort_code = oracle::EInvalidOracleCap)]
fun update_prices_with_unauthorized_cap_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut oracle, cap, clock) = oracle_helper::create_oracle_with_unregistered_cap(ctx);

    let new_prices = new_price_data(105 * FLOAT, 106 * FLOAT);
    oracle.update_prices(&cap, new_prices, &clock);

    abort
}

#[test, expected_failure(abort_code = oracle::EInvalidOracleCap)]
fun update_svi_with_unauthorized_cap_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut oracle, cap, clock) = oracle_helper::create_oracle_with_unregistered_cap(ctx);

    let new_svi = new_svi_params(0, FLOAT, 0, false, 0, false, SVI_SIGMA_0_25);
    oracle.update_svi(&cap, new_svi, 0, &clock);

    abort
}

#[test, expected_failure(abort_code = oracle::EOracleAlreadyActive)]
fun activate_already_active_oracle_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut oracle, cap, clock) = oracle_helper::create_oracle_with_cap(ctx);

    // Oracle is already active (create_test_oracle sets active=true)
    oracle.activate(&cap, &clock);

    abort
}

#[test, expected_failure(abort_code = oracle::EOracleExpired)]
fun activate_expired_oracle_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut oracle, cap, mut clock) = oracle_helper::create_oracle_with_cap(ctx);
    oracle.set_active_for_testing(false);
    clock.set_for_testing(2_000_000); // past expiry (1_000_000)

    oracle.activate(&cap, &clock);

    abort
}

#[test, expected_failure(abort_code = oracle::EOracleExpired)]
fun update_svi_on_settled_oracle_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut oracle, cap, clock) = oracle_helper::create_oracle_with_cap(ctx);
    oracle.settle_test_oracle(100 * FLOAT);

    let new_svi = new_svi_params(0, FLOAT, 0, false, 0, false, SVI_SIGMA_0_25);
    oracle.update_svi(&cap, new_svi, 0, &clock);

    abort
}

#[test, expected_failure(abort_code = oracle::ECannotBeNegative)]
fun compute_nd2_negative_inner_aborts() {
    let ctx = &mut tx_context::dummy();
    // Adversarial SVI: rho=-1.0, sigma~0 makes inner term negative for large k
    let svi = new_svi_params(0, FLOAT, FLOAT, true, 0, false, 1);
    let prices = new_price_data(100 * FLOAT, 100 * FLOAT);
    let oracle = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi,
        prices,
        0,
        1_000_000,
        0,
        ctx,
    );

    let clock = clock::create_for_testing(ctx);
    oracle.get_binary_price(1000 * FLOAT, true, &clock);

    abort
}

#[test, expected_failure(abort_code = oracle::EZeroVariance)]
fun zero_svi_params_on_live_oracle_aborts() {
    let ctx = &mut tx_context::dummy();
    // a=0, b=0 → total_var = 0 → EZeroVariance in compute_nd2
    let svi = new_svi_params(0, 0, 0, false, 0, false, 0);
    let prices = new_price_data(100 * FLOAT, 100 * FLOAT);
    let oracle = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi,
        prices,
        0,
        1_000_000,
        0,
        ctx,
    );

    let clock = clock::create_for_testing(ctx);
    oracle.get_binary_price(100 * FLOAT, true, &clock);

    abort
}

// ============================================================
// Expiry boundary tests
// ============================================================

#[test, expected_failure(abort_code = oracle::EOracleExpired)]
fun activate_at_exact_expiry_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut oracle, cap, mut clock) = oracle_helper::create_oracle_with_cap(ctx);
    oracle.set_active_for_testing(false);
    clock.set_for_testing(1_000_000); // exactly at expiry; guard is now < expiry

    oracle.activate(&cap, &clock);

    abort
}

#[test]
fun update_prices_at_exact_expiry_does_not_settle() {
    let ctx = &mut tx_context::dummy();
    let (mut oracle, cap, mut clock) = oracle_helper::create_oracle_with_cap(ctx);
    clock.set_for_testing(1_000_000); // exactly at expiry; guard is now > expiry

    let new_prices = new_price_data(105 * FLOAT, 106 * FLOAT);
    oracle.update_prices(&cap, new_prices, &clock);

    // Should NOT have settled — just updated prices
    assert!(oracle.settlement_price().is_none());
    assert_eq!(oracle.spot_price(), 105 * FLOAT);

    destroy(oracle);
    destroy(cap);
    destroy(clock);
}

#[test]
fun update_prices_on_settled_oracle_preserves_settlement() {
    let ctx = &mut tx_context::dummy();
    let (mut oracle, cap, mut clock) = oracle_helper::create_oracle_with_cap(ctx);

    // First, settle the oracle by calling update_prices past expiry
    clock.set_for_testing(2_000_000);
    let prices1 = new_price_data(105 * FLOAT, 106 * FLOAT);
    oracle.update_prices(&cap, prices1, &clock);
    assert_eq!(oracle.settlement_price().destroy_some(), 105 * FLOAT);

    // Call update_prices again — settlement_price.is_some(), so settlement branch is skipped
    let prices2 = new_price_data(110 * FLOAT, 111 * FLOAT);
    oracle.update_prices(&cap, prices2, &clock);

    // Settlement price unchanged, but prices updated
    assert_eq!(oracle.settlement_price().destroy_some(), 105 * FLOAT);
    assert_eq!(oracle.spot_price(), 110 * FLOAT);

    destroy(oracle);
    destroy(cap);
    destroy(clock);
}

// ============================================================
// Scenario runner — all 13 scenarios against scipy ground truth
// ============================================================

#[test]
fun scenario_std() { run_oracle_scenario(0); }
#[test]
fun scenario_std_5pct() { run_oracle_scenario(1); }
#[test]
fun scenario_full_svi() { run_oracle_scenario(2); }
#[test]
fun scenario_small_sigma() { run_oracle_scenario(3); }
#[test]
fun scenario_nonzero_a() { run_oracle_scenario(4); }
#[test]
fun scenario_neg_rho() { run_oracle_scenario(5); }
#[test]
fun scenario_nonzero_m() { run_oracle_scenario(6); }
#[test]
fun scenario_s0() { run_oracle_scenario(7); }
#[test]
fun scenario_s1() { run_oracle_scenario(8); }
#[test]
fun scenario_s2() { run_oracle_scenario(9); }
#[test]
fun scenario_s3() { run_oracle_scenario(10); }
#[test]
fun scenario_s4() { run_oracle_scenario(11); }
#[test]
fun scenario_s5() { run_oracle_scenario(12); }
