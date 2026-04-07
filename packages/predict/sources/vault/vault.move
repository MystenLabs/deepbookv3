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
use deepbook_predict::{oracle_config::CurvePoint, strike_matrix::{Self, StrikeMatrix}};
use sui::{balance::{Self, Balance}, table::{Self, Table}};

// === Errors ===
const EInsufficientBalance: u64 = 0;
const EExceedsMaxTotalExposure: u64 = 1;
const EOracleExposureNotFound: u64 = 2;
const EMtmExceedsBalance: u64 = 3;

// === Structs ===

public struct Vault<phantom Quote> has store {
    /// USDC balance held by the vault
    balance: Balance<Quote>,
    /// Per-oracle matrix for strike-level position tracking
    oracle_matrices: Table<ID, StrikeMatrix>,
    /// Sum of all oracle matrix MTM values
    total_mtm: u64,
    /// Sum of all oracle matrix max payout values
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

/// Allocate one zeroed strike matrix for an oracle's configured strike grid.
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

/// Insert a position into the per-oracle exposure structure and update cached max payout.
public(package) fun insert_position<Quote>(
    vault: &mut Vault<Quote>,
    oracle_id: ID,
    is_up: bool,
    strike: u64,
    quantity: u64,
) {
    assert!(vault.oracle_matrices.contains(oracle_id), EOracleExposureNotFound);
    let old_max_payout = vault.oracle_matrices[oracle_id].max_payout();
    vault.oracle_matrices[oracle_id].insert(strike, quantity, is_up);
    let new_max_payout = vault.oracle_matrices[oracle_id].max_payout();
    vault.total_max_payout = vault.total_max_payout + new_max_payout - old_max_payout;
}

/// Accept payment into vault balance.
public(package) fun accept_payment<Quote>(vault: &mut Vault<Quote>, payment: Balance<Quote>) {
    vault.balance.join(payment);
}

/// Remove a position from the strike matrix.
public(package) fun remove_position<Quote>(
    vault: &mut Vault<Quote>,
    oracle_id: ID,
    is_up: bool,
    strike: u64,
    quantity: u64,
) {
    assert!(vault.oracle_matrices.contains(oracle_id), EOracleExposureNotFound);
    let old_max_payout = vault.oracle_matrices[oracle_id].max_payout();
    vault.oracle_matrices[oracle_id].remove(strike, quantity, is_up);
    let new_max_payout = vault.oracle_matrices[oracle_id].max_payout();
    vault.total_max_payout = vault.total_max_payout + new_max_payout - old_max_payout;
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

public(package) fun oracle_strike_range<Quote>(vault: &Vault<Quote>, oracle_id: ID): (u64, u64) {
    assert!(vault.oracle_matrices.contains(oracle_id), EOracleExposureNotFound);
    let matrix = &vault.oracle_matrices[oracle_id];
    if (!matrix.has_live_positions()) return (0, 0);
    matrix.minted_strike_range()
}

public(package) fun set_mtm_with_curve<Quote>(
    vault: &mut Vault<Quote>,
    oracle_id: ID,
    curve: &vector<CurvePoint>,
) {
    assert!(vault.oracle_matrices.contains(oracle_id), EOracleExposureNotFound);

    let old_mtm = vault.oracle_matrices[oracle_id].mtm();
    let new_mtm = vault.oracle_matrices[oracle_id].evaluate(curve);

    let matrix = &mut vault.oracle_matrices[oracle_id];
    matrix.set_mtm(new_mtm);
    vault.total_mtm = vault.total_mtm + new_mtm - old_mtm;
}

public(package) fun set_mtm_with_settlement<Quote>(
    vault: &mut Vault<Quote>,
    oracle_id: ID,
    settlement: u64,
) {
    assert!(vault.oracle_matrices.contains(oracle_id), EOracleExposureNotFound);

    let old_mtm = vault.oracle_matrices[oracle_id].mtm();
    let new_mtm = vault.oracle_matrices[oracle_id].evaluate_settled(settlement);

    let matrix = &mut vault.oracle_matrices[oracle_id];
    matrix.set_mtm(new_mtm);
    vault.total_mtm = vault.total_mtm + new_mtm - old_mtm;
}

public(package) fun set_mtm<Quote>(vault: &mut Vault<Quote>, oracle_id: ID, mtm: u64) {
    assert!(vault.oracle_matrices.contains(oracle_id), EOracleExposureNotFound);

    let old_mtm = vault.oracle_matrices[oracle_id].mtm();
    vault.oracle_matrices[oracle_id].set_mtm(mtm);
    vault.total_mtm = vault.total_mtm + mtm - old_mtm;
}
