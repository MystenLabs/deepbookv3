// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::predict_tests;

use deepbook_predict::{
    constants::float_scaling as float,
    market_key,
    oracle::{Self, new_price_data, new_svi_params},
    predict,
};
use sui::{clock, sui::SUI};

const GRID_MIN_STRIKE: u64 = 10_000;
const GRID_TICK_SIZE: u64 = 10_000;
const GRID_MAX_STRIKE: u64 = GRID_MIN_STRIKE + GRID_TICK_SIZE * 100_000;

#[test, expected_failure(abort_code = oracle::EStrikeNotOnTick)]
fun get_trade_amounts_invalid_strike_aborts() {
    let ctx = &mut tx_context::dummy();

    let predict = predict::create_test_predict<SUI>(ctx);
    let svi = new_svi_params(0, float!(), 0, false, 0, false, 250_000_000);
    let prices = new_price_data(500_000_000, 500_000_000);
    let oracle = oracle::create_test_oracle_with_grid(
        b"BTC".to_string(),
        svi,
        prices,
        0,
        1_000_000,
        0,
        GRID_MIN_STRIKE,
        GRID_MAX_STRIKE,
        GRID_TICK_SIZE,
        ctx,
    );
    let key = market_key::up(oracle::id(&oracle), oracle::expiry(&oracle), 500_000_001);
    let clock = clock::create_for_testing(ctx);

    predict::get_trade_amounts(&predict, &oracle, key, 1, &clock);

    abort
}

#[test, expected_failure(abort_code = predict::EOracleInactive)]
fun get_trade_amounts_inactive_oracle_aborts() {
    let ctx = &mut tx_context::dummy();

    let predict = predict::create_test_predict<SUI>(ctx);
    let svi = new_svi_params(0, float!(), 0, false, 0, false, 250_000_000);
    let prices = new_price_data(500_000_000, 500_000_000);
    let mut oracle = oracle::create_test_oracle_with_grid(
        b"BTC".to_string(),
        svi,
        prices,
        0,
        1_000_000,
        0,
        GRID_MIN_STRIKE,
        GRID_MAX_STRIKE,
        GRID_TICK_SIZE,
        ctx,
    );
    oracle::set_active_for_testing(&mut oracle, false);
    let key = market_key::up(oracle::id(&oracle), oracle::expiry(&oracle), GRID_MIN_STRIKE);
    let clock = clock::create_for_testing(ctx);

    predict::get_trade_amounts(&predict, &oracle, key, 1, &clock);

    abort
}
