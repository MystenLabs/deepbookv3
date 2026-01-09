// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// PredictManager wraps a BalanceManager for binary options trading.
///
/// Users deposit USDC into the PredictManager, which is stored in the inner BalanceManager.
/// Positions are tracked in a Table mapping PositionKey to quantity.
module deepbook_predict::predict_manager;

use deepbook::balance_manager::{Self, BalanceManager, TradeCap, DepositCap, WithdrawCap};
use sui::{coin::Coin, table::{Self, Table}};

// === Constants ===
const DIRECTION_UP: u8 = 0;
const DIRECTION_DOWN: u8 = 1;

// === Errors ===
const EInvalidOwner: u64 = 0;
const EInsufficientPosition: u64 = 1;

// === Structs ===

/// Key for a position: (oracle_id, expiry, strike, direction)
public struct PositionKey(ID, u64, u64, u8) has copy, drop, store;

/// PredictManager wraps a BalanceManager and tracks positions.
public struct PredictManager has key {
    id: UID,
    owner: address,
    balance_manager: BalanceManager,
    deposit_cap: DepositCap,
    withdraw_cap: WithdrawCap,
    trade_cap: TradeCap,
    /// PositionKey -> quantity
    positions: Table<PositionKey, u64>,
}

// === Public Functions ===

/// Get the owner of the PredictManager.
public fun owner(self: &PredictManager): address {
    self.owner
}

/// Get the ID of the PredictManager.
public fun id(self: &PredictManager): ID {
    self.id.to_inner()
}

/// Get the position quantity for a given key.
/// Returns 0 if no position exists.
public fun position(self: &PredictManager, key: PositionKey): u64 {
    if (self.positions.contains(key)) {
        self.positions[key]
    } else {
        0
    }
}

/// Get balance of a specific asset in the PredictManager.
public fun balance<T>(self: &PredictManager): u64 {
    self.balance_manager.balance<T>()
}

/// Deposit coins into the PredictManager.
public fun deposit<T>(self: &mut PredictManager, coin: Coin<T>, ctx: &TxContext) {
    assert!(ctx.sender() == self.owner, EInvalidOwner);
    self.balance_manager.deposit_with_cap(&self.deposit_cap, coin, ctx);
}

/// Withdraw coins from the PredictManager.
public fun withdraw<T>(self: &mut PredictManager, amount: u64, ctx: &mut TxContext): Coin<T> {
    assert!(ctx.sender() == self.owner, EInvalidOwner);
    self.balance_manager.withdraw_with_cap(&self.withdraw_cap, amount, ctx)
}

// === PositionKey Functions ===

/// Create a new PositionKey for an UP position.
public fun position_key_up(oracle_id: ID, expiry: u64, strike: u64): PositionKey {
    PositionKey(oracle_id, expiry, strike, DIRECTION_UP)
}

/// Create a new PositionKey for a DOWN position.
public fun position_key_down(oracle_id: ID, expiry: u64, strike: u64): PositionKey {
    PositionKey(oracle_id, expiry, strike, DIRECTION_DOWN)
}

/// Get the oracle_id from a PositionKey.
public fun key_oracle_id(key: &PositionKey): ID {
    key.0
}

/// Get the expiry from a PositionKey.
public fun key_expiry(key: &PositionKey): u64 {
    key.1
}

/// Get the strike from a PositionKey.
public fun key_strike(key: &PositionKey): u64 {
    key.2
}

/// Get the direction from a PositionKey.
public fun key_direction(key: &PositionKey): u8 {
    key.3
}

/// Check if a PositionKey is for an UP position.
public fun key_is_up(key: &PositionKey): bool {
    key.3 == DIRECTION_UP
}

// === Public-Package Functions ===

/// Create a new PredictManager and share it.
public(package) fun new(ctx: &mut TxContext): ID {
    let manager = new_predict_manager(ctx);
    let manager_id = manager.id();
    transfer::share_object(manager);

    manager_id
}

/// Increase a position quantity. Called when user buys a position.
public(package) fun increase_position(self: &mut PredictManager, key: PositionKey, quantity: u64) {
    if (self.positions.contains(key)) {
        let current = &mut self.positions[key];
        *current = *current + quantity;
    } else {
        self.positions.add(key, quantity);
    }
}

/// Decrease a position quantity. Called when user sells a position.
public(package) fun decrease_position(self: &mut PredictManager, key: PositionKey, quantity: u64) {
    assert!(self.positions.contains(key), EInsufficientPosition);
    let current = &mut self.positions[key];
    assert!(*current >= quantity, EInsufficientPosition);
    *current = *current - quantity;
}

// === Private Functions ===

fun new_predict_manager(ctx: &mut TxContext): PredictManager {
    let id = object::new(ctx);
    let owner = ctx.sender();

    let mut balance_manager = balance_manager::new(ctx);
    let deposit_cap = balance_manager.mint_deposit_cap(ctx);
    let withdraw_cap = balance_manager.mint_withdraw_cap(ctx);
    let trade_cap = balance_manager.mint_trade_cap(ctx);

    PredictManager {
        id,
        owner,
        balance_manager,
        deposit_cap,
        withdraw_cap,
        trade_cap,
        positions: table::new(ctx),
    }
}
