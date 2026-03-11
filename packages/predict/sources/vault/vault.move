// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Vault module - pure state machine for trade execution.
///
/// The vault holds USDC and takes the opposite side of every trade.
/// All pricing logic is handled by the orchestrator (predict.move).
///
/// Tracks aggregate short exposure (total_up_short, total_down_short)
/// instead of per-market positions.
///
/// Scaling conventions (aligned with DeepBook):
/// - Quantities are in Quote units (USDC): 1_000_000 = 1 contract = $1 at settlement
/// - All liabilities (max_liability) are in Quote units
module deepbook_predict::vault;

use deepbook::math;
use sui::{balance::{Self, Balance}, table::{Self, Table}};

// === Errors ===
const EInsufficientBalance: u64 = 1;
const EExceedsMaxTotalExposure: u64 = 2;

// === Structs ===

public struct OracleExposure has copy, drop, store {
    up_short: u64,
    down_short: u64,
}

public struct Vault<phantom Quote> has store {
    /// USDC balance held by the vault
    balance: Balance<Quote>,
    /// Total UP contracts the vault is short
    total_up_short: u64,
    /// Total DOWN contracts the vault is short
    total_down_short: u64,
    /// Per-oracle exposure tracking for skew calculation
    oracle_exposure: Table<ID, OracleExposure>,
}

// === Public Functions ===

public fun balance<Quote>(vault: &Vault<Quote>): u64 {
    vault.balance.value()
}

public fun max_liability<Quote>(vault: &Vault<Quote>): u64 {
    vault.total_up_short + vault.total_down_short
}

public fun total_up_short<Quote>(vault: &Vault<Quote>): u64 {
    vault.total_up_short
}

public fun total_down_short<Quote>(vault: &Vault<Quote>): u64 {
    vault.total_down_short
}

public fun oracle_exposure<Quote>(vault: &Vault<Quote>, oracle_id: ID): (u64, u64) {
    if (!vault.oracle_exposure.contains(oracle_id)) return (0, 0);
    let exp = &vault.oracle_exposure[oracle_id];
    (exp.up_short, exp.down_short)
}

// === Public-Package Functions ===

public(package) fun new<Quote>(ctx: &mut TxContext): Vault<Quote> {
    Vault {
        balance: balance::zero(),
        total_up_short: 0,
        total_down_short: 0,
        oracle_exposure: table::new(ctx),
    }
}

/// Execute a mint trade. Updates aggregate exposure.
/// Cost calculation is done by the orchestrator.
public(package) fun execute_mint<Quote>(
    vault: &mut Vault<Quote>,
    oracle_id: ID,
    is_up: bool,
    quantity: u64,
    payment: Balance<Quote>,
) {
    vault.balance.join(payment);
    if (is_up) {
        vault.total_up_short = vault.total_up_short + quantity;
    } else {
        vault.total_down_short = vault.total_down_short + quantity;
    };

    if (!vault.oracle_exposure.contains(oracle_id)) {
        vault.oracle_exposure.add(oracle_id, OracleExposure { up_short: 0, down_short: 0 });
    };
    let exp = &mut vault.oracle_exposure[oracle_id];
    if (is_up) { exp.up_short = exp.up_short + quantity } else {
        exp.down_short = exp.down_short + quantity
    };
}

/// Execute a redeem trade. Updates aggregate exposure.
/// Payout calculation is done by the orchestrator.
public(package) fun execute_redeem<Quote>(
    vault: &mut Vault<Quote>,
    oracle_id: ID,
    is_up: bool,
    quantity: u64,
    payout: u64,
): Balance<Quote> {
    assert!(vault.balance.value() >= payout, EInsufficientBalance);
    if (is_up) {
        vault.total_up_short = vault.total_up_short - quantity;
    } else {
        vault.total_down_short = vault.total_down_short - quantity;
    };

    let exp = &mut vault.oracle_exposure[oracle_id];
    if (is_up) { exp.up_short = exp.up_short - quantity } else {
        exp.down_short = exp.down_short - quantity
    };

    vault.balance.split(payout)
}

/// Assert that total vault exposure is within risk limits.
public(package) fun assert_total_exposure<Quote>(vault: &Vault<Quote>, max_total_pct: u64) {
    let balance = vault.balance.value();
    assert!(vault.max_liability() <= math::mul(balance, max_total_pct), EExceedsMaxTotalExposure);
}

/// Admin deposits USDC into the vault.
public(package) fun deposit<Quote>(vault: &mut Vault<Quote>, deposit: Balance<Quote>) {
    vault.balance.join(deposit);
}

/// Admin withdraws USDC from the vault.
public(package) fun withdraw<Quote>(vault: &mut Vault<Quote>, amount: u64): Balance<Quote> {
    vault.balance.split(amount)
}
