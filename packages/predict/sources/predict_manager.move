// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// PredictManager wraps a BalanceManager for binary options trading.
///
/// Users deposit USDC into the PredictManager, which is stored in the inner
/// BalanceManager. Long positions are tracked in `positions` keyed by
/// MarketKey, and vertical-spread positions in `spread_positions` keyed by
/// SpreadKey.
module deepbook_predict::predict_manager;

use deepbook::balance_manager::{Self, BalanceManager, DepositCap, WithdrawCap};
use deepbook_predict::{market_key::MarketKey, spread_key::SpreadKey};
use sui::{coin::Coin, event, table::{Self, Table}};

// === Errors ===
const EInvalidOwner: u64 = 0;
const EInsufficientPosition: u64 = 1;
const EInsufficientSpreadPosition: u64 = 2;

// === Events ===

public struct PredictManagerCreated has copy, drop, store {
    manager_id: ID,
    owner: address,
}

// === Structs ===

/// PredictManager wraps a BalanceManager and tracks positions.
public struct PredictManager has key {
    id: UID,
    owner: address,
    balance_manager: BalanceManager,
    deposit_cap: DepositCap,
    withdraw_cap: WithdrawCap,
    /// MarketKey -> long position quantity
    positions: Table<MarketKey, u64>,
    /// SpreadKey -> spread position quantity
    spread_positions: Table<SpreadKey, u64>,
}

// === Public Functions ===

/// Get the owner of the PredictManager.
public fun owner(self: &PredictManager): address {
    self.owner
}

/// Get the long position quantity for a given MarketKey.
public fun position(self: &PredictManager, key: MarketKey): u64 {
    if (self.positions.contains(key)) {
        self.positions[key]
    } else {
        0
    }
}

/// Get the spread position quantity for a given SpreadKey.
public fun spread_position(self: &PredictManager, key: SpreadKey): u64 {
    if (self.spread_positions.contains(key)) {
        self.spread_positions[key]
    } else {
        0
    }
}

/// Get the balance of a specific coin type in the PredictManager.
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

// === Public-Package Functions ===

/// Create a new PredictManager and share it.
public(package) fun new(ctx: &mut TxContext): ID {
    let id = object::new(ctx);
    let owner = ctx.sender();

    let mut balance_manager = balance_manager::new(ctx);
    let deposit_cap = balance_manager.mint_deposit_cap(ctx);
    let withdraw_cap = balance_manager.mint_withdraw_cap(ctx);

    let manager = PredictManager {
        id,
        owner,
        balance_manager,
        deposit_cap,
        withdraw_cap,
        positions: table::new(ctx),
        spread_positions: table::new(ctx),
    };
    let manager_id = object::id(&manager);
    transfer::share_object(manager);

    event::emit(PredictManagerCreated {
        manager_id,
        owner,
    });

    manager_id
}

/// Increase long position quantity. Called when user mints.
public(package) fun increase_position(self: &mut PredictManager, key: MarketKey, quantity: u64) {
    if (!self.positions.contains(key)) {
        self.positions.add(key, 0);
    };
    let qty = &mut self.positions[key];
    *qty = *qty + quantity;
}

/// Decrease long position quantity. Called when user redeems.
public(package) fun decrease_position(self: &mut PredictManager, key: MarketKey, quantity: u64) {
    assert!(self.positions.contains(key), EInsufficientPosition);
    let qty = &mut self.positions[key];
    assert!(*qty >= quantity, EInsufficientPosition);
    *qty = *qty - quantity;
}

/// Increase spread position quantity. Called when user mints a spread.
public(package) fun increase_spread(self: &mut PredictManager, key: SpreadKey, quantity: u64) {
    if (!self.spread_positions.contains(key)) {
        self.spread_positions.add(key, 0);
    };
    let qty = &mut self.spread_positions[key];
    *qty = *qty + quantity;
}

/// Decrease spread position quantity. Called when user redeems a spread.
public(package) fun decrease_spread(self: &mut PredictManager, key: SpreadKey, quantity: u64) {
    assert!(self.spread_positions.contains(key), EInsufficientSpreadPosition);
    let qty = &mut self.spread_positions[key];
    assert!(*qty >= quantity, EInsufficientSpreadPosition);
    *qty = *qty - quantity;
}
