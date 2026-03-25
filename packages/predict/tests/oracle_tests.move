// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::oracle_tests;

use deepbook_predict::{
    generated_oracle as gs,
    oracle::{Self, new_price_data, new_svi_params, new_curve_point},
    precision
};
use std::unit_test::{assert_eq, destroy};
use sui::clock;

const FLOAT: u64 = 1_000_000_000;

// === Time constants ===
const MS_PER_YEAR: u64 = 31_536_000_000;
const STALENESS_THRESHOLD_MS: u64 = 30_000;
const HALF_YEAR_MS: u64 = 15_768_000_000;

// === Common test SVI params ===
const SIGMA_25: u64 = 250_000_000;
const SIGMA_01: u64 = 10_000_000;

// === Interest rates ===
const RATE_5_PCT: u64 = 50_000_000;
const RATE_10_PCT: u64 = 100_000_000;

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
    assert_eq!(oracle.settlement_price().is_none(), true);
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
    let svi = new_svi_params(0, 0, 0, false, 0, false, 0);
    let prices = new_price_data(50 * FLOAT, 50 * FLOAT);
    let oracle = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi,
        prices,
        0,
        1_000_000,
        10_000,
        ctx,
    );

    let clock = clock::create_for_testing(ctx);
    // now=0 <= 10_000 + STALENESS_THRESHOLD_MS = 40_000
    assert_eq!(oracle.is_stale(&clock), false);

    destroy(oracle);
    clock.destroy_for_testing();
}

#[test]
fun is_stale_returns_true_when_stale() {
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, 0, 0, false, 0, false, 0);
    let prices = new_price_data(50 * FLOAT, 50 * FLOAT);
    let oracle = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi,
        prices,
        0,
        1_000_000,
        10_000,
        ctx,
    );

    let mut clock = clock::create_for_testing(ctx);
    // now=40_001 > 10_000 + STALENESS_THRESHOLD_MS = 40_000
    clock.set_for_testing(10_000 + STALENESS_THRESHOLD_MS + 1);
    assert_eq!(oracle.is_stale(&clock), true);

    destroy(oracle);
    clock.destroy_for_testing();
}

#[test]
fun is_stale_boundary_exactly_at_threshold() {
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, 0, 0, false, 0, false, 0);
    let prices = new_price_data(50 * FLOAT, 50 * FLOAT);
    let oracle = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi,
        prices,
        0,
        1_000_000,
        10_000,
        ctx,
    );

    let mut clock = clock::create_for_testing(ctx);
    // now = 10_000 + STALENESS_THRESHOLD_MS; not strictly greater, NOT stale
    clock.set_for_testing(10_000 + STALENESS_THRESHOLD_MS);
    assert_eq!(oracle.is_stale(&clock), false);

    destroy(oracle);
    clock.destroy_for_testing();
}

#[test, expected_failure(abort_code = oracle::EOracleStale)]
fun assert_not_stale_aborts_when_stale() {
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, 0, 0, false, 0, false, 0);
    let prices = new_price_data(50 * FLOAT, 50 * FLOAT);
    let oracle = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi,
        prices,
        0,
        1_000_000,
        10_000,
        ctx,
    );

    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(10_000 + STALENESS_THRESHOLD_MS + 1);
    oracle.assert_not_stale(&clock);

    abort
}

#[test]
fun assert_not_stale_passes_when_fresh() {
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, 0, 0, false, 0, false, 0);
    let prices = new_price_data(50 * FLOAT, 50 * FLOAT);
    let oracle = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi,
        prices,
        0,
        1_000_000,
        10_000,
        ctx,
    );

    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(10_000 + STALENESS_THRESHOLD_MS - 1);
    oracle.assert_not_stale(&clock);

    destroy(oracle);
    clock.destroy_for_testing();
}

// ============================================================
// Settlement (get_binary_price -- settled path)
// ============================================================

#[test]
fun settled_above_strike_up_wins() {
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, 0, 0, false, 0, false, 0);
    let prices = new_price_data(0, 0);
    let mut oracle = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi,
        prices,
        0,
        100_000,
        0,
        ctx,
    );

    // Settle at 60, strike at 50: settlement > strike, UP wins
    oracle.settle_test_oracle(60 * FLOAT);

    let clock = clock::create_for_testing(ctx);
    let up_price = oracle.get_binary_price(50 * FLOAT, true, &clock);
    let dn_price = oracle.get_binary_price(50 * FLOAT, false, &clock);

    assert_eq!(up_price, FLOAT);
    assert_eq!(dn_price, 0);

    destroy(oracle);
    clock.destroy_for_testing();
}

#[test]
fun settled_below_strike_dn_wins() {
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, 0, 0, false, 0, false, 0);
    let prices = new_price_data(0, 0);
    let mut oracle = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi,
        prices,
        0,
        100_000,
        0,
        ctx,
    );

    // Settle at 40, strike at 50: settlement < strike, DN wins
    oracle.settle_test_oracle(40 * FLOAT);

    let clock = clock::create_for_testing(ctx);
    let up_price = oracle.get_binary_price(50 * FLOAT, true, &clock);
    let dn_price = oracle.get_binary_price(50 * FLOAT, false, &clock);

    assert_eq!(up_price, 0);
    assert_eq!(dn_price, FLOAT);

    destroy(oracle);
    clock.destroy_for_testing();
}

#[test]
fun settled_at_strike_dn_wins() {
    // ATM settles as DOWN win: settlement_price > strike is false when equal
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, 0, 0, false, 0, false, 0);
    let prices = new_price_data(0, 0);
    let mut oracle = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi,
        prices,
        0,
        100_000,
        0,
        ctx,
    );

    oracle.settle_test_oracle(50 * FLOAT);

    let clock = clock::create_for_testing(ctx);
    let up_price = oracle.get_binary_price(50 * FLOAT, true, &clock);
    let dn_price = oracle.get_binary_price(50 * FLOAT, false, &clock);

    assert_eq!(up_price, 0);
    assert_eq!(dn_price, FLOAT);

    destroy(oracle);
    clock.destroy_for_testing();
}

#[test]
fun settled_various_strikes() {
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, 0, 0, false, 0, false, 0);
    let prices = new_price_data(0, 0);
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
    clock.destroy_for_testing();
}

#[test]
fun settled_up_plus_dn_always_one() {
    // For settled oracle, exactly one side wins: UP + DN = FLOAT always
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, 0, 0, false, 0, false, 0);
    let prices = new_price_data(0, 0);
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

    let strikes = vector[1, 50, 74, 75, 76, 100, 200];
    strikes.do!(|s| {
        let strike = s * FLOAT;
        let up = oracle.get_binary_price(strike, true, &clock);
        let dn = oracle.get_binary_price(strike, false, &clock);
        assert_eq!(up + dn, FLOAT);
    });

    destroy(oracle);
    clock.destroy_for_testing();
}

// ============================================================
// is_settled and is_active
// ============================================================

#[test]
fun is_settled_true_after_settle() {
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, 0, 0, false, 0, false, 0);
    let prices = new_price_data(0, 0);
    let mut oracle = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi,
        prices,
        0,
        100_000,
        0,
        ctx,
    );

    oracle.settle_test_oracle(50 * FLOAT);

    assert_eq!(oracle.is_settled(), true);
    assert_eq!(oracle.is_active(), false);
    assert_eq!(oracle.settlement_price().destroy_some(), 50 * FLOAT);

    destroy(oracle);
}

// ============================================================
// get_binary_price -- Live path (SVI + Black-Scholes)
// ============================================================

// ATM test: strike == forward, m=0, rho=0
// SVI params: a=0, b=1.0, rho=0, m=0, sigma=0.25
// Hand-traced computation:
//   k = ln(1) = (0, false)
//   k_minus_m = (0, false)
//   sq = sigma = 250_000_000
//   inner = sigma = 250_000_000 (rho=0 so rho_km=0)
//   total_var = 0 + mul(1e9, 250M) = 250_000_000
//   sqrt_var = sqrt(250M, 1e9) = 500_000_000
//   d2: sub_signed(0, true, 125_000_000, false) = (125_000_000, true)
//   d2 = div(125M, 500M) = 250_000_000, d2_neg = true
//   For UP: cdf_neg = true; normal_cdf(250M, true)
//   For DN: cdf_neg = false; normal_cdf(250M, false)
// With risk_free_rate=0, discount=1.0

#[test]
fun live_atm_up_plus_dn_equals_discount() {
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, FLOAT, 0, false, 0, false, SIGMA_25);
    let forward = 100 * FLOAT;
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
    let strike = gs::SYN_STD_STRIKE_ATM!();

    let up_price = oracle.get_binary_price(strike, true, &clock);
    let dn_price = oracle.get_binary_price(strike, false, &clock);

    precision::assert_approx_rel(up_price, gs::SYN_STD_UP_ATM!());
    precision::assert_approx_rel(dn_price, gs::SYN_STD_DN_ATM!());

    destroy(oracle);
    clock.destroy_for_testing();
}

#[test]
fun live_deep_itm_up() {
    // strike << forward: UP should be significantly above 0.5
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, FLOAT, 0, false, 0, false, SIGMA_25);
    let forward = 100 * FLOAT;
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
    let strike = gs::SYN_STD_STRIKE_ITM_D1!();

    let up_price = oracle.get_binary_price(strike, true, &clock);
    let dn_price = oracle.get_binary_price(strike, false, &clock);

    precision::assert_approx_rel(up_price, gs::SYN_STD_UP_ITM_D1!());
    precision::assert_approx_rel(dn_price, gs::SYN_STD_DN_ITM_D1!());

    destroy(oracle);
    clock.destroy_for_testing();
}

#[test]
fun live_deep_otm_up() {
    // strike >> forward: UP should be well below 0.5
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, FLOAT, 0, false, 0, false, SIGMA_25);
    let forward = 100 * FLOAT;
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
    let strike = gs::SYN_STD_STRIKE_OTM_D2!();

    let up_price = oracle.get_binary_price(strike, true, &clock);
    let dn_price = oracle.get_binary_price(strike, false, &clock);

    precision::assert_approx_rel(up_price, gs::SYN_STD_UP_OTM_D2!());
    precision::assert_approx_rel(dn_price, gs::SYN_STD_DN_OTM_D2!());

    destroy(oracle);
    clock.destroy_for_testing();
}

#[test]
fun live_complement_property_various_strikes() {
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, FLOAT, 0, false, 0, false, SIGMA_25);
    let forward = 100 * FLOAT;
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

    precision::assert_approx_rel(
        oracle.get_binary_price(gs::SYN_STD_STRIKE_OTM_D2!(), true, &clock),
        gs::SYN_STD_UP_OTM_D2!(),
    );
    precision::assert_approx_rel(
        oracle.get_binary_price(gs::SYN_STD_STRIKE_OTM_D2!(), false, &clock),
        gs::SYN_STD_DN_OTM_D2!(),
    );
    precision::assert_approx_rel(
        oracle.get_binary_price(gs::SYN_STD_STRIKE_OTM_D1!(), true, &clock),
        gs::SYN_STD_UP_OTM_D1!(),
    );
    precision::assert_approx_rel(
        oracle.get_binary_price(gs::SYN_STD_STRIKE_OTM_D1!(), false, &clock),
        gs::SYN_STD_DN_OTM_D1!(),
    );
    precision::assert_approx_rel(
        oracle.get_binary_price(gs::SYN_STD_STRIKE_ATM!(), true, &clock),
        gs::SYN_STD_UP_ATM!(),
    );
    precision::assert_approx_rel(
        oracle.get_binary_price(gs::SYN_STD_STRIKE_ATM!(), false, &clock),
        gs::SYN_STD_DN_ATM!(),
    );
    precision::assert_approx_rel(
        oracle.get_binary_price(gs::SYN_STD_STRIKE_ITM_D1!(), true, &clock),
        gs::SYN_STD_UP_ITM_D1!(),
    );
    precision::assert_approx_rel(
        oracle.get_binary_price(gs::SYN_STD_STRIKE_ITM_D1!(), false, &clock),
        gs::SYN_STD_DN_ITM_D1!(),
    );

    destroy(oracle);
    clock.destroy_for_testing();
}

#[test]
fun live_discount_less_than_one_for_positive_rate() {
    // With positive rate and time to expiry, discount < 1.0
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, FLOAT, 0, false, 0, false, SIGMA_25);
    let forward = 100 * FLOAT;
    let prices = new_price_data(forward, forward);
    let oracle = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi,
        prices,
        RATE_5_PCT,
        MS_PER_YEAR, // expiry = 1 year in ms
        0,
        ctx,
    );

    let clock = clock::create_for_testing(ctx);

    let up = oracle.get_binary_price(gs::SYN_5PCT_STRIKE_ATM!(), true, &clock);
    let dn = oracle.get_binary_price(gs::SYN_5PCT_STRIKE_ATM!(), false, &clock);

    precision::assert_approx_rel(up, gs::SYN_5PCT_UP_ATM!());
    precision::assert_approx_rel(dn, gs::SYN_5PCT_DN_ATM!());

    destroy(oracle);
    clock.destroy_for_testing();
}

#[test]
fun live_discount_is_one_past_expiry() {
    // Past expiry but not settled: compute_discount returns 1.0
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, FLOAT, 0, false, 0, false, SIGMA_25);
    let forward = 100 * FLOAT;
    let prices = new_price_data(forward, forward);
    let oracle = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi,
        prices,
        RATE_5_PCT,
        100_000, // expiry at 100_000ms
        0,
        ctx,
    );

    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(200_000); // past expiry

    let up = oracle.get_binary_price(gs::SYN_STD_STRIKE_ATM!(), true, &clock);
    let dn = oracle.get_binary_price(gs::SYN_STD_STRIKE_ATM!(), false, &clock);

    // discount = 1.0 past expiry, so prices equal the zero-rate ATM values
    precision::assert_approx_rel(up, gs::SYN_STD_UP_ATM!());
    precision::assert_approx_rel(dn, gs::SYN_STD_DN_ATM!());

    destroy(oracle);
    clock.destroy_for_testing();
}

#[test]
fun live_up_monotonically_decreasing_with_strike() {
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, FLOAT, 0, false, 0, false, SIGMA_25);
    let forward = 100 * FLOAT;
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

    precision::assert_approx_rel(
        oracle.get_binary_price(gs::SYN_STD_STRIKE_ITM_D1!(), true, &clock),
        gs::SYN_STD_UP_ITM_D1!(),
    );
    precision::assert_approx_rel(
        oracle.get_binary_price(gs::SYN_STD_STRIKE_ATM!(), true, &clock),
        gs::SYN_STD_UP_ATM!(),
    );
    precision::assert_approx_rel(
        oracle.get_binary_price(gs::SYN_STD_STRIKE_OTM_D1!(), true, &clock),
        gs::SYN_STD_UP_OTM_D1!(),
    );
    precision::assert_approx_rel(
        oracle.get_binary_price(gs::SYN_STD_STRIKE_OTM_D2!(), true, &clock),
        gs::SYN_STD_UP_OTM_D2!(),
    );
    // Monotonicity: ITM_D1 > ATM > OTM_D1 > OTM_D2
    assert_eq!(gs::SYN_STD_UP_ITM_D1!() > gs::SYN_STD_UP_ATM!(), true);
    assert_eq!(gs::SYN_STD_UP_ATM!() > gs::SYN_STD_UP_OTM_D1!(), true);
    assert_eq!(gs::SYN_STD_UP_OTM_D1!() > gs::SYN_STD_UP_OTM_D2!(), true);

    destroy(oracle);
    clock.destroy_for_testing();
}

// ============================================================
// Exact ATM computation trace
// ============================================================

// ============================================================
// SVI parameter sensitivity
// ============================================================

#[test]
fun live_nonzero_a_increases_variance() {
    // Adding a > 0 increases total_var, which increases |d2| for ATM
    let ctx = &mut tx_context::dummy();
    let svi0 = new_svi_params(0, FLOAT, 0, false, 0, false, SIGMA_25);
    let svi1 = new_svi_params(100_000_000, FLOAT, 0, false, 0, false, SIGMA_25);
    let forward = 100 * FLOAT;
    let prices = new_price_data(forward, forward);

    let oracle0 = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi0,
        prices,
        0,
        1_000_000,
        0,
        ctx,
    );
    let oracle1 = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi1,
        prices,
        0,
        1_000_000,
        0,
        ctx,
    );

    let clock = clock::create_for_testing(ctx);

    precision::assert_approx_rel(
        oracle0.get_binary_price(gs::SYN_STD_STRIKE_ATM!(), true, &clock),
        gs::SYN_STD_UP_ATM!(),
    );
    precision::assert_approx_rel(
        oracle1.get_binary_price(forward, true, &clock),
        gs::SYN_A100M_UP_ATM!(),
    );
    // Higher a lowers ATM UP price
    assert_eq!(gs::SYN_A100M_UP_ATM!() < gs::SYN_STD_UP_ATM!(), true);

    destroy(oracle0);
    destroy(oracle1);
    clock.destroy_for_testing();
}

#[test]
fun live_negative_rho_affects_wings() {
    // Negative rho skews the smile
    let ctx = &mut tx_context::dummy();
    let svi_no_skew = new_svi_params(0, FLOAT, 0, false, 0, false, SIGMA_25);
    let svi_skew = new_svi_params(0, FLOAT, 500_000_000, true, 0, false, SIGMA_25);

    let forward = 100 * FLOAT;
    let prices = new_price_data(forward, forward);

    let oracle_no = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi_no_skew,
        prices,
        0,
        1_000_000,
        0,
        ctx,
    );
    let oracle_sk = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi_skew,
        prices,
        0,
        1_000_000,
        0,
        ctx,
    );

    let clock = clock::create_for_testing(ctx);

    // Check complement property still holds with skew
    let otm_put_strike = 80 * FLOAT;
    let up_no = oracle_no.get_binary_price(otm_put_strike, true, &clock);
    let dn_no = oracle_no.get_binary_price(otm_put_strike, false, &clock);
    let up_sk = oracle_sk.get_binary_price(otm_put_strike, true, &clock);
    let dn_sk = oracle_sk.get_binary_price(otm_put_strike, false, &clock);

    assert_eq!(up_no + dn_no, FLOAT);
    assert_eq!(up_sk + dn_sk, FLOAT);

    // Prices should differ with skew
    assert!(up_no != up_sk);

    destroy(oracle_no);
    destroy(oracle_sk);
    clock.destroy_for_testing();
}

#[test]
fun live_nonzero_m_shifts_smile() {
    let ctx = &mut tx_context::dummy();
    let svi_m0 = new_svi_params(0, FLOAT, 0, false, 0, false, SIGMA_25);
    let svi_m_pos = new_svi_params(0, FLOAT, 0, false, 100_000_000, false, SIGMA_25);

    let forward = 100 * FLOAT;
    let prices = new_price_data(forward, forward);

    let oracle0 = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi_m0,
        prices,
        0,
        1_000_000,
        0,
        ctx,
    );
    let oracle1 = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi_m_pos,
        prices,
        0,
        1_000_000,
        0,
        ctx,
    );

    let clock = clock::create_for_testing(ctx);

    let up0 = oracle0.get_binary_price(forward, true, &clock);
    let up1 = oracle1.get_binary_price(forward, true, &clock);
    let dn0 = oracle0.get_binary_price(forward, false, &clock);
    let dn1 = oracle1.get_binary_price(forward, false, &clock);

    // ATM prices differ since m shifts the SVI surface
    assert!(up0 != up1);
    assert_eq!(up0 + dn0, FLOAT);
    assert_eq!(up1 + dn1, FLOAT);

    destroy(oracle0);
    destroy(oracle1);
    clock.destroy_for_testing();
}

#[test]
fun live_small_sigma_atm_near_half() {
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, FLOAT, 0, false, 0, false, SIGMA_01);
    let forward = 100 * FLOAT;
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

    precision::assert_approx_rel(
        oracle.get_binary_price(forward, true, &clock),
        gs::SYN_SMALL_SIGMA_UP_ATM!(),
    );
    precision::assert_approx_rel(
        oracle.get_binary_price(forward, false, &clock),
        gs::SYN_SMALL_SIGMA_DN_ATM!(),
    );

    destroy(oracle);
    clock.destroy_for_testing();
}

// ============================================================
// Discount computation
// ============================================================

#[test]
fun discount_positive_rate_half_year() {
    // rate=10%, half year: discount = SYN_DISCOUNT_10PCT_HALF_YR
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, FLOAT, 0, false, 0, false, SIGMA_25);
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

    let sum = up + dn;
    assert_eq!(sum, gs::SYN_DISCOUNT_10PCT_HALF_YR!());

    destroy(oracle);
    clock.destroy_for_testing();
}

// ============================================================
// build_curve -- settled oracle
// ============================================================

#[test]
fun build_curve_settled_oracle() {
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, FLOAT, 0, false, 0, false, SIGMA_25);
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
    clock.destroy_for_testing();
}

// ============================================================
// build_curve -- single strike edge case
// ============================================================

#[test]
fun build_curve_single_strike() {
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, FLOAT, 0, false, 0, false, SIGMA_25);
    let forward = 100 * FLOAT;
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
    let curve = oracle.build_curve(100 * FLOAT, 100 * FLOAT, &clock);

    assert_eq!(curve.length(), 1);
    let pt = &curve[0];
    assert_eq!(pt.strike(), 100 * FLOAT);
    assert_eq!(pt.up_price() + pt.dn_price(), FLOAT);

    destroy(oracle);
    clock.destroy_for_testing();
}

// ============================================================
// build_curve -- live oracle properties
// ============================================================

#[test]
fun build_curve_live_sorted_and_complement() {
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, FLOAT, 0, false, 0, false, SIGMA_25);
    let forward = 100 * FLOAT;
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

    let len = curve.length();
    // At least min, forward, max
    assert!(len >= 3);

    // Sorted by strike
    let mut i = 0;
    while (i < len - 1) {
        assert!(curve[i].strike() < curve[i + 1].strike());
        i = i + 1;
    };

    // Complement: UP + DN = discount = FLOAT (rate=0)
    i = 0;
    while (i < len) {
        assert_eq!(curve[i].up_price() + curve[i].dn_price(), FLOAT);
        i = i + 1;
    };

    // UP prices monotonically non-increasing
    i = 0;
    while (i < len - 1) {
        assert!(curve[i].up_price() >= curve[i + 1].up_price());
        i = i + 1;
    };

    destroy(oracle);
    clock.destroy_for_testing();
}

#[test]
fun build_curve_includes_forward_when_in_range() {
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, FLOAT, 0, false, 0, false, SIGMA_25);
    let forward = 100 * FLOAT;
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

    let mut found = false;
    curve.do_ref!(|pt| {
        if (pt.strike() == forward) found = true;
    });
    assert!(found);

    destroy(oracle);
    clock.destroy_for_testing();
}

#[test]
fun build_curve_no_duplicate_when_forward_at_boundary() {
    // When forward == min_strike, no duplicate
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, FLOAT, 0, false, 0, false, SIGMA_25);
    let forward = 100 * FLOAT;
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
    let curve = oracle.build_curve(forward, 150 * FLOAT, &clock);

    // All strikes must be strictly increasing (no duplicates)
    let len = curve.length();
    let mut i = 0;
    while (i < len - 1) {
        assert!(curve[i].strike() < curve[i + 1].strike());
        i = i + 1;
    };

    destroy(oracle);
    clock.destroy_for_testing();
}

#[test]
fun build_curve_endpoints_match_min_max() {
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, FLOAT, 0, false, 0, false, SIGMA_25);
    let forward = 100 * FLOAT;
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
    let min_strike = 50 * FLOAT;
    let max_strike = 150 * FLOAT;
    let curve = oracle.build_curve(min_strike, max_strike, &clock);

    // First point should be min_strike, last should be max_strike
    assert_eq!(curve[0].strike(), min_strike);
    assert_eq!(curve[curve.length() - 1].strike(), max_strike);

    destroy(oracle);
    clock.destroy_for_testing();
}

// ============================================================
// Exact normal_cdf values from contract for specific d2 magnitudes
// ============================================================

// ============================================================
// Edge cases
// ============================================================

#[test]
fun live_forward_one_unit_above_strike() {
    // Very close to ATM: strike = forward - 1
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, FLOAT, 0, false, 0, false, SIGMA_25);
    let forward = 100 * FLOAT;
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
    let strike = forward - 1;

    let up = oracle.get_binary_price(strike, true, &clock);
    let dn = oracle.get_binary_price(strike, false, &clock);

    // Should be nearly identical to ATM since difference is 1 unit
    assert_eq!(up + dn, FLOAT);

    destroy(oracle);
    clock.destroy_for_testing();
}

#[test]
fun build_curve_with_positive_rate_complement() {
    // With positive rate, UP + DN = discount < FLOAT
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, FLOAT, 0, false, 0, false, SIGMA_25);
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

    // All curve points use the same discount factor.
    // eval_strike computes: up = mul(discount, nd2), dn = discount - up
    // So up + dn = discount exactly for every point (no rounding split).
    let len = curve.length();
    let mut i = 0;
    while (i < len) {
        let sum = curve[i].up_price() + curve[i].dn_price();
        precision::assert_approx_rel(sum, gs::SYN_DISCOUNT_5PCT_1YR!());
        i = i + 1;
    };

    destroy(oracle);
    clock.destroy_for_testing();
}

// ============================================================
// Exact-value tests: independently compute expected oracle output
// ============================================================

#[test]
fun exact_otm_d2_forward_price() {
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, FLOAT, 0, false, 0, false, SIGMA_25);
    let forward = 100 * FLOAT;
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

    precision::assert_approx_rel(
        oracle.get_binary_price(gs::SYN_STD_STRIKE_OTM_D2!(), true, &clock),
        gs::SYN_STD_UP_OTM_D2!(),
    );
    precision::assert_approx_rel(
        oracle.get_binary_price(gs::SYN_STD_STRIKE_OTM_D2!(), false, &clock),
        gs::SYN_STD_DN_OTM_D2!(),
    );

    destroy(oracle);
    clock.destroy_for_testing();
}

#[test]
fun exact_discount_with_partial_year() {
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, FLOAT, 0, false, 0, false, SIGMA_25);
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

    precision::assert_approx_rel(
        oracle.get_binary_price(forward, true, &clock),
        gs::SYN_10PCT_PARTIAL_UP_ATM!(),
    );
    precision::assert_approx_rel(
        oracle.get_binary_price(forward, false, &clock),
        gs::SYN_10PCT_PARTIAL_DN_ATM!(),
    );

    destroy(oracle);
    clock.destroy_for_testing();
}

#[test]
fun exact_full_svi_params() {
    // a=50M, b=800M, rho=-300M, m=100M, sigma=200M, ATM, rate=0
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(
        50_000_000,
        800_000_000,
        300_000_000,
        true,
        100_000_000,
        false,
        200_000_000,
    );
    let forward = 100 * FLOAT;
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

    precision::assert_approx_rel(
        oracle.get_binary_price(forward, true, &clock),
        gs::SYN_FULL_UP_ATM!(),
    );
    precision::assert_approx_rel(
        oracle.get_binary_price(forward, false, &clock),
        gs::SYN_FULL_DN_ATM!(),
    );

    destroy(oracle);
    clock.destroy_for_testing();
}

// ============================================================
// Edge: zero forward aborts (div by zero)
// ============================================================

#[test, expected_failure]
fun live_price_with_zero_forward_aborts() {
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, FLOAT, 0, false, 0, false, SIGMA_25);
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
// build_curve: forward outside range
// ============================================================

#[test]
fun build_curve_forward_outside_range() {
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, FLOAT, 0, false, 0, false, SIGMA_25);
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

    // Sorted
    let len = curve.length();
    let mut i = 0;
    while (i < len - 1) {
        assert!(curve[i].strike() < curve[i + 1].strike());
        i = i + 1;
    };

    destroy(oracle);
    clock.destroy_for_testing();
}

// ============================================================
// Settled oracle: build_curve at different settlement
// ============================================================

#[test]
fun build_curve_settled_at_75() {
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, FLOAT, 0, false, 0, false, SIGMA_25);
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
    clock.destroy_for_testing();
}

// ============================================================
// Prices bounded between 0 and discount for non-extreme strikes
// ============================================================

#[test]
fun live_prices_bounded_between_zero_and_discount() {
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, FLOAT, 0, false, 0, false, SIGMA_25);
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

    precision::assert_approx_rel(
        oracle.get_binary_price(gs::SYN_5PCT_STRIKE_OTM_D1!(), true, &clock),
        gs::SYN_5PCT_UP_OTM_D1!(),
    );
    precision::assert_approx_rel(
        oracle.get_binary_price(gs::SYN_5PCT_STRIKE_OTM_D1!(), false, &clock),
        gs::SYN_5PCT_DN_OTM_D1!(),
    );
    precision::assert_approx_rel(
        oracle.get_binary_price(gs::SYN_5PCT_STRIKE_ATM!(), true, &clock),
        gs::SYN_5PCT_UP_ATM!(),
    );
    precision::assert_approx_rel(
        oracle.get_binary_price(gs::SYN_5PCT_STRIKE_ATM!(), false, &clock),
        gs::SYN_5PCT_DN_ATM!(),
    );
    precision::assert_approx_rel(
        oracle.get_binary_price(gs::SYN_5PCT_STRIKE_ITM_D1!(), true, &clock),
        gs::SYN_5PCT_UP_ITM_D1!(),
    );
    precision::assert_approx_rel(
        oracle.get_binary_price(gs::SYN_5PCT_STRIKE_ITM_D1!(), false, &clock),
        gs::SYN_5PCT_DN_ITM_D1!(),
    );

    destroy(oracle);
    clock.destroy_for_testing();
}

// ============================================================
// Abort code coverage
// ============================================================

#[test, expected_failure(abort_code = oracle::EInvalidOracleCap)]
fun activate_with_unauthorized_cap_aborts() {
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, FLOAT, 0, false, 0, false, SIGMA_25);
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
    let cap = oracle::create_oracle_cap(ctx);
    let clock = clock::create_for_testing(ctx);

    // Cap is not registered on this oracle
    oracle.activate(&cap, &clock);

    abort
}

#[test, expected_failure(abort_code = oracle::EOracleAlreadyActive)]
fun activate_already_active_oracle_aborts() {
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, FLOAT, 0, false, 0, false, SIGMA_25);
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

    // Oracle is already active (create_test_oracle sets active=true)
    oracle.activate(&cap, &clock);

    abort
}

#[test, expected_failure(abort_code = oracle::EOracleExpired)]
fun activate_expired_oracle_aborts() {
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, FLOAT, 0, false, 0, false, SIGMA_25);
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
    oracle.set_active_for_testing(false);
    let cap = oracle::create_oracle_cap(ctx);
    oracle::register_cap(&mut oracle, &cap);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(200_000);

    oracle.activate(&cap, &clock);

    abort
}

#[test, expected_failure(abort_code = oracle::EOracleExpired)]
fun update_svi_on_settled_oracle_aborts() {
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(0, FLOAT, 0, false, 0, false, SIGMA_25);
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
    oracle::settle_test_oracle(&mut oracle, 100 * FLOAT);

    let clock = clock::create_for_testing(ctx);
    let new_svi = new_svi_params(0, FLOAT, 0, false, 0, false, SIGMA_25);
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
    // a=0, b=0 → total_var = 0 → division by zero in compute_nd2
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
// Real-world pricing — Block Scholes SVI data (ground truth from scipy)
// ============================================================

// S0: tte=6.9d — far from expiry
#[test]
fun realworld_s0_binary_prices() {
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(
        gs::S0_A!(),
        gs::S0_B!(),
        gs::S0_RHO!(),
        gs::S0_RHO_NEG!() == 1,
        gs::S0_M!(),
        gs::S0_M_NEG!() == 1,
        gs::S0_SIGMA!(),
    );
    let prices = new_price_data(gs::S0_SPOT!(), gs::S0_FORWARD!());
    let oracle = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi,
        prices,
        gs::S0_RATE!(),
        gs::S0_EXPIRY_MS!(),
        gs::S0_NOW_MS!(),
        ctx,
    );
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(gs::S0_NOW_MS!());

    precision::assert_approx_rel(
        oracle.get_binary_price(gs::S0_STRIKE_ATM!(), true, &clock),
        gs::S0_UP_ATM!(),
    );
    precision::assert_approx_rel(
        oracle.get_binary_price(gs::S0_STRIKE_ATM!(), false, &clock),
        gs::S0_DN_ATM!(),
    );
    precision::assert_approx_rel(
        oracle.get_binary_price(gs::S0_STRIKE_OTM10!(), true, &clock),
        gs::S0_UP_OTM10!(),
    );
    precision::assert_approx_rel(
        oracle.get_binary_price(gs::S0_STRIKE_ITM10!(), true, &clock),
        gs::S0_UP_ITM10!(),
    );

    destroy(oracle);
    clock.destroy_for_testing();
}

// S3: tte=1.2d — medium term
#[test]
fun realworld_s3_binary_prices() {
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(
        gs::S3_A!(),
        gs::S3_B!(),
        gs::S3_RHO!(),
        gs::S3_RHO_NEG!() == 1,
        gs::S3_M!(),
        gs::S3_M_NEG!() == 1,
        gs::S3_SIGMA!(),
    );
    let prices = new_price_data(gs::S3_SPOT!(), gs::S3_FORWARD!());
    let oracle = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi,
        prices,
        gs::S3_RATE!(),
        gs::S3_EXPIRY_MS!(),
        gs::S3_NOW_MS!(),
        ctx,
    );
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(gs::S3_NOW_MS!());

    precision::assert_approx_rel(
        oracle.get_binary_price(gs::S3_STRIKE_ATM!(), true, &clock),
        gs::S3_UP_ATM!(),
    );
    precision::assert_approx_rel(
        oracle.get_binary_price(gs::S3_STRIKE_ATM!(), false, &clock),
        gs::S3_DN_ATM!(),
    );
    precision::assert_approx_rel(
        oracle.get_binary_price(gs::S3_STRIKE_OTM5!(), true, &clock),
        gs::S3_UP_OTM5!(),
    );
    precision::assert_approx_rel(
        oracle.get_binary_price(gs::S3_STRIKE_ITM5!(), false, &clock),
        gs::S3_DN_ITM5!(),
    );

    destroy(oracle);
    clock.destroy_for_testing();
}

// S6: tte=5m — near expiry
#[test]
fun realworld_s6_near_expiry_prices() {
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(
        gs::S6_A!(),
        gs::S6_B!(),
        gs::S6_RHO!(),
        gs::S6_RHO_NEG!() == 1,
        gs::S6_M!(),
        gs::S6_M_NEG!() == 1,
        gs::S6_SIGMA!(),
    );
    let prices = new_price_data(gs::S6_SPOT!(), gs::S6_FORWARD!());
    let oracle = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi,
        prices,
        gs::S6_RATE!(),
        gs::S6_EXPIRY_MS!(),
        gs::S6_NOW_MS!(),
        ctx,
    );
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(gs::S6_NOW_MS!());

    precision::assert_approx_rel(
        oracle.get_binary_price(gs::S6_STRIKE_ATM!(), true, &clock),
        gs::S6_UP_ATM!(),
    );
    precision::assert_approx_rel(
        oracle.get_binary_price(gs::S6_STRIKE_ATM!(), false, &clock),
        gs::S6_DN_ATM!(),
    );
    precision::assert_approx_rel(
        oracle.get_binary_price(gs::S6_STRIKE_OTM10!(), true, &clock),
        gs::S6_UP_OTM10!(),
    );
    precision::assert_approx_rel(
        oracle.get_binary_price(gs::S6_STRIKE_ITM10!(), true, &clock),
        gs::S6_UP_ITM10!(),
    );

    destroy(oracle);
    clock.destroy_for_testing();
}

// S7: tte=31s — extreme near-expiry
#[test]
fun realworld_s7_extreme_near_expiry_prices() {
    let ctx = &mut tx_context::dummy();
    let svi = new_svi_params(
        gs::S7_A!(),
        gs::S7_B!(),
        gs::S7_RHO!(),
        gs::S7_RHO_NEG!() == 1,
        gs::S7_M!(),
        gs::S7_M_NEG!() == 1,
        gs::S7_SIGMA!(),
    );
    let prices = new_price_data(gs::S7_SPOT!(), gs::S7_FORWARD!());
    let oracle = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi,
        prices,
        gs::S7_RATE!(),
        gs::S7_EXPIRY_MS!(),
        gs::S7_NOW_MS!(),
        ctx,
    );
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(gs::S7_NOW_MS!());

    precision::assert_approx_rel(
        oracle.get_binary_price(gs::S7_STRIKE_ATM!(), true, &clock),
        gs::S7_UP_ATM!(),
    );
    precision::assert_approx_rel(
        oracle.get_binary_price(gs::S7_STRIKE_ATM!(), false, &clock),
        gs::S7_DN_ATM!(),
    );
    precision::assert_approx_rel(
        oracle.get_binary_price(gs::S7_STRIKE_OTM5!(), true, &clock),
        gs::S7_UP_OTM5!(),
    );
    precision::assert_approx_rel(
        oracle.get_binary_price(gs::S7_STRIKE_ITM5!(), true, &clock),
        gs::S7_UP_ITM5!(),
    );

    destroy(oracle);
    clock.destroy_for_testing();
}
