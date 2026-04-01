// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Shared test helper for constructing oracles from generated scenario constants.
#[test_only]
module deepbook_predict::oracle_helper;

use deepbook_predict::{
    generated_oracle::OracleScenario,
    oracle::{Self, OracleSVI, OracleCapSVI, new_price_data, new_svi_params}
};
use sui::clock::{Self, Clock};

/// Create oracle + clock from an OracleScenario struct.
public fun create_from_scenario(s: &OracleScenario, ctx: &mut TxContext): (OracleSVI, Clock) {
    let svi = new_svi_params(s.a(), s.b(), s.rho(), s.rho_neg(), s.m(), s.m_neg(), s.sigma());
    let prices = new_price_data(s.spot(), s.forward());
    let oracle = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi,
        prices,
        s.rate(),
        s.expiry_ms(),
        s.now_ms(),
        ctx,
    );
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(s.now_ms());
    (oracle, clock)
}

/// Zero-SVI oracle for staleness/settlement tests.
/// Clock is set to `now_ms` for consistency with `create_from_scenario`.
public fun create_simple_oracle(
    spot: u64,
    forward: u64,
    expiry_ms: u64,
    now_ms: u64,
    ctx: &mut TxContext,
): (OracleSVI, Clock) {
    let svi = new_svi_params(0, 0, 0, false, 0, false, 0);
    let prices = new_price_data(spot, forward);
    let oracle = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi,
        prices,
        0,
        expiry_ms,
        now_ms,
        ctx,
    );
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(now_ms);
    (oracle, clock)
}

/// Standard oracle for unit tests: a=0, b=1, rho=0, m=0, sigma=0.25,
/// rate=0, spot=forward=100, expiry=1_000_000, timestamp=0.
public fun create_std_oracle(ctx: &mut TxContext): (OracleSVI, Clock) {
    let svi = new_svi_params(0, 1_000_000_000, 0, false, 0, false, 250_000_000);
    let prices = new_price_data(100_000_000_000, 100_000_000_000);
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
    (oracle, clock)
}

/// Standard oracle with a registered cap, ready for guarded function calls.
/// Returns (oracle, cap, clock). Clock starts at 0.
public fun create_oracle_with_cap(ctx: &mut TxContext): (OracleSVI, OracleCapSVI, Clock) {
    let (mut oracle, clock) = create_std_oracle(ctx);
    let cap = oracle::create_oracle_cap(ctx);
    oracle::register_cap(&mut oracle, &cap);
    (oracle, cap, clock)
}

/// Oracle + cap where the cap is NOT registered (for unauthorized-cap abort tests).
public fun create_oracle_with_unregistered_cap(
    ctx: &mut TxContext,
): (OracleSVI, OracleCapSVI, Clock) {
    let (oracle, clock) = create_std_oracle(ctx);
    let cap = oracle::create_oracle_cap(ctx);
    (oracle, cap, clock)
}

/// Settled oracle for deterministic unit tests.
public fun create_settled_oracle(settlement_price: u64, ctx: &mut TxContext): OracleSVI {
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
    oracle::settle_test_oracle(&mut oracle, settlement_price);
    oracle
}
