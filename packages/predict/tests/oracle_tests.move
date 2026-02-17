// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::oracle_tests;

use deepbook_predict::{constants, oracle};
use std::unit_test::destroy;
use sui::clock;

public struct BTC has drop {}

/// ATM: UP + DOWN prices should sum to ~discount factor.
/// With 5% rate and 7-day expiry, discount ≈ 0.999 — so sum ≈ 1e9.
#[test]
fun atm_up_down_sum_to_discount() {
    let ctx = &mut tx_context::dummy();

    let svi = oracle::new_svi_params(
        40_000_000, // a = 0.04
        100_000_000, // b = 0.1
        300_000_000, // rho = 0.3
        true, // rho_negative
        0, // m = 0
        false,
        100_000_000, // sigma = 0.1
    );
    let prices = oracle::new_price_data(100_000_000_000_000, 100_500_000_000_000);
    let risk_free_rate = 50_000_000; // 5%

    let now_ms = 1_000_000_000;
    let expiry_ms = now_ms + 604_800_000; // +7 days

    let oracle = oracle::create_test_oracle<BTC>(
        svi,
        prices,
        risk_free_rate,
        expiry_ms,
        now_ms,
        ctx,
    );

    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(now_ms);

    let strike = 100_000_000_000_000; // $100k ATM

    let up = oracle.get_binary_price(strike, true, &clock);
    let down = oracle.get_binary_price(strike, false, &clock);
    let sum = up + down;

    // UP and DOWN should each be between 0 and 100%
    assert!(up > 0 && up < constants::float_scaling!());
    assert!(down > 0 && down < constants::float_scaling!());
    // Sum should be close to discount factor (~0.999 for 5% rate, 7 days)
    // Allow 1% tolerance: sum in [0.99e9, 1.01e9]
    assert!(sum > 990_000_000 && sum < 1_010_000_000, sum);

    destroy(oracle);
    clock.destroy_for_testing();
}

/// OTM put: strike well below forward → UP price high, DOWN price low.
#[test]
fun otm_put_prices_directional() {
    let ctx = &mut tx_context::dummy();

    let svi = oracle::new_svi_params(
        40_000_000,
        100_000_000,
        300_000_000,
        true,
        0,
        false,
        100_000_000,
    );
    let prices = oracle::new_price_data(100_000_000_000_000, 100_500_000_000_000);
    let risk_free_rate = 50_000_000;

    let now_ms = 1_000_000_000;
    let expiry_ms = now_ms + 604_800_000;

    let oracle = oracle::create_test_oracle<BTC>(
        svi,
        prices,
        risk_free_rate,
        expiry_ms,
        now_ms,
        ctx,
    );

    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(now_ms);

    let strike = 90_000_000_000_000; // $90k — well below $100.5k forward

    let up = oracle.get_binary_price(strike, true, &clock);
    let down = oracle.get_binary_price(strike, false, &clock);

    // Strike far below forward: UP should be > 50%, DOWN should be < 50%
    assert!(up > 500_000_000);
    assert!(down < 500_000_000);
    // UP + DOWN ≈ discount factor
    let sum = up + down;
    assert!(sum > 990_000_000 && sum < 1_010_000_000, sum);

    destroy(oracle);
    clock.destroy_for_testing();
}

/// OTM call: strike well above forward → UP price low, DOWN price high.
#[test]
fun otm_call_prices_directional() {
    let ctx = &mut tx_context::dummy();

    let svi = oracle::new_svi_params(
        40_000_000,
        100_000_000,
        300_000_000,
        true,
        0,
        false,
        100_000_000,
    );
    let prices = oracle::new_price_data(100_000_000_000_000, 100_500_000_000_000);
    let risk_free_rate = 50_000_000;

    let now_ms = 1_000_000_000;
    let expiry_ms = now_ms + 604_800_000;

    let oracle = oracle::create_test_oracle<BTC>(
        svi,
        prices,
        risk_free_rate,
        expiry_ms,
        now_ms,
        ctx,
    );

    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(now_ms);

    let strike = 110_000_000_000_000; // $110k — well above $100.5k forward

    let up = oracle.get_binary_price(strike, true, &clock);
    let down = oracle.get_binary_price(strike, false, &clock);

    // Strike far above forward: UP should be < 50%, DOWN should be > 50%
    assert!(up < 500_000_000);
    assert!(down > 500_000_000);
    let sum = up + down;
    assert!(sum > 990_000_000 && sum < 1_010_000_000, sum);

    destroy(oracle);
    clock.destroy_for_testing();
}

/// Non-zero m shift and positive rho — verify sum invariant still holds.
#[test]
fun shifted_params_sum_invariant() {
    let ctx = &mut tx_context::dummy();

    let svi = oracle::new_svi_params(
        20_000_000, // a = 0.02
        150_000_000, // b = 0.15
        500_000_000, // rho = 0.5
        false, // rho positive
        50_000_000, // m = 0.05
        true, // m negative
        200_000_000, // sigma = 0.2
    );
    let prices = oracle::new_price_data(50_000_000_000_000, 50_200_000_000_000);
    let risk_free_rate = 30_000_000; // 3%

    let now_ms = 1_000_000_000;
    let expiry_ms = now_ms + 2_592_000_000; // +30 days

    let oracle = oracle::create_test_oracle<BTC>(
        svi,
        prices,
        risk_free_rate,
        expiry_ms,
        now_ms,
        ctx,
    );

    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(now_ms);

    let strike = 52_000_000_000_000; // $52k

    let up = oracle.get_binary_price(strike, true, &clock);
    let down = oracle.get_binary_price(strike, false, &clock);

    assert!(up > 0 && up < constants::float_scaling!());
    assert!(down > 0 && down < constants::float_scaling!());
    let sum = up + down;
    // 30-day expiry at 3% → discount ≈ 0.9975, allow wider tolerance
    assert!(sum > 980_000_000 && sum < 1_020_000_000, sum);

    destroy(oracle);
    clock.destroy_for_testing();
}

/// Short expiry (1 day) — prices still valid and sum correctly.
#[test]
fun short_expiry_sum_invariant() {
    let ctx = &mut tx_context::dummy();

    let svi = oracle::new_svi_params(
        40_000_000,
        100_000_000,
        300_000_000,
        true,
        0,
        false,
        100_000_000,
    );
    let prices = oracle::new_price_data(100_000_000_000_000, 100_100_000_000_000);
    let risk_free_rate = 50_000_000;

    let now_ms = 1_000_000_000;
    let expiry_ms = now_ms + 86_400_000; // +1 day

    let oracle = oracle::create_test_oracle<BTC>(
        svi,
        prices,
        risk_free_rate,
        expiry_ms,
        now_ms,
        ctx,
    );

    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(now_ms);

    let strike = 100_000_000_000_000;

    let up = oracle.get_binary_price(strike, true, &clock);
    let down = oracle.get_binary_price(strike, false, &clock);

    assert!(up > 0 && up < constants::float_scaling!());
    assert!(down > 0 && down < constants::float_scaling!());
    let sum = up + down;
    assert!(sum > 990_000_000 && sum < 1_010_000_000, sum);

    destroy(oracle);
    clock.destroy_for_testing();
}
