// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// PredictManager stores DUSDC for Predict trading.
///
/// Users deposit DUSDC into the PredictManager. Positions are tracked as
/// canonical ranges keyed by RangeKey.
module deepbook_predict::predict_manager;

use deepbook_predict::range_key::RangeKey;
use dusdc::dusdc::DUSDC;
use sui::{balance::{Self, Balance}, coin::Coin, derived_object, table::{Self, Table}};

const EInvalidOwner: u64 = 0;
const EInsufficientPosition: u64 = 1;
const EInsufficientBalance: u64 = 2;

/// The key for deriving predict manager. u64 is optional for
/// supporting multiple managers per address. Defaults to 0 in v1.
public struct PredictManagerKey(address, u64) has copy, drop, store;

/// PredictManager stores DUSDC and tracks positions.
public struct PredictManager has key {
    id: UID,
    owner: address,
    balance: Balance<DUSDC>,
    /// RangeKey -> position quantity
    positions: Table<RangeKey, u64>,
}

// === Public Functions ===

/// Share a newly created PredictManager object.
public fun share(self: PredictManager) {
    transfer::share_object(self);
}

/// Deposit coins into the PredictManager.
public fun deposit(self: &mut PredictManager, coin: Coin<DUSDC>, ctx: &TxContext) {
    assert!(ctx.sender() == self.owner, EInvalidOwner);
    self.balance.join(coin.into_balance());
}

/// Withdraw coins from the PredictManager.
public fun withdraw(self: &mut PredictManager, amount: u64, ctx: &mut TxContext): Coin<DUSDC> {
    assert!(ctx.sender() == self.owner, EInvalidOwner);
    assert!(self.balance.value() >= amount, EInsufficientBalance);
    self.balance.split(amount).into_coin(ctx)
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

/// Get the DUSDC balance in the PredictManager.
public fun balance(self: &PredictManager): u64 {
    self.balance.value()
}

// === Public-Package Functions ===

/// Create a new PredictManager and share it.
public(package) fun new(registry_uid: &mut UID, ctx: &mut TxContext): PredictManager {
    let id = derived_object::claim(registry_uid, PredictManagerKey(ctx.sender(), 0));
    let owner = ctx.sender();

    PredictManager {
        id,
        owner,
        balance: balance::zero(),
        positions: table::new(ctx),
    }
}

/// Deposit protocol payouts without requiring the manager owner as sender.
public(package) fun deposit_permissionless(self: &mut PredictManager, coin: Coin<DUSDC>) {
    self.balance.join(coin.into_balance());
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
