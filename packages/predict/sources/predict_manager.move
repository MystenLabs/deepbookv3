// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// PredictManager wraps a BalanceManager for Predict trading.
///
/// Users deposit DUSDC into the PredictManager. DUSDC custody is delegated to
/// BalanceManager, while positions are tracked as individual orders keyed by
/// expiry market and order ID.
module deepbook_predict::predict_manager;

use deepbook::balance_manager::{Self, BalanceManager, DepositCap};
use deepbook_predict::{builder_code::{Self, BuilderCode}, math};
use dusdc::dusdc::DUSDC;
use sui::{coin::Coin, derived_object, event, table::{Self, Table}};

const EInsufficientPosition: u64 = 0;
const ENotOwner: u64 = 1;
const EZeroQuantity: u64 = 2;

/// The key for deriving predict manager. u64 is optional for
/// supporting multiple managers per address. Defaults to 0 in v1.
public struct PredictManagerKey(address, u64) has copy, drop, store;

/// PredictManager stores DUSDC in a BalanceManager and tracks positions.
public struct PredictManager has key {
    id: UID,
    balance_manager: BalanceManager,
    deposit_cap: DepositCap,
    builder_code_id: Option<ID>,
    /// Per-order position state keyed by expiry market and order ID.
    positions: Table<PositionKey, Position>,
}

/// Key for one order-owned position in one expiry market.
public struct PositionKey has copy, drop, store {
    expiry_market_id: ID,
    order_id: u256,
}

/// Quantity and raw rebate fee basis attached to one active order.
public struct Position has store {
    quantity: u64,
    rebate_fee_basis: u64,
}

/// Emitted when a manager owner changes sticky builder-code attribution.
public struct BuilderCodeSet has copy, drop, store {
    predict_manager_id: ID,
    owner: address,
    builder_code_id: Option<ID>,
}

// === Public Functions ===

/// Return the PredictManager object ID.
public fun id(self: &PredictManager): ID {
    self.id.to_inner()
}

/// Return the BalanceManager owner for this PredictManager.
public fun owner(self: &PredictManager): address {
    self.balance_manager.owner()
}

/// Return the position quantity for an order ID.
public fun position(self: &PredictManager, expiry_market_id: ID, order_id: u256): u64 {
    let key = position_key(expiry_market_id, order_id);
    if (self.positions.contains(key)) {
        self.positions[key].quantity
    } else {
        0
    }
}

/// Return the raw rebate fee basis attached to an order ID.
public fun rebate_fee_basis(self: &PredictManager, expiry_market_id: ID, order_id: u256): u64 {
    let key = position_key(expiry_market_id, order_id);
    if (self.positions.contains(key)) {
        self.positions[key].rebate_fee_basis
    } else {
        0
    }
}

/// Return the DUSDC balance held by this PredictManager.
public fun balance(self: &PredictManager): u64 {
    self.balance_manager.balance<DUSDC>()
}

/// Return the sticky builder-code ID used for future trades, if one is set.
public fun builder_code_id(self: &PredictManager): Option<ID> {
    self.builder_code_id
}

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

/// Set sticky builder-code attribution for future trades.
public fun set_builder_code(
    self: &mut PredictManager,
    builder_code: &BuilderCode,
    ctx: &TxContext,
) {
    self.assert_owner(ctx);
    let builder_code_id = builder_code::id(builder_code);
    self.builder_code_id = option::some(builder_code_id);
    event::emit(BuilderCodeSet {
        predict_manager_id: self.id(),
        owner: self.owner(),
        builder_code_id: option::some(builder_code_id),
    });
}

/// Clear sticky builder-code attribution for future trades.
public fun unset_builder_code(self: &mut PredictManager, ctx: &TxContext) {
    self.assert_owner(ctx);
    self.builder_code_id = option::none();
    event::emit(BuilderCodeSet {
        predict_manager_id: self.id(),
        owner: self.owner(),
        builder_code_id: option::none(),
    });
}

// === Public-Package Functions ===

/// Abort unless the transaction sender owns this manager.
public(package) fun assert_owner(self: &PredictManager, ctx: &TxContext) {
    assert!(ctx.sender() == self.balance_manager.owner(), ENotOwner);
}

/// Create a derived PredictManager for the sender.
public(package) fun new(registry_uid: &mut UID, ctx: &mut TxContext): PredictManager {
    let id = derived_object::claim(registry_uid, PredictManagerKey(ctx.sender(), 0));
    let mut balance_manager = balance_manager::new(ctx);
    let deposit_cap = balance_manager.mint_deposit_cap(ctx);

    PredictManager {
        id,
        balance_manager,
        deposit_cap,
        builder_code_id: option::none(),
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

/// Add position quantity and raw rebate fee basis for a new order.
public(package) fun increase_position(
    self: &mut PredictManager,
    expiry_market_id: ID,
    order_id: u256,
    quantity: u64,
    rebate_fee_basis: u64,
) {
    assert_nonzero_quantity(quantity);
    let position_key = position_key(expiry_market_id, order_id);
    self
        .positions
        .add(
            position_key,
            Position {
                quantity,
                rebate_fee_basis,
            },
        );
}

/// Remove position quantity and return the raw fee basis removed with it.
///
/// Full removal takes the exact remaining fee basis. Partial removal rounds up
/// so repeated partial burns cannot strand rebate basis in a zero-quantity
/// position.
///
/// Empty positions are deleted only after both quantity and fee basis reach
/// zero.
public(package) fun decrease_position(
    self: &mut PredictManager,
    expiry_market_id: ID,
    order_id: u256,
    quantity: u64,
): u64 {
    let position_key = position_key(expiry_market_id, order_id);
    let rebate_fee_basis = self.fee_basis_to_remove(position_key, quantity);
    let remove_position;
    {
        let position = &mut self.positions[position_key];
        position.quantity = position.quantity - quantity;
        position.rebate_fee_basis = position.rebate_fee_basis - rebate_fee_basis;
        remove_position = position.quantity == 0 && position.rebate_fee_basis == 0;
    };
    if (remove_position) {
        let Position {
            quantity: _,
            rebate_fee_basis: _,
        } = self.positions.remove(position_key);
    };

    rebate_fee_basis
}

fun fee_basis_to_remove(self: &PredictManager, key: PositionKey, quantity: u64): u64 {
    self.assert_can_decrease_position(key, quantity);
    let position = &self.positions[key];
    if (quantity == position.quantity) {
        position.rebate_fee_basis
    } else {
        math::mul_div_round_up(position.rebate_fee_basis, quantity, position.quantity)
    }
}

fun assert_can_decrease_position(self: &PredictManager, key: PositionKey, quantity: u64) {
    assert_nonzero_quantity(quantity);
    assert!(self.positions.contains(key), EInsufficientPosition);
    assert!(self.positions[key].quantity >= quantity, EInsufficientPosition);
}

fun assert_nonzero_quantity(quantity: u64) {
    assert!(quantity > 0, EZeroQuantity);
}

fun position_key(expiry_market_id: ID, order_id: u256): PositionKey {
    PositionKey { expiry_market_id, order_id }
}
