// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Tracks per-user supply shares for the vault.
/// Share value is derived from vault_value = balance - total_mtm.
module deepbook_predict::supply_manager;

use deepbook_predict::math::{mul_div_round_down, mul_div_round_up};
use sui::table::{Self, Table};

const EZeroAmount: u64 = 0;
const EInsufficientShares: u64 = 1;
const EZeroVaultValue: u64 = 2;
const EZeroSharesMinted: u64 = 3;
const EZeroSharesBurned: u64 = 4;

public struct SupplyManager has store {
    /// Total shares outstanding across all suppliers
    total_shares: u64,
    /// User address → share balance
    user_shares: Table<address, u64>,
}

// === Public-Package Functions ===

public(package) fun total_shares(self: &SupplyManager): u64 {
    self.total_shares
}

public(package) fun user_shares(self: &SupplyManager, sender: address): u64 {
    if (self.user_shares.contains(sender)) self.user_shares[sender] else 0
}

/// Returns the USDC value of a user's shares at current vault value.
public(package) fun user_supply_amount(
    self: &SupplyManager,
    vault_value: u64,
    sender: address,
): u64 {
    let shares = self.user_shares(sender);
    if (shares == 0 || self.total_shares == 0) return 0;
    mul_div_round_down(shares, vault_value, self.total_shares)
}

public(package) fun new(ctx: &mut TxContext): SupplyManager {
    SupplyManager {
        total_shares: 0,
        user_shares: table::new(ctx),
    }
}

/// Deposit `amount` into the vault. Returns the number of shares minted.
/// First depositor gets shares 1:1. Subsequent depositors get shares
/// proportional to their deposit relative to current vault value.
public(package) fun supply(
    self: &mut SupplyManager,
    amount: u64,
    vault_value: u64,
    sender: address,
): u64 {
    assert!(amount > 0, EZeroAmount);

    let shares = if (self.total_shares == 0) {
        amount
    } else {
        assert!(vault_value > 0, EZeroVaultValue);
        mul_div_round_down(amount, self.total_shares, vault_value)
    };
    assert!(shares > 0, EZeroSharesMinted);

    self.total_shares = self.total_shares + shares;

    if (self.user_shares.contains(sender)) {
        let user = &mut self.user_shares[sender];
        *user = *user + shares;
    } else {
        self.user_shares.add(sender, shares);
    };

    shares
}

/// Withdraw `amount` of USDC. Converts to shares and burns them.
/// Returns the number of shares burned.
/// Note: fixed-point truncation may round shares up relative to the amount,
/// so withdrawing an exact deposited amount can fail with EInsufficientShares.
/// Use `withdraw_all()` to fully exit a position without rounding issues.
public(package) fun withdraw(
    self: &mut SupplyManager,
    amount: u64,
    vault_value: u64,
    sender: address,
): u64 {
    assert!(amount > 0, EZeroAmount);
    assert!(vault_value > 0, EZeroVaultValue);

    let shares = mul_div_round_up(amount, self.total_shares, vault_value);
    assert!(shares > 0, EZeroSharesBurned);
    let user = &mut self.user_shares[sender];
    assert!(*user >= shares, EInsufficientShares);

    *user = *user - shares;
    self.total_shares = self.total_shares - shares;
    if (*user == 0) { self.user_shares.remove(sender); };

    shares
}

/// Withdraw all shares for `sender`. Returns (USDC amount, shares burned).
public(package) fun withdraw_all(
    self: &mut SupplyManager,
    vault_value: u64,
    sender: address,
): (u64, u64) {
    let shares = self.user_shares(sender);
    assert!(shares > 0, EZeroAmount);

    let amount = if (self.total_shares == shares) {
        vault_value
    } else {
        assert!(vault_value > 0, EZeroVaultValue);
        mul_div_round_down(shares, vault_value, self.total_shares)
    };

    self.user_shares.remove(sender);
    self.total_shares = self.total_shares - shares;

    (amount, shares)
}
