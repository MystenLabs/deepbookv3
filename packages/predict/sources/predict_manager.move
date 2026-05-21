// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// PredictManager wraps a BalanceManager for Predict trading.
///
/// Users deposit DUSDC into the PredictManager. DUSDC custody is delegated to
/// BalanceManager, while positions are tracked as canonical ranges keyed by
/// RangeKey.
///
/// Authorization mirrors BalanceManager: the manager owner can act directly,
/// or grant `TradeCap`, `DepositCap`, and `WithdrawCap` to other addresses.
/// `TradeProof` is used by predict modules to validate the caller against the
/// manager when moving funds during mint/redeem. The inner BalanceManager
/// `DepositCap` and `WithdrawCap` are held by PredictManager itself and never
/// exposed — all custody operations route through them so the inner
/// BalanceManager owner check never fires from a cap holder's call.
module deepbook_predict::predict_manager;

use deepbook::balance_manager::{
    Self,
    BalanceManager,
    DepositCap as BMDepositCap,
    WithdrawCap as BMWithdrawCap
};
use deepbook_predict::{builder_code::{Self, BuilderCode}, math, range_key::RangeKey};
use dusdc::dusdc::DUSDC;
use sui::{coin::Coin, derived_object, event, table::{Self, Table}, vec_set::{Self, VecSet}};

// === Errors ===
const EInsufficientPosition: u64 = 0;
const ENotOwner: u64 = 1;
const EZeroQuantity: u64 = 2;
const EInvalidProof: u64 = 3;
const EInvalidCap: u64 = 4;
const EMaxCapsReached: u64 = 5;
const ECapNotInList: u64 = 6;

// === Constants ===
const MAX_CAPS: u64 = 1000;

// === Structs ===

/// The key for deriving predict manager. u64 is optional for
/// supporting multiple managers per address. Defaults to 0 in v1.
public struct PredictManagerKey(address, u64) has copy, drop, store;

/// PredictManager stores DUSDC in a BalanceManager and tracks positions.
public struct PredictManager has key {
    id: UID,
    balance_manager: BalanceManager,
    /// Inner BalanceManager `DepositCap` used by PredictManager to credit the
    /// underlying balance without going through the BalanceManager owner check.
    deposit_cap: BMDepositCap,
    /// Inner BalanceManager `WithdrawCap` used by PredictManager to debit the
    /// underlying balance without going through the BalanceManager owner check.
    withdraw_cap: BMWithdrawCap,
    /// IDs of PredictManager caps (TradeCap/DepositCap/WithdrawCap) authorized
    /// to act on this manager. Revoking removes the ID from this set.
    allow_listed: VecSet<ID>,
    builder_code_id: Option<ID>,
    /// RangeKey -> position quantity and raw rebate fee basis.
    positions: Table<RangeKey, Position>,
}

/// Quantity plus raw fee basis attached to one active range position.
public struct Position has store {
    quantity: u64,
    rebate_fee_basis: u64,
}

/// Owners of a `TradeCap` can generate a `TradeProof` to mint/redeem
/// positions on this manager. Risk of equivocation since `TradeCap` is an
/// owned object — high-frequency callers should trade as the manager owner.
public struct TradeCap has key, store {
    id: UID,
    predict_manager_id: ID,
}

/// `DepositCap` is used to deposit funds into a PredictManager by a non-owner.
public struct DepositCap has key, store {
    id: UID,
    predict_manager_id: ID,
}

/// `WithdrawCap` is used to withdraw funds from a PredictManager by a non-owner.
public struct WithdrawCap has key, store {
    id: UID,
    predict_manager_id: ID,
}

/// Manager owner and `TradeCap` holders can generate a `TradeProof`. Predict
/// modules consume the proof to authorize the trade and to route deposit /
/// withdraw through the manager's inner BalanceManager caps.
public struct TradeProof has drop {
    predict_manager_id: ID,
    trader: address,
}

/// Emitted when a manager owner changes sticky builder-code attribution.
public struct BuilderCodeSet has copy, drop, store {
    predict_manager_id: ID,
    owner: address,
    builder_code_id: Option<ID>,
}

// === Public Functions ===

/// Share a newly created PredictManager object.
public fun share(self: PredictManager) {
    transfer::share_object(self);
}

/// Return the PredictManager object ID.
public fun id(self: &PredictManager): ID {
    self.id.to_inner()
}

/// Return the BalanceManager owner for this PredictManager.
public fun owner(self: &PredictManager): address {
    self.balance_manager.owner()
}

/// Return the position quantity for a range key.
public fun position(self: &PredictManager, key: RangeKey): u64 {
    if (self.positions.contains(key)) {
        self.positions[key].quantity
    } else {
        0
    }
}

/// Return the raw rebate fee basis attached to a range key.
public fun rebate_fee_basis(self: &PredictManager, key: RangeKey): u64 {
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

/// Mint a `TradeCap`. Only the manager owner can mint.
public fun mint_trade_cap(self: &mut PredictManager, ctx: &mut TxContext): TradeCap {
    self.assert_owner(ctx);
    self.assert_caps_capacity();
    let id = object::new(ctx);
    self.allow_listed.insert(id.to_inner());
    TradeCap { id, predict_manager_id: self.id() }
}

/// Mint a `DepositCap`. Only the manager owner can mint.
public fun mint_deposit_cap(self: &mut PredictManager, ctx: &mut TxContext): DepositCap {
    self.assert_owner(ctx);
    self.assert_caps_capacity();
    let id = object::new(ctx);
    self.allow_listed.insert(id.to_inner());
    DepositCap { id, predict_manager_id: self.id() }
}

/// Mint a `WithdrawCap`. Only the manager owner can mint.
public fun mint_withdraw_cap(self: &mut PredictManager, ctx: &mut TxContext): WithdrawCap {
    self.assert_owner(ctx);
    self.assert_caps_capacity();
    let id = object::new(ctx);
    self.allow_listed.insert(id.to_inner());
    WithdrawCap { id, predict_manager_id: self.id() }
}

/// Revoke a previously minted cap. Only the manager owner can revoke. Works
/// for any of `TradeCap`, `DepositCap`, or `WithdrawCap` since they all live
/// in the same `allow_listed` set.
public fun revoke_cap(self: &mut PredictManager, cap_id: &ID, ctx: &TxContext) {
    self.assert_owner(ctx);
    assert!(self.allow_listed.contains(cap_id), ECapNotInList);
    self.allow_listed.remove(cap_id);
}

/// Generate a `TradeProof` as the manager owner. No equivocation risk.
public fun generate_proof_as_owner(self: &PredictManager, ctx: &TxContext): TradeProof {
    self.assert_owner(ctx);
    TradeProof { predict_manager_id: self.id(), trader: ctx.sender() }
}

/// Generate a `TradeProof` using a `TradeCap`. Cap is an owned object so the
/// holder risks equivocation when generating proofs in concurrent PTBs.
public fun generate_proof_as_trader(
    self: &PredictManager,
    trade_cap: &TradeCap,
    ctx: &TxContext,
): TradeProof {
    self.validate_trader(trade_cap);
    TradeProof { predict_manager_id: self.id(), trader: ctx.sender() }
}

/// Abort unless the proof was generated for this manager.
public fun validate_proof(self: &PredictManager, proof: &TradeProof) {
    assert!(self.id() == proof.predict_manager_id, EInvalidProof);
}

/// Deposit DUSDC into the manager. Only the manager owner may call.
public fun deposit(self: &mut PredictManager, coin: Coin<DUSDC>, ctx: &mut TxContext) {
    self.assert_owner(ctx);
    self.balance_manager.deposit_with_cap(&self.deposit_cap, coin, ctx);
}

/// Withdraw DUSDC from the manager. Only the manager owner may call.
public fun withdraw(self: &mut PredictManager, amount: u64, ctx: &mut TxContext): Coin<DUSDC> {
    self.assert_owner(ctx);
    self.balance_manager.withdraw_with_cap(&self.withdraw_cap, amount, ctx)
}

/// Deposit DUSDC using a `DepositCap`.
public fun deposit_with_cap(
    self: &mut PredictManager,
    cap: &DepositCap,
    coin: Coin<DUSDC>,
    ctx: &TxContext,
) {
    self.validate_depositor(cap);
    self.balance_manager.deposit_with_cap(&self.deposit_cap, coin, ctx);
}

/// Withdraw DUSDC using a `WithdrawCap`.
public fun withdraw_with_cap(
    self: &mut PredictManager,
    cap: &WithdrawCap,
    amount: u64,
    ctx: &mut TxContext,
): Coin<DUSDC> {
    self.validate_withdrawer(cap);
    self.balance_manager.withdraw_with_cap(&self.withdraw_cap, amount, ctx)
}

// === Public-Package Functions ===

/// Create a derived PredictManager for the sender.
public(package) fun new(registry_uid: &mut UID, ctx: &mut TxContext): PredictManager {
    let id = derived_object::claim(registry_uid, PredictManagerKey(ctx.sender(), 0));
    let mut balance_manager = balance_manager::new(ctx);
    let deposit_cap = balance_manager.mint_deposit_cap(ctx);
    let withdraw_cap = balance_manager.mint_withdraw_cap(ctx);

    PredictManager {
        id,
        balance_manager,
        deposit_cap,
        withdraw_cap,
        allow_listed: vec_set::empty(),
        builder_code_id: option::none(),
        positions: table::new(ctx),
    }
}

/// Deposit protocol payouts without requiring any authorization. Used for
/// settled and compacted redemptions, which any caller may trigger.
public(package) fun deposit_permissionless(
    self: &mut PredictManager,
    coin: Coin<DUSDC>,
    ctx: &TxContext,
) {
    self.balance_manager.deposit_with_cap(&self.deposit_cap, coin, ctx);
}

/// Deposit DUSDC into the manager using a validated `TradeProof`.
public(package) fun deposit_with_proof(
    self: &mut PredictManager,
    proof: &TradeProof,
    coin: Coin<DUSDC>,
    ctx: &TxContext,
) {
    self.validate_proof(proof);
    self.balance_manager.deposit_with_cap(&self.deposit_cap, coin, ctx);
}

/// Withdraw DUSDC from the manager using a validated `TradeProof`.
public(package) fun withdraw_with_proof(
    self: &mut PredictManager,
    proof: &TradeProof,
    amount: u64,
    ctx: &mut TxContext,
): Coin<DUSDC> {
    self.validate_proof(proof);
    self.balance_manager.withdraw_with_cap(&self.withdraw_cap, amount, ctx)
}

/// Add position quantity and raw rebate-eligible fee basis to a range.
public(package) fun increase_position(
    self: &mut PredictManager,
    key: RangeKey,
    quantity: u64,
    rebate_fee_basis: u64,
) {
    assert_nonzero_quantity(quantity);
    if (!self.positions.contains(key)) {
        self.positions.add(key, Position { quantity: 0, rebate_fee_basis: 0 });
    };
    let position = &mut self.positions[key];
    position.quantity = position.quantity + quantity;
    position.rebate_fee_basis = position.rebate_fee_basis + rebate_fee_basis;
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
    key: RangeKey,
    quantity: u64,
): u64 {
    let rebate_fee_basis = self.fee_basis_to_remove(key, quantity);
    let remove_position;
    {
        let position = &mut self.positions[key];
        position.quantity = position.quantity - quantity;
        position.rebate_fee_basis = position.rebate_fee_basis - rebate_fee_basis;
        remove_position = position.quantity == 0 && position.rebate_fee_basis == 0;
    };
    if (remove_position) {
        let Position { quantity: _, rebate_fee_basis: _ } = self.positions.remove(key);
    };

    rebate_fee_basis
}

/// Abort unless the transaction sender owns this manager.
public(package) fun assert_owner(self: &PredictManager, ctx: &TxContext) {
    assert!(ctx.sender() == self.balance_manager.owner(), ENotOwner);
}

/// Return the address that generated a trade proof.
public(package) fun trader(proof: &TradeProof): address {
    proof.trader
}

// === Private Functions ===

fun assert_caps_capacity(self: &PredictManager) {
    assert!(self.allow_listed.length() < MAX_CAPS, EMaxCapsReached);
}

fun validate_trader(self: &PredictManager, trade_cap: &TradeCap) {
    assert!(self.allow_listed.contains(object::borrow_id(trade_cap)), EInvalidCap);
}

fun validate_depositor(self: &PredictManager, deposit_cap: &DepositCap) {
    assert!(self.allow_listed.contains(object::borrow_id(deposit_cap)), EInvalidCap);
}

fun validate_withdrawer(self: &PredictManager, withdraw_cap: &WithdrawCap) {
    assert!(self.allow_listed.contains(object::borrow_id(withdraw_cap)), EInvalidCap);
}

fun fee_basis_to_remove(self: &PredictManager, key: RangeKey, quantity: u64): u64 {
    self.assert_can_decrease_position(key, quantity);
    let position = &self.positions[key];
    if (quantity == position.quantity) {
        position.rebate_fee_basis
    } else {
        math::mul_div_round_up(position.rebate_fee_basis, quantity, position.quantity)
    }
}

fun assert_can_decrease_position(self: &PredictManager, key: RangeKey, quantity: u64) {
    assert_nonzero_quantity(quantity);
    assert!(self.positions.contains(key), EInsufficientPosition);
    assert!(self.positions[key].quantity >= quantity, EInsufficientPosition);
}

fun assert_nonzero_quantity(quantity: u64) {
    assert!(quantity > 0, EZeroQuantity);
}
