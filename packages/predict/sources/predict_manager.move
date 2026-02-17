// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// PredictManager wraps a BalanceManager for binary options trading.
///
/// Users deposit USDC into the PredictManager, which is stored in the inner BalanceManager.
/// Positions are tracked in a Table mapping MarketKey to UserPosition (free, locked).
module deepbook_predict::predict_manager;

use deepbook::balance_manager::{Self, BalanceManager, DepositCap, WithdrawCap};
use deepbook_predict::market_key::MarketKey;
use sui::{coin::Coin, table::{Self, Table}};

// === Errors ===
const EInvalidOwner: u64 = 0;
const EInsufficientPosition: u64 = 1;
const EInsufficientFreePosition: u64 = 2;
const EInsufficientCollateral: u64 = 3;

// === Structs ===

public struct UserPosition has copy, drop, store {
    free: u64,
    locked: u64,
}

public struct CollateralKey has copy, drop, store {
    locked_key: MarketKey,
    minted_key: MarketKey,
}

/// PredictManager wraps a BalanceManager and tracks positions.
public struct PredictManager has key {
    id: UID,
    owner: address,
    balance_manager: BalanceManager,
    deposit_cap: DepositCap,
    withdraw_cap: WithdrawCap,
    /// MarketKey -> UserPosition (free, locked)
    positions: Table<MarketKey, UserPosition>,
    /// CollateralKey -> locked quantity per collateral relationship
    collateral: Table<CollateralKey, u64>,
}

// === Public Functions ===

/// Get the owner of the PredictManager.
public fun owner(self: &PredictManager): address {
    self.owner
}

/// Get position quantities for a given key. Returns (free, locked).
public fun position(self: &PredictManager, key: MarketKey): (u64, u64) {
    if (self.positions.contains(key)) {
        let data = self.positions[key];
        (data.free, data.locked)
    } else {
        (0, 0)
    }
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
        collateral: table::new(ctx),
    };
    let manager_id = object::id(&manager);
    transfer::share_object(manager);

    manager_id
}

/// Increase free position quantity. Called when user mints.
public(package) fun increase_position(self: &mut PredictManager, key: MarketKey, quantity: u64) {
    if (!self.positions.contains(key)) {
        self.positions.add(key, UserPosition { free: 0, locked: 0 });
    };
    let data = &mut self.positions[key];
    data.free = data.free + quantity;
}

/// Decrease free position quantity. Called when user redeems.
public(package) fun decrease_position(self: &mut PredictManager, key: MarketKey, quantity: u64) {
    assert!(self.positions.contains(key), EInsufficientPosition);
    let data = &mut self.positions[key];
    assert!(data.free >= quantity, EInsufficientFreePosition);
    data.free = data.free - quantity;
}

/// Lock collateral for a collateralized mint.
public(package) fun lock_collateral(
    self: &mut PredictManager,
    locked_key: MarketKey,
    minted_key: MarketKey,
    quantity: u64,
) {
    assert!(self.positions.contains(locked_key), EInsufficientPosition);
    let data = &mut self.positions[locked_key];
    assert!(data.free >= quantity, EInsufficientFreePosition);

    // Move from free to locked
    data.free = data.free - quantity;
    data.locked = data.locked + quantity;

    // Track collateral relationship
    let collateral_key = CollateralKey { locked_key, minted_key };
    if (!self.collateral.contains(collateral_key)) {
        self.collateral.add(collateral_key, 0);
    };
    let collateral_qty = &mut self.collateral[collateral_key];
    *collateral_qty = *collateral_qty + quantity;
}

/// Release collateral when redeeming a collateralized position.
public(package) fun release_collateral(
    self: &mut PredictManager,
    locked_key: MarketKey,
    minted_key: MarketKey,
    quantity: u64,
) {
    let collateral_key = CollateralKey { locked_key, minted_key };
    assert!(self.collateral.contains(collateral_key), EInsufficientCollateral);

    let collateral_qty = &mut self.collateral[collateral_key];
    assert!(*collateral_qty >= quantity, EInsufficientCollateral);
    *collateral_qty = *collateral_qty - quantity;

    // Move from locked to free
    let data = &mut self.positions[locked_key];
    data.locked = data.locked - quantity;
    data.free = data.free + quantity;
}

