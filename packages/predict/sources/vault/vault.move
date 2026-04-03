// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Vault module - pure state machine for trade execution.
///
/// The vault holds USDC and takes the opposite side of every trade.
/// All pricing logic is handled by the orchestrator (predict.move).
///
/// Tracks mark-to-market liability via per-oracle strike matrices and a cached
/// global total_mtm, refreshed on every trade.
///
/// Scaling conventions (aligned with DeepBook):
/// - Quantities are in Quote units (USDC): 1_000_000 = 1 contract = $1 at settlement
module deepbook_predict::vault;

use deepbook::math;
use deepbook_predict::{oracle::OracleSVI, strike_matrix::{Self, StrikeMatrix}};
use sui::{balance::{Self, Balance}, clock::Clock, table::{Self, Table}};

// === Errors ===
const EInsufficientBalance: u64 = 1;
const EExceedsMaxTotalExposure: u64 = 2;
const EOracleExposureNotFound: u64 = 3;
const EMtmExceedsBalance: u64 = 4;

// === Structs ===

public struct Vault<phantom Quote> has store {
    /// USDC balance held by the vault
    balance: Balance<Quote>,
    /// Per-oracle strike matrix for strike-level position tracking
    oracle_matrices: Table<ID, StrikeMatrix>,
    /// Sum of all oracle strike matrix MTM values
    total_mtm: u64,
    /// Sum of all oracle strike matrix max payout values
    total_max_payout: u64,
}

// === Public Functions ===

public fun balance<Quote>(vault: &Vault<Quote>): u64 {
    vault.balance.value()
}

public fun total_mtm<Quote>(vault: &Vault<Quote>): u64 {
    vault.total_mtm
}

public fun vault_value<Quote>(vault: &Vault<Quote>): u64 {
    assert!(vault.balance.value() >= vault.total_mtm, EMtmExceedsBalance);
    vault.balance.value() - vault.total_mtm
}

public fun total_max_payout<Quote>(vault: &Vault<Quote>): u64 {
    vault.total_max_payout
}

// === Public-Package Functions ===

public(package) fun new<Quote>(ctx: &mut TxContext): Vault<Quote> {
    Vault {
        balance: balance::zero(),
        oracle_matrices: table::new(ctx),
        total_mtm: 0,
        total_max_payout: 0,
    }
}

public(package) fun init_oracle_matrix<Quote>(
    vault: &mut Vault<Quote>,
    oracle_id: ID,
    min_strike: u64,
    max_strike: u64,
    tick_size: u64,
    ctx: &mut TxContext,
) {
    if (!vault.oracle_matrices.contains(oracle_id)) {
        vault
            .oracle_matrices
            .add(
                oracle_id,
                strike_matrix::new(ctx, tick_size, min_strike, max_strike),
            );
    };
}

#[test_only]
public(package) fun insert_test_position<Quote>(
    vault: &mut Vault<Quote>,
    oracle: &OracleSVI,
    is_up: bool,
    strike: u64,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    vault.init_oracle_matrix(
        oracle.id(),
        oracle.min_strike(),
        oracle.max_strike(),
        oracle.tick_size(),
        ctx,
    );
    vault.insert_position(oracle, is_up, strike, quantity, clock);
}

/// Insert a position into the matrix and refresh risk metrics.
public(package) fun insert_position<Quote>(
    vault: &mut Vault<Quote>,
    oracle: &OracleSVI,
    is_up: bool,
    strike: u64,
    quantity: u64,
    clock: &Clock,
) {
    let oracle_id = oracle.id();
    let old_max_payout = vault.oracle_matrices[oracle_id].max_payout();
    vault.oracle_matrices[oracle_id].insert(strike, quantity, is_up);
    let new_max_payout = vault.oracle_matrices[oracle_id].max_payout();
    vault.total_max_payout = vault.total_max_payout + new_max_payout - old_max_payout;
    vault.refresh_oracle_risk(oracle, clock);
}

/// Accept payment into vault balance.
public(package) fun accept_payment<Quote>(vault: &mut Vault<Quote>, payment: Balance<Quote>) {
    vault.balance.join(payment);
}

/// Remove a position from the matrix and refresh risk metrics.
public(package) fun remove_position<Quote>(
    vault: &mut Vault<Quote>,
    oracle: &OracleSVI,
    is_up: bool,
    strike: u64,
    quantity: u64,
    clock: &Clock,
) {
    let oracle_id = oracle.id();
    assert!(vault.oracle_matrices.contains(oracle_id), EOracleExposureNotFound);
    let old_max_payout = vault.oracle_matrices[oracle_id].max_payout();
    vault.oracle_matrices[oracle_id].remove(strike, quantity, is_up);
    let new_max_payout = vault.oracle_matrices[oracle_id].max_payout();
    vault.total_max_payout = vault.total_max_payout + new_max_payout - old_max_payout;
    vault.refresh_oracle_risk(oracle, clock);
}

/// Dispense payout from vault balance.
public(package) fun dispense_payout<Quote>(vault: &mut Vault<Quote>, amount: u64): Balance<Quote> {
    assert!(vault.balance.value() >= amount, EInsufficientBalance);
    vault.balance.split(amount)
}

/// Assert that total vault exposure is within risk limits.
public(package) fun assert_total_exposure<Quote>(vault: &Vault<Quote>, max_total_pct: u64) {
    let balance = vault.balance.value();
    assert!(vault.total_mtm <= math::mul(balance, max_total_pct), EExceedsMaxTotalExposure);
}

/// Refresh cached MTM for one oracle.
fun refresh_oracle_risk<Quote>(vault: &mut Vault<Quote>, oracle: &OracleSVI, clock: &Clock) {
    let oracle_id = oracle.id();
    let matrix = &vault.oracle_matrices[oracle_id];
    if (!matrix.has_live_positions()) {
        let old_mtm = matrix.mtm();
        let matrix = &mut vault.oracle_matrices[oracle_id];
        matrix.set_mtm(0);
        vault.total_mtm = vault.total_mtm - old_mtm;
        return
    };
    let old_mtm = matrix.mtm();
    let new_mtm = if (oracle.is_settled()) {
        matrix.evaluate_settled(oracle.settlement_price().destroy_some())
    } else {
        let (min_strike, max_strike) = matrix.minted_strike_range();
        let curve = oracle.build_curve(min_strike, max_strike, clock);
        matrix.evaluate(&curve)
    };
    let matrix = &mut vault.oracle_matrices[oracle_id];
    matrix.set_mtm(new_mtm);
    vault.total_mtm = vault.total_mtm + new_mtm - old_mtm;
}
