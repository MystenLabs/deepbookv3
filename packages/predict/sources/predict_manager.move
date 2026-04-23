// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// PredictManager wraps a BalanceManager for binary options trading.
///
/// Users deposit USDC into the PredictManager, which is stored in the inner
/// BalanceManager. Long positions are tracked in `positions` keyed by
/// MarketKey, and vertical-range positions in `range_positions` keyed by
/// RangeKey.
module deepbook_predict::predict_manager;

use deepbook::balance_manager::{Self, BalanceManager, DepositCap, WithdrawCap};
use deepbook_predict::{market_key::MarketKey, range_key::RangeKey};
use sui::{coin::Coin, derived_object, table::{Self, Table}};

// === Errors ===
const EInvalidOwner: u64 = 0;
const EInsufficientPosition: u64 = 1;
const EInsufficientRangePosition: u64 = 2;

/// The key for deriving predict manager. u64 is optional for
/// supporting multiple managers per address. Defaults to 0 in v1.
public struct PredictManagerKey(address, u64) has copy, drop, store;

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
    /// RangeKey -> range position quantity
    range_positions: Table<RangeKey, u64>,
}

// === Public Functions ===
public fun share(self: PredictManager) {
    transfer::share_object(self);
}

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

/// Get the range position quantity for a given RangeKey.
public fun range_position(self: &PredictManager, key: RangeKey): u64 {
    if (self.range_positions.contains(key)) {
        self.range_positions[key]
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
public(package) fun new(registry_uid: &mut UID, ctx: &mut TxContext): PredictManager {
    let id = derived_object::claim(registry_uid, PredictManagerKey(ctx.sender(), 0));
    let owner = ctx.sender();

    let mut balance_manager = balance_manager::new(ctx);
    let deposit_cap = balance_manager.mint_deposit_cap(ctx);
    let withdraw_cap = balance_manager.mint_withdraw_cap(ctx);

    PredictManager {
        id,
        owner,
        balance_manager,
        deposit_cap,
        withdraw_cap,
        positions: table::new(ctx),
        range_positions: table::new(ctx),
    }
}

/// Deposit protocol payouts without requiring the manager owner as sender.
public(package) fun deposit_permissionless<T>(
    self: &mut PredictManager,
    coin: Coin<T>,
    ctx: &TxContext,
) {
    self.balance_manager.deposit_with_cap(&self.deposit_cap, coin, ctx);
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

/// Increase range position quantity. Called when user mints a range.
public(package) fun increase_range(self: &mut PredictManager, key: RangeKey, quantity: u64) {
    if (!self.range_positions.contains(key)) {
        self.range_positions.add(key, 0);
    };
    let qty = &mut self.range_positions[key];
    *qty = *qty + quantity;
}

/// Decrease range position quantity. Called when user redeems a range.
public(package) fun decrease_range(self: &mut PredictManager, key: RangeKey, quantity: u64) {
    assert!(self.range_positions.contains(key), EInsufficientRangePosition);
    let qty = &mut self.range_positions[key];
    assert!(*qty >= quantity, EInsufficientRangePosition);
    *qty = *qty - quantity;
}
