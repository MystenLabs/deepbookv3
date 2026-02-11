// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// SupplyManager tracks LP shares and supply timestamps per address.
///
/// Share calculation uses DeepBook math (FLOAT_SCALING = 1e9):
/// - share_ratio = vault_value / total_shares (or FLOAT_SCALING if no shares)
/// - Supply: shares = amount / share_ratio
/// - Withdraw: amount = shares * share_ratio
///
/// Withdrawals are subject to a lockup period after the last supply.
module deepbook_predict::supply_manager;

use deepbook::math;
use sui::{clock::Clock, table::{Self, Table}};

// === Errors ===
const EInsufficientShares: u64 = 0;
const EZeroAmount: u64 = 1;
const ELockupNotElapsed: u64 = 2;

// === Structs ===

public struct SupplyData has copy, drop, store {
    shares: u64,
    last_supply_ms: u64,
}

public struct SupplyManager has store {
    supplies: Table<address, SupplyData>,
    total_shares: u64,
}

// === Public Functions ===

/// Returns (shares, last_supply_ms) for an owner.
public fun supply_data(self: &SupplyManager, owner: address): (u64, u64) {
    if (self.supplies.contains(owner)) {
        let data = self.supplies[owner];
        (data.shares, data.last_supply_ms)
    } else {
        (0, 0)
    }
}

public fun total_shares(self: &SupplyManager): u64 {
    self.total_shares
}

// === Public-Package Functions ===

public(package) fun new(ctx: &mut TxContext): SupplyManager {
    SupplyManager {
        supplies: table::new(ctx),
        total_shares: 0,
    }
}

/// Supply USDC to the vault, receive shares.
/// Returns the number of shares minted.
public(package) fun supply(
    self: &mut SupplyManager,
    amount: u64,
    vault_value: u64,
    clock: &Clock,
    ctx: &TxContext,
): u64 {
    assert!(amount > 0, EZeroAmount);

    let shares_to_mint = if (self.total_shares == 0) {
        amount
    } else {
        math::div(amount, self.share_ratio(vault_value))
    };

    // Update supply data
    let depositor = ctx.sender();
    self.add_supply_entry(depositor);

    let data = &mut self.supplies[depositor];
    data.shares = data.shares + shares_to_mint;
    data.last_supply_ms = clock.timestamp_ms();

    self.total_shares = self.total_shares + shares_to_mint;

    shares_to_mint
}

/// Withdraw USDC from the vault by burning shares.
/// Returns the amount to return.
/// Fails if lockup period has not elapsed since last supply.
public(package) fun withdraw(
    self: &mut SupplyManager,
    shares: u64,
    vault_value: u64,
    lockup_period_ms: u64,
    clock: &Clock,
    ctx: &TxContext,
): u64 {
    assert!(shares > 0, EZeroAmount);

    let depositor = ctx.sender();
    assert!(self.supplies.contains(depositor), EInsufficientShares);

    let ratio = self.share_ratio(vault_value);

    let data = &mut self.supplies[depositor];
    assert!(data.shares >= shares, EInsufficientShares);

    // Check lockup period
    let elapsed = clock.timestamp_ms() - data.last_supply_ms;
    assert!(elapsed >= lockup_period_ms, ELockupNotElapsed);

    let amount = math::mul(shares, ratio);

    // Update shares
    data.shares = data.shares - shares;
    self.total_shares = self.total_shares - shares;

    amount
}

// === Private Functions ===

fun share_ratio(self: &SupplyManager, vault_value: u64): u64 {
    math::div(vault_value, self.total_shares)
}

fun add_supply_entry(self: &mut SupplyManager, owner: address) {
    if (!self.supplies.contains(owner)) {
        self.supplies.add(owner, SupplyData { shares: 0, last_supply_ms: 0 });
    }
}
