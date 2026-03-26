// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Shared test helper for constructing oracles from generated scenario constants.
#[test_only]
module deepbook_predict::oracle_helper;

use deepbook_predict::{
    generated_oracle as go,
    generated_predict as gp,
    oracle::{Self, OracleSVI, new_price_data, new_svi_params}
};
use sui::clock::{Self, Clock};

/// Create a live oracle + clock from generated scenario params.
/// Takes raw u64 constants as emitted by generate.py (rho_neg/m_neg as 0 or 1).
public fun create_oracle(
    spot: u64,
    forward: u64,
    a: u64,
    b: u64,
    rho: u64,
    rho_neg: u64,
    m: u64,
    m_neg: u64,
    sigma: u64,
    rate: u64,
    expiry_ms: u64,
    now_ms: u64,
    ctx: &mut TxContext,
): (OracleSVI, Clock) {
    let svi = new_svi_params(a, b, rho, rho_neg == 1, m, m_neg == 1, sigma);
    let prices = new_price_data(spot, forward);
    let oracle = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi,
        prices,
        rate,
        expiry_ms,
        now_ms,
        ctx,
    );
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(now_ms);
    (oracle, clock)
}

/// Zero-SVI oracle for staleness/settlement tests.
/// Clock starts at 0; caller sets it if needed.
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
    let clock = clock::create_for_testing(ctx);
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

/// Settled oracle for unit tests. SVI params are zeroed (irrelevant for settled path).
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

// === Scenario oracle factories ===
// Each wraps create_oracle() with generated constants for a specific scenario.

public fun create_s0_oracle(ctx: &mut TxContext): (OracleSVI, Clock) {
    create_oracle(
        go::S0_SPOT!(),
        go::S0_FORWARD!(),
        go::S0_A!(),
        go::S0_B!(),
        go::S0_RHO!(),
        go::S0_RHO_NEG!(),
        go::S0_M!(),
        go::S0_M_NEG!(),
        go::S0_SIGMA!(),
        go::S0_RATE!(),
        go::S0_EXPIRY_MS!(),
        go::S0_NOW_MS!(),
        ctx,
    )
}

public fun create_s1_oracle(ctx: &mut TxContext): (OracleSVI, Clock) {
    create_oracle(
        go::S1_SPOT!(),
        go::S1_FORWARD!(),
        go::S1_A!(),
        go::S1_B!(),
        go::S1_RHO!(),
        go::S1_RHO_NEG!(),
        go::S1_M!(),
        go::S1_M_NEG!(),
        go::S1_SIGMA!(),
        go::S1_RATE!(),
        go::S1_EXPIRY_MS!(),
        go::S1_NOW_MS!(),
        ctx,
    )
}

public fun create_s2_oracle(ctx: &mut TxContext): (OracleSVI, Clock) {
    create_oracle(
        go::S2_SPOT!(),
        go::S2_FORWARD!(),
        go::S2_A!(),
        go::S2_B!(),
        go::S2_RHO!(),
        go::S2_RHO_NEG!(),
        go::S2_M!(),
        go::S2_M_NEG!(),
        go::S2_SIGMA!(),
        go::S2_RATE!(),
        go::S2_EXPIRY_MS!(),
        go::S2_NOW_MS!(),
        ctx,
    )
}

public fun create_s3_oracle(ctx: &mut TxContext): (OracleSVI, Clock) {
    create_oracle(
        go::S3_SPOT!(),
        go::S3_FORWARD!(),
        go::S3_A!(),
        go::S3_B!(),
        go::S3_RHO!(),
        go::S3_RHO_NEG!(),
        go::S3_M!(),
        go::S3_M_NEG!(),
        go::S3_SIGMA!(),
        go::S3_RATE!(),
        go::S3_EXPIRY_MS!(),
        go::S3_NOW_MS!(),
        ctx,
    )
}

public fun create_s4_oracle(ctx: &mut TxContext): (OracleSVI, Clock) {
    create_oracle(
        go::S4_SPOT!(),
        go::S4_FORWARD!(),
        go::S4_A!(),
        go::S4_B!(),
        go::S4_RHO!(),
        go::S4_RHO_NEG!(),
        go::S4_M!(),
        go::S4_M_NEG!(),
        go::S4_SIGMA!(),
        go::S4_RATE!(),
        go::S4_EXPIRY_MS!(),
        go::S4_NOW_MS!(),
        ctx,
    )
}

public fun create_s5_oracle(ctx: &mut TxContext): (OracleSVI, Clock) {
    create_oracle(
        go::S5_SPOT!(),
        go::S5_FORWARD!(),
        go::S5_A!(),
        go::S5_B!(),
        go::S5_RHO!(),
        go::S5_RHO_NEG!(),
        go::S5_M!(),
        go::S5_M_NEG!(),
        go::S5_SIGMA!(),
        go::S5_RATE!(),
        go::S5_EXPIRY_MS!(),
        go::S5_NOW_MS!(),
        ctx,
    )
}

public fun create_m0_oracle(ctx: &mut TxContext): (OracleSVI, Clock) {
    create_oracle(
        gp::M0_SPOT!(),
        gp::M0_FORWARD!(),
        gp::M0_A!(),
        gp::M0_B!(),
        gp::M0_RHO!(),
        gp::M0_RHO_NEG!(),
        gp::M0_M!(),
        gp::M0_M_NEG!(),
        gp::M0_SIGMA!(),
        gp::M0_RATE!(),
        gp::M0_EXPIRY_MS!(),
        gp::M0_NOW_MS!(),
        ctx,
    )
}

public fun create_m1_oracle(ctx: &mut TxContext): (OracleSVI, Clock) {
    create_oracle(
        gp::M1_SPOT!(),
        gp::M1_FORWARD!(),
        gp::M1_A!(),
        gp::M1_B!(),
        gp::M1_RHO!(),
        gp::M1_RHO_NEG!(),
        gp::M1_M!(),
        gp::M1_M_NEG!(),
        gp::M1_SIGMA!(),
        gp::M1_RATE!(),
        gp::M1_EXPIRY_MS!(),
        gp::M1_NOW_MS!(),
        ctx,
    )
}

public fun create_m2_oracle(ctx: &mut TxContext): (OracleSVI, Clock) {
    create_oracle(
        gp::M2_SPOT!(),
        gp::M2_FORWARD!(),
        gp::M2_A!(),
        gp::M2_B!(),
        gp::M2_RHO!(),
        gp::M2_RHO_NEG!(),
        gp::M2_M!(),
        gp::M2_M_NEG!(),
        gp::M2_SIGMA!(),
        gp::M2_RATE!(),
        gp::M2_EXPIRY_MS!(),
        gp::M2_NOW_MS!(),
        ctx,
    )
}

public fun create_m3_oracle(ctx: &mut TxContext): (OracleSVI, Clock) {
    create_oracle(
        gp::M3_SPOT!(),
        gp::M3_FORWARD!(),
        gp::M3_A!(),
        gp::M3_B!(),
        gp::M3_RHO!(),
        gp::M3_RHO_NEG!(),
        gp::M3_M!(),
        gp::M3_M_NEG!(),
        gp::M3_SIGMA!(),
        gp::M3_RATE!(),
        gp::M3_EXPIRY_MS!(),
        gp::M3_NOW_MS!(),
        ctx,
    )
}

public fun create_m4_oracle(ctx: &mut TxContext): (OracleSVI, Clock) {
    create_oracle(
        gp::M4_SPOT!(),
        gp::M4_FORWARD!(),
        gp::M4_A!(),
        gp::M4_B!(),
        gp::M4_RHO!(),
        gp::M4_RHO_NEG!(),
        gp::M4_M!(),
        gp::M4_M_NEG!(),
        gp::M4_SIGMA!(),
        gp::M4_RATE!(),
        gp::M4_EXPIRY_MS!(),
        gp::M4_NOW_MS!(),
        ctx,
    )
}
