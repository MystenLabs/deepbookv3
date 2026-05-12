// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// PredictManager wraps a BalanceManager for Predict trading.
///
/// Users deposit DUSDC into the PredictManager. DUSDC custody is delegated to
/// BalanceManager, while positions are tracked as canonical ranges keyed by
/// RangeKey.
module deepbook_predict::predict_manager;

use deepbook::balance_manager::{Self, BalanceManager, DepositCap};
use deepbook_predict::range_key::RangeKey;
use dusdc::dusdc::DUSDC;
use sui::{coin::Coin, derived_object, table::{Self, Table}};

const EInsufficientPosition: u64 = 0;

/// The key for deriving predict manager. u64 is optional for
/// supporting multiple managers per address. Defaults to 0 in v1.
public struct PredictManagerKey(address, u64) has copy, drop, store;

/// PredictManager stores DUSDC in a BalanceManager and tracks positions.
public struct PredictManager has key {
    id: UID,
    balance_manager: BalanceManager,
    deposit_cap: DepositCap,
    /// RangeKey -> position quantity
    positions: Table<RangeKey, u64>,
}

// === Public Functions ===

/// Share a newly created PredictManager object.
public fun share(self: PredictManager) {
    transfer::share_object(self);
}

/// Deposit coins into the PredictManager.
public fun deposit(self: &mut PredictManager, coin: Coin<DUSDC>, ctx: &mut TxContext) {
    self.balance_manager.deposit(coin, ctx);
}

/// Withdraw coins from the PredictManager.
public fun withdraw(self: &mut PredictManager, amount: u64, ctx: &mut TxContext): Coin<DUSDC> {
    self.balance_manager.withdraw(amount, ctx)
}

/// Get the owner of the PredictManager.
public fun owner(self: &PredictManager): address {
    self.balance_manager.owner()
}

/// Get the position quantity for a given RangeKey.
public fun position(self: &PredictManager, key: RangeKey): u64 {
    if (self.positions.contains(key)) {
        self.positions[key]
    } else {
        0
    }
}

/// Get the DUSDC balance in the PredictManager.
public fun balance(self: &PredictManager): u64 {
    self.balance_manager.balance<DUSDC>()
}

// === Public-Package Functions ===

/// Create a new PredictManager and share it.
public(package) fun new(registry_uid: &mut UID, ctx: &mut TxContext): PredictManager {
    let id = derived_object::claim(registry_uid, PredictManagerKey(ctx.sender(), 0));
    let mut balance_manager = balance_manager::new(ctx);
    let deposit_cap = balance_manager.mint_deposit_cap(ctx);

    PredictManager {
        id,
        balance_manager,
        deposit_cap,
        positions: table::new(ctx),
    }
}

/// Deposit protocol payouts without requiring the manager owner as sender.
public(package) fun deposit_permissionless(
    self: &mut PredictManager,
    coin: Coin<DUSDC>,
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
