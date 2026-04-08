// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Shared test helper for building oracle state through real entrypoints and
/// explicitly wiring Predict runtime strike grids around it.
#[test_only]
module deepbook_predict::oracle_helper;

use deepbook_predict::{
    constants::{float_scaling as float, oracle_tick_size_unit},
    generated_oracle::OracleScenario,
    i64,
    oracle::{
        Self as oracle,
        OracleSVICap,
        OracleSVI,
        PriceData,
        SVIParams,
        new_price_data,
        new_svi_params
    },
    predict::{Self as predict, Predict}
};
use std::{string::String, unit_test::destroy};
use sui::{clock, test_scenario::{Self as test_scenario, Scenario}};

fun signed(magnitude: u64, is_negative: bool): i64::I64 {
    i64::from_parts(magnitude, is_negative)
}

fun flat_vol_svi(): SVIParams {
    new_svi_params(0, 1_000_000_000, signed(0, false), signed(0, false), 250_000_000)
}

fun zero_svi(): SVIParams {
    new_svi_params(0, 0, signed(0, false), signed(0, false), 0)
}

/// Attach a Predict strike grid to an oracle ID inside a test Predict object.
public fun add_grid_to_predict(
    test_predict: &mut Predict,
    oracle: &OracleSVI,
    min_strike: u64,
    tick_size: u64,
    ctx: &mut TxContext,
) {
    predict::add_oracle_grid(test_predict, oracle.id(), min_strike, tick_size, ctx);
}

/// Attach a scenario-defined strike grid to an oracle ID inside a test Predict object.
public fun add_scenario_grid_to_predict(
    test_predict: &mut Predict,
    oracle: &OracleSVI,
    scenario: &OracleScenario,
    ctx: &mut TxContext,
) {
    add_grid_to_predict(
        test_predict,
        oracle,
        scenario.min_strike(),
        scenario.tick_size(),
        ctx,
    );
}

/// Default grid for standard runtime tests around spot ~= 100.
public fun default_std_grid(): (u64, u64) {
    (50 * float!(), oracle_tick_size_unit!() * 100)
}

/// Create an extra cap and transfer it to `sender` without registering it.
/// This is useful for unauthorized-cap tests.
public fun create_unregistered_cap(sender: address, test: &mut Scenario): ID {
    test.next_tx(sender);
    let cap = oracle::create_oracle_cap(test.ctx());
    let cap_id = object::id(&cap);
    transfer::public_transfer(cap, sender);
    cap_id
}

/// Create a shared oracle plus a registered cap inside a scenario.
/// The cap is returned to `sender`, so later helper calls can take it from
/// sender inventory and drive real oracle entrypoints.
public fun setup_shared_oracle(
    sender: address,
    underlying_asset: String,
    expiry_ms: u64,
    test: &mut Scenario,
): (ID, ID) {
    test.next_tx(sender);
    let cap = oracle::create_oracle_cap(test.ctx());
    let cap_id = object::id(&cap);
    transfer::public_transfer(cap, sender);

    let oracle_id = oracle::create_oracle(underlying_asset, expiry_ms, test.ctx());
    test.next_tx(sender);
    {
        let mut oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let cap = test.take_from_sender<OracleSVICap>();
        oracle::register_cap(&mut oracle_state, &cap);
        test_scenario::return_shared(oracle_state);
        test.return_to_sender(cap);
    };

    (oracle_id, cap_id)
}

/// Configure a shared oracle through real `update_svi` and `update_prices` calls.
/// If `active` is true, the oracle is activated after state updates.
public fun configure_shared_oracle(
    sender: address,
    oracle_id: ID,
    svi: SVIParams,
    prices: PriceData,
    risk_free_rate: u64,
    now_ms: u64,
    active: bool,
    test: &mut Scenario,
) {
    test.next_tx(sender);
    {
        let mut oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let cap = test.take_from_sender<OracleSVICap>();
        let mut test_clock = clock::create_for_testing(test.ctx());
        test_clock.set_for_testing(now_ms);

        oracle::update_svi(
            &mut oracle_state,
            &cap,
            svi,
            risk_free_rate,
            &test_clock,
        );
        oracle::update_prices(
            &mut oracle_state,
            &cap,
            prices,
            &test_clock,
        );
        if (active) {
            oracle::activate(&mut oracle_state, &cap, &test_clock);
        };

        destroy(test_clock);
        test_scenario::return_shared(oracle_state);
        test.return_to_sender(cap);
    };
}

/// Force a shared oracle to settle by advancing past expiry and calling the
/// real `update_prices` entrypoint with the desired settlement spot.
public fun settle_shared_oracle(
    sender: address,
    oracle_id: ID,
    settlement_price: u64,
    now_ms: u64,
    test: &mut Scenario,
) {
    test.next_tx(sender);
    {
        let mut oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let cap = test.take_from_sender<OracleSVICap>();
        let mut test_clock = clock::create_for_testing(test.ctx());
        test_clock.set_for_testing(now_ms);

        oracle::update_prices(
            &mut oracle_state,
            &cap,
            new_price_data(settlement_price, settlement_price),
            &test_clock,
        );

        destroy(test_clock);
        test_scenario::return_shared(oracle_state);
        test.return_to_sender(cap);
    };
}

/// Scenario convenience: build a registered shared oracle and configure it to
/// the requested core state in one step.
public fun setup_configured_shared_oracle(
    sender: address,
    underlying_asset: String,
    svi: SVIParams,
    prices: PriceData,
    risk_free_rate: u64,
    expiry_ms: u64,
    now_ms: u64,
    active: bool,
    test: &mut Scenario,
): ID {
    let (oracle_id, _cap_id) = setup_shared_oracle(
        sender,
        underlying_asset,
        expiry_ms,
        test,
    );
    configure_shared_oracle(
        sender,
        oracle_id,
        svi,
        prices,
        risk_free_rate,
        now_ms,
        active,
        test,
    );
    oracle_id
}

/// Scenario convenience for generated oracle fixtures.
public fun setup_oracle_from_scenario(
    sender: address,
    scenario: &OracleScenario,
    active: bool,
    test: &mut Scenario,
): ID {
    let svi = new_svi_params(
        scenario.a(),
        scenario.b(),
        signed(scenario.rho(), scenario.rho_neg()),
        signed(scenario.m(), scenario.m_neg()),
        scenario.sigma(),
    );
    let prices = new_price_data(scenario.spot(), scenario.forward());
    setup_configured_shared_oracle(
        sender,
        b"BTC".to_string(),
        svi,
        prices,
        scenario.rate(),
        scenario.expiry_ms(),
        scenario.now_ms(),
        active,
        test,
    )
}

/// Scenario convenience for a zero-SVI oracle.
public fun setup_simple_shared_oracle(
    sender: address,
    spot: u64,
    forward: u64,
    expiry_ms: u64,
    now_ms: u64,
    active: bool,
    test: &mut Scenario,
): ID {
    setup_configured_shared_oracle(
        sender,
        b"BTC".to_string(),
        zero_svi(),
        new_price_data(spot, forward),
        0,
        expiry_ms,
        now_ms,
        active,
        test,
    )
}

/// Scenario convenience for the standard live oracle used in exact-pricing tests.
public fun setup_std_shared_oracle(sender: address, active: bool, test: &mut Scenario): ID {
    setup_flat_vol_shared_oracle(
        sender,
        100 * float!(),
        100 * float!(),
        0,
        1_000_000,
        0,
        active,
        test,
    )
}

/// Scenario convenience for a flat 25%-vol oracle.
public fun setup_flat_vol_shared_oracle(
    sender: address,
    spot: u64,
    forward: u64,
    rate: u64,
    expiry_ms: u64,
    now_ms: u64,
    active: bool,
    test: &mut Scenario,
): ID {
    setup_configured_shared_oracle(
        sender,
        b"BTC".to_string(),
        flat_vol_svi(),
        new_price_data(spot, forward),
        rate,
        expiry_ms,
        now_ms,
        active,
        test,
    )
}

/// Scenario convenience for a settled oracle.
public fun setup_settled_shared_oracle(
    sender: address,
    settlement_price: u64,
    test: &mut Scenario,
): ID {
    let oracle_id = setup_simple_shared_oracle(
        sender,
        0,
        0,
        100_000,
        0,
        false,
        test,
    );
    settle_shared_oracle(sender, oracle_id, settlement_price, 100_001, test);
    oracle_id
}
