// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Vault module - counterparty for all trades.
///
/// The vault holds USDC and takes the opposite side of every trade:
/// - When user mints UP position, vault receives USDC and is short UP
/// - When user mints DOWN position, vault receives USDC and is short DOWN
/// - When user redeems, vault pays out and closes its short
///
/// Position tracking:
/// - `positions` maps PositionCoin ID to vault's short quantity
/// - Net exposure is calculated by comparing UP vs DOWN shorts at the same strike
///
/// Invariant: balance >= max_liability (max of UP shorts vs DOWN shorts per strike * $1)
module deepbook_predict::vault;

use deepbook_predict::market_manager::PositionCoin;
use sui::{balance::{Self, Balance}, coin::Coin, table::{Self, Table}};

// === Errors ===
const ENoShortPosition: u64 = 0;

// === Structs ===

/// Vault holding USDC and tracking short positions.
/// Quote is the collateral asset (e.g., USDC).
public struct Vault<phantom Quote> has store {
    /// USDC balance held by the vault
    balance: Balance<Quote>,
    /// PositionCoin ID -> quantity short
    positions: Table<ID, u64>,
}

// === Public Functions ===

/// Get the vault's USDC balance.
public fun balance<Quote>(vault: &Vault<Quote>): u64 {
    vault.balance.value()
}

/// Get the vault's short position for a specific market.
/// Returns 0 if no position exists.
public fun position<Quote, PQuote>(vault: &Vault<Quote>, position_coin: &PositionCoin<PQuote>): u64 {
    let position_coin_id = position_coin.id();
    if (vault.positions.contains(position_coin_id)) {
        vault.positions[position_coin_id]
    } else {
        0
    }
}

// === Public-Package Functions ===

/// Create a new empty vault.
public(package) fun new<Quote>(ctx: &mut TxContext): Vault<Quote> {
    Vault {
        balance: balance::zero(),
        positions: table::new(ctx),
    }
}

/// Mint: user pays USDC, vault goes short on the position.
/// Returns the cost paid by the user.
public(package) fun increase_exposure<Quote>(
    vault: &mut Vault<Quote>,
    position: &PositionCoin<Quote>,
    quantity: u64,
    payment: Coin<Quote>,
): u64 {
    let cost = payment.value();
    vault.balance.join(payment.into_balance());
    let position_id = position.id();

    // Record short position
    if (vault.positions.contains(position_id)) {
        let current = &mut vault.positions[position_id];
        *current = *current + quantity;
    } else {
        vault.positions.add(position_id, quantity);
    };

    cost
}

/// Redeem: user returns position, vault pays out and reduces short.
/// Returns the payout as Balance.
public(package) fun decrease_exposure<Quote>(
    vault: &mut Vault<Quote>,
    position: &PositionCoin<Quote>,
    quantity: u64,
    quote_out: u64,
): Balance<Quote> {
    // Reduce short position
    let position_id = position.id();
    assert!(vault.positions.contains(position_id), ENoShortPosition);
    let current = &mut vault.positions[position_id];
    *current = *current - quantity;

    // Pay out
    vault.balance.split(quote_out)
}
