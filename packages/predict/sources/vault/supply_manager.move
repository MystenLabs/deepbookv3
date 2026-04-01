// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Manages LP token minting and burning for the vault.
/// Share value is derived from vault_value = balance - total_mtm.
/// LP tokens (Coin<PLP>) are minted on supply and burned on withdraw.
module deepbook_predict::supply_manager;

use deepbook_predict::{math::mul_div_round_down, plp::PLP};
use sui::coin::{Self, Coin, TreasuryCap};

const EZeroAmount: u64 = 0;
const EZeroVaultValue: u64 = 1;
const EZeroSharesMinted: u64 = 2;

public struct SupplyManager has store {
    /// Treasury cap for minting/burning LP tokens
    treasury_cap: TreasuryCap<PLP>,
}

// === Public-Package Functions ===

public(package) fun total_shares(self: &SupplyManager): u64 {
    self.treasury_cap.total_supply()
}

/// Returns the USDC value of `shares` at the given vault value.
public(package) fun shares_to_amount(self: &SupplyManager, shares: u64, vault_value: u64): u64 {
    let total = self.treasury_cap.total_supply();
    if (shares == 0 || total == 0) return 0;
    if (total == shares) return vault_value;
    mul_div_round_down(shares, vault_value, total)
}

public(package) fun new(treasury_cap: TreasuryCap<PLP>): SupplyManager {
    SupplyManager { treasury_cap }
}

/// Deposit `amount` into the vault. Returns LP tokens representing shares.
/// First depositor gets shares 1:1. Subsequent depositors get shares
/// proportional to their deposit relative to current vault value.
public(package) fun supply(
    self: &mut SupplyManager,
    amount: u64,
    vault_value: u64,
    ctx: &mut TxContext,
): Coin<PLP> {
    assert!(amount > 0, EZeroAmount);

    let total = self.treasury_cap.total_supply();
    let shares = if (total == 0) {
        amount
    } else {
        assert!(vault_value > 0, EZeroVaultValue);
        mul_div_round_down(amount, total, vault_value)
    };
    assert!(shares > 0, EZeroSharesMinted);

    coin::mint(&mut self.treasury_cap, shares, ctx)
}

/// Withdraw by providing LP tokens. Burns the tokens and returns the
/// USDC amount to dispense. If the provided tokens represent all
/// outstanding shares, the full vault_value is returned (avoids rounding dust).
public(package) fun withdraw(self: &mut SupplyManager, token: Coin<PLP>, vault_value: u64): u64 {
    let shares = token.value();
    assert!(shares > 0, EZeroAmount);

    let amount = self.shares_to_amount(shares, vault_value);
    self.treasury_cap.burn(token);

    amount
}
