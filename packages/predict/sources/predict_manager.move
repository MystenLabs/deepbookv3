// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// PredictManager wraps a BalanceManager for Predict trading.
///
/// Users deposit quote assets into the PredictManager, which stores them in the inner
/// BalanceManager. Positions are tracked as canonical ranges keyed by RangeKey.
module deepbook_predict::predict_manager;

use deepbook::balance_manager::{Self, BalanceManager, DepositCap, WithdrawCap};
use deepbook_predict::range_key::RangeKey;
use sui::{coin::Coin, derived_object, table::{Self, Table}};

const EInvalidOwner: u64 = 0;
const EInsufficientPosition: u64 = 1;

/// The key for deriving predict manager. u64 is optional for
/// supporting multiple managers per address. Defaults to 0 in v1.
public struct PredictManagerKey(address, u64) has copy, drop, store;

/// PredictManager wraps a BalanceManager and tracks positions.
public struct PredictManager has key {
    id: UID,
    owner: address,
    balance_manager: BalanceManager,
    deposit_cap: DepositCap,
    withdraw_cap: WithdrawCap,
    /// RangeKey -> position quantity
    positions: Table<RangeKey, u64>,
}

// === Public Functions ===

/// Share a newly created PredictManager object.
public fun share(self: PredictManager) {
    transfer::share_object(self);
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

/// Get the owner of the PredictManager.
public fun owner(self: &PredictManager): address {
    self.owner
}

/// Get the position quantity for a given RangeKey.
public fun position(self: &PredictManager, key: RangeKey): u64 {
    if (self.positions.contains(key)) {
        self.positions[key]
    } else {
        0
    }
}

/// Get the balance of a specific coin type in the PredictManager.
public fun balance<T>(self: &PredictManager): u64 {
    self.balance_manager.balance<T>()
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

/// Increase position quantity.
public(package) fun increase_position(self: &mut PredictManager, key: RangeKey, quantity: u64) {
    if (!self.positions.contains(key)) {
        self.positions.add(key, 0);
    };
    let qty = &mut self.positions[key];
    *qty = *qty + quantity;
}

/// Decrease position quantity.
public(package) fun decrease_position(self: &mut PredictManager, key: RangeKey, quantity: u64) {
    assert!(self.positions.contains(key), EInsufficientPosition);
    let qty = &mut self.positions[key];
    assert!(*qty >= quantity, EInsufficientPosition);
    *qty = *qty - quantity;
}
