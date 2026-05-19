// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// PredictManager wraps a BalanceManager for Predict trading.
///
/// Users deposit USDC into the PredictManager, which is stored in the inner
/// BalanceManager. Positions are tracked as binary instruments (UP/DOWN)
/// keyed by MarketKey.
module deepbook_predict::predict_manager;

use deepbook::balance_manager::{Self, BalanceManager, DepositCap, WithdrawCap};
use deepbook_predict::market_key::{MarketKey, CollateralKey};
use sui::{coin::Coin, derived_object, table::{Self, Table}};

const EInvalidOwner: u64 = 0;
const EInsufficientPosition: u64 = 1;

/// The key for deriving predict manager. u64 is optional for
/// supporting multiple managers per address. Defaults to 0 in v1.
public struct PredictManagerKey(address, u64) has copy, drop, store;

/// Tracks user position across two states: free (tradeable) and locked
/// (held in a paired collateral lock).
public struct UserPosition has copy, drop, store {
    free: u64,
    locked: u64,
}

/// PredictManager wraps a BalanceManager and tracks positions.
public struct PredictManager has key {
    id: UID,
    owner: address,
    balance_manager: BalanceManager,
    deposit_cap: DepositCap,
    withdraw_cap: WithdrawCap,
    /// MarketKey -> UserPosition
    positions: Table<MarketKey, UserPosition>,
    /// CollateralKey -> quantity (number of UP+DN pairs locked)
    collateral: Table<CollateralKey, u64>,
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

/// Get the free and locked position quantity for a given MarketKey.
public fun position(self: &PredictManager, key: MarketKey): (u64, u64) {
    if (self.positions.contains(key)) {
        let pos = &self.positions[key];
        (pos.free, pos.locked)
    } else {
        (0, 0)
    }
}

/// Get the quantity of locked paired positions for a given CollateralKey.
public fun collateral(self: &PredictManager, key: CollateralKey): u64 {
    if (self.collateral.contains(key)) {
        self.collateral[key]
    } else {
        0
    }
}

/// Get the balance of a specific coin type in the PredictManager.
public fun balance<T>(self: &PredictManager): u64 {
    self.balance_manager.balance<T>()
}

// === Public-Package Functions ===

/// Create a new PredictManager.
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
        collateral: table::new(ctx),
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

/// Increase free position quantity.
public(package) fun increase_position(self: &mut PredictManager, key: MarketKey, quantity: u64) {
    if (!self.positions.contains(key)) {
        self.positions.add(key, UserPosition { free: 0, locked: 0 });
    };
    let pos = &mut self.positions[key];
    pos.free = pos.free + quantity;
}

/// Decrease free position quantity.
public(package) fun decrease_position(self: &mut PredictManager, key: MarketKey, quantity: u64) {
    assert!(self.positions.contains(key), EInsufficientPosition);
    let pos = &mut self.positions[key];
    assert!(pos.free >= quantity, EInsufficientPosition);
    pos.free = pos.free - quantity;
}

/// Lock a pair of UP and DOWN positions into collateral.
public(package) fun lock_collateral(
    self: &mut PredictManager,
    up_key: MarketKey,
    down_key: MarketKey,
    quantity: u64,
) {
    let collateral_key = up_key.to_collateral();

    self.decrease_position(up_key, quantity);
    self.decrease_position(down_key, quantity);

    if (!self.collateral.contains(collateral_key)) {
        self.collateral.add(collateral_key, 0);
    };
    let collat_qty = &mut self.collateral[collateral_key];
    *collat_qty = *collat_qty + quantity;

    let up_pos = &mut self.positions[up_key];
    up_pos.locked = up_pos.locked + quantity;

    let down_pos = &mut self.positions[down_key];
    down_pos.locked = down_pos.locked + quantity;
}

/// Unlock a pair of positions from collateral back to free state.
public(package) fun unlock_collateral(
    self: &mut PredictManager,
    up_key: MarketKey,
    down_key: MarketKey,
    quantity: u64,
) {
    let collateral_key = up_key.to_collateral();

    assert!(self.collateral.contains(collateral_key), EInsufficientPosition);
    let collat_qty = &mut self.collateral[collateral_key];
    assert!(*collat_qty >= quantity, EInsufficientPosition);
    *collat_qty = *collat_qty - quantity;

    let up_pos = &mut self.positions[up_key];
    up_pos.locked = up_pos.locked - quantity;
    up_pos.free = up_pos.free + quantity;

    let down_pos = &mut self.positions[down_key];
    down_pos.locked = down_pos.locked - quantity;
    down_pos.free = down_pos.free + quantity;
}

// === Test-Only Functions ===

#[test_only]
public fun new_test_manager(ctx: &mut TxContext): PredictManager {
    PredictManager {
        id: object::new(ctx),
        owner: ctx.sender(),
        balance_manager: deepbook::balance_manager::new(ctx),
        deposit_cap: deepbook::balance_manager::mint_deposit_cap_for_testing(ctx),
        withdraw_cap: deepbook::balance_manager::mint_withdraw_cap_for_testing(ctx),
        positions: table::new(ctx),
        collateral: table::new(ctx),
    }
}

#[test_only]
public fun destroy_test_manager(self: PredictManager) {
    let PredictManager {
        id,
        owner: _,
        balance_manager,
        deposit_cap,
        withdraw_cap,
        positions,
        collateral,
    } = self;
    id.delete();
    balance_manager.destroy_for_testing();
    deposit_cap.destroy_for_testing();
    withdraw_cap.destroy_for_testing();
    positions.drop();
    collateral.drop();
}

