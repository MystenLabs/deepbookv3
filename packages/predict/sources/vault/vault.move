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
use sui::{balance::{Self, Balance}, coin::Coin};

// === Errors ===
const EInsufficientBalance: u64 = 1;
const EExceedsMaxTotalExposure: u64 = 2;

// === Structs ===

public struct Vault<phantom Quote> has store {
    /// USDC balance held by the vault
    balance: Balance<Quote>,
    /// Total UP contracts the vault is short
    total_up_short: u64,
    /// Total DOWN contracts the vault is short
    total_down_short: u64,
    /// Total collateralized contracts (not backed by vault)
    total_collateralized: u64,
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

public fun total_collateralized<Quote>(vault: &Vault<Quote>): u64 {
    vault.total_collateralized
}

// === Public-Package Functions ===

public(package) fun new<Quote>(): Vault<Quote> {
    Vault {
        balance: balance::zero(),
        total_up_short: 0,
        total_down_short: 0,
        total_collateralized: 0,
    }
}

/// Execute a mint trade. Updates aggregate exposure.
/// Cost calculation is done by the orchestrator.
public(package) fun execute_mint<Quote>(
    vault: &mut Vault<Quote>,
    is_up: bool,
    quantity: u64,
    payment: Coin<Quote>,
) {
    vault.balance.join(payment.into_balance());
    if (is_up) {
        vault.total_up_short = vault.total_up_short + quantity;
    } else {
        vault.total_down_short = vault.total_down_short + quantity;
    };
}

/// Execute a redeem trade. Updates aggregate exposure.
/// Payout calculation is done by the orchestrator.
public(package) fun execute_redeem<Quote>(
    vault: &mut Vault<Quote>,
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
    vault.balance.split(payout)
}

/// Execute a collateralized mint. Only updates total_collateralized.
/// Does not affect vault risk since position is backed by collateral.
public(package) fun execute_mint_collateralized<Quote>(vault: &mut Vault<Quote>, quantity: u64) {
    vault.total_collateralized = vault.total_collateralized + quantity;
}

/// Execute a collateralized redeem. Only updates total_collateralized.
/// Does not affect vault risk since position was backed by collateral.
public(package) fun execute_redeem_collateralized<Quote>(vault: &mut Vault<Quote>, quantity: u64) {
    vault.total_collateralized = vault.total_collateralized - quantity;
}

/// Assert that total vault exposure is within risk limits.
public(package) fun assert_total_exposure<Quote>(vault: &Vault<Quote>, max_total_pct: u64) {
    let balance = vault.balance.value();
    assert!(vault.max_liability() <= math::mul(balance, max_total_pct), EExceedsMaxTotalExposure);
}

/// Admin deposits USDC into the vault.
public(package) fun deposit<Quote>(vault: &mut Vault<Quote>, coin: Coin<Quote>) {
    vault.balance.join(coin.into_balance());
}

/// Admin withdraws USDC from the vault.
public(package) fun withdraw<Quote>(vault: &mut Vault<Quote>, amount: u64): Balance<Quote> {
    vault.balance.split(amount)
}
