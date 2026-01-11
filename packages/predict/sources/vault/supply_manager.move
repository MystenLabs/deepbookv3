// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// SupplyManager tracks LP shares per address.
///
/// Share calculation uses DeepBook math (FLOAT_SCALING = 1e9):
/// - vault_value = balance - unrealized_liability
/// - share_ratio = vault_value / total_shares (or FLOAT_SCALING if no shares)
/// - Supply: shares = amount / share_ratio
/// - Withdraw: amount = shares * share_ratio
module deepbook_predict::supply_manager;

use deepbook::math;
use sui::table::{Self, Table};

// === Errors ===
const EInsufficientShares: u64 = 0;
const EZeroAmount: u64 = 1;

// === Structs ===

public struct SupplyManager has store {
    shares: Table<address, u64>,
    total_shares: u64,
}

// === Public Functions ===

public fun shares(self: &SupplyManager, owner: address): u64 {
    if (self.shares.contains(owner)) {
        self.shares[owner]
    } else {
        0
    }
}

public fun total_shares(self: &SupplyManager): u64 {
    self.total_shares
}

// === Public-Package Functions ===

public(package) fun new(ctx: &mut TxContext): SupplyManager {
    SupplyManager {
        shares: table::new(ctx),
        total_shares: 0,
    }
}

/// Supply USDC to the vault, receive shares.
/// Returns the number of shares minted.
public(package) fun supply(
    self: &mut SupplyManager,
    amount: u64,
    balance: u64,
    unrealized_liability: u64,
    ctx: &TxContext,
): u64 {
    assert!(amount > 0, EZeroAmount);

    let shares_to_mint = if (self.total_shares == 0) {
        // First deposit: 1:1 ratio
        amount
    } else {
        // vault_value = balance - unrealized_liability (before deposit)
        let vault_value = balance - unrealized_liability;
        // share_ratio = vault_value / total_shares
        let share_ratio = math::div(vault_value, self.total_shares);
        // shares = amount / share_ratio
        math::div(amount, share_ratio)
    };

    // Update shares
    let depositor = ctx.sender();
    if (self.shares.contains(depositor)) {
        let current = &mut self.shares[depositor];
        *current = *current + shares_to_mint;
    } else {
        self.shares.add(depositor, shares_to_mint);
    };
    self.total_shares = self.total_shares + shares_to_mint;

    shares_to_mint
}

/// Withdraw USDC from the vault by burning shares.
/// Returns the amount to return.
public(package) fun withdraw(
    self: &mut SupplyManager,
    shares: u64,
    balance: u64,
    unrealized_liability: u64,
    ctx: &TxContext,
): u64 {
    assert!(shares > 0, EZeroAmount);

    let depositor = ctx.sender();
    assert!(self.shares.contains(depositor), EInsufficientShares);

    let current_shares = &mut self.shares[depositor];
    assert!(*current_shares >= shares, EInsufficientShares);

    // vault_value = balance - unrealized_liability
    let vault_value = balance - unrealized_liability;
    // share_ratio = vault_value / total_shares
    let share_ratio = math::div(vault_value, self.total_shares);
    // amount = shares * share_ratio
    let amount = math::mul(shares, share_ratio);

    // Update shares
    *current_shares = *current_shares - shares;
    self.total_shares = self.total_shares - shares;

    amount
}
