// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// PredictManager wraps a BalanceManager for Predict trading.
///
/// Users deposit DUSDC into the PredictManager. DUSDC custody is delegated to
/// BalanceManager, while positions are tracked as canonical ranges keyed by
/// RangeKey.
///
/// Authorization mirrors BalanceManager: the manager owner can act directly,
/// or grant `PredictTradeCap`, `PredictDepositCap`, and `PredictWithdrawCap`
/// to other addresses. `PredictTradeProof` is used by predict modules to validate
/// the caller against the manager when moving funds during mint/redeem. The
/// inner BalanceManager `DepositCap` and `WithdrawCap` are held by
/// PredictManager itself and never exposed — all custody operations route
/// through them so the inner BalanceManager owner check never fires from a
/// cap holder's call.
module deepbook_predict::predict_manager;

use deepbook::{
    balance_manager::{Self, BalanceManager, DepositCap, WithdrawCap, TradeCap as BMTradeCap},
    registry::Registry as DeepbookRegistry
};
use deepbook_predict::{builder_code::{Self, BuilderCode}, constants, math, range_key::RangeKey};
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

/// The key for deriving predict manager. u64 distinguishes managers per
/// address: index 0 is reserved for sender-owned managers (`new`), index 1
/// for self-owned managers (`new_self_owned`). Future indices may extend the
/// scheme if multiple managers per sender are added.
public struct PredictManagerKey(address, u64) has copy, drop, store;

/// Witness used to prove that calls into `balance_manager::new_with_custom_owner_caps_v2`
/// originate from this package. The deepbook `Registry` admin must authorize
/// `PredictApp` once via `authorize_app<PredictApp>` before `new_self_owned`
/// can succeed.
public struct PredictApp has drop {}

/// PredictManager stores DUSDC in a BalanceManager and tracks positions.
public struct PredictManager has key {
    id: UID,
    balance_manager: BalanceManager,
    /// Inner BalanceManager `DepositCap` used by PredictManager to credit the
    /// underlying balance without going through the BalanceManager owner check.
    deposit_cap: DepositCap,
    /// Inner BalanceManager `WithdrawCap` used by PredictManager to debit the
    /// underlying balance without going through the BalanceManager owner check.
    withdraw_cap: WithdrawCap,
    /// Unused TradeCap returned by `balance_manager::new_with_custom_owner_caps_v2`.
    /// PredictManager doesn't trade on deepbook pools, so this cap is dead
    /// weight — we stash it because BalanceManager doesn't expose a public
    /// destroy for TradeCap. `option::none` for sender-owned managers, since
    /// the sender-owned constructor doesn't go through `_v2`.
    bm_trade_cap: Option<BMTradeCap>,
    /// IDs of PredictManager caps (PredictTradeCap / PredictDepositCap /
    /// PredictWithdrawCap) authorized to act on this manager. Revoking removes
    /// the ID from this set.
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

/// Owners of a `PredictTradeCap` can generate a `PredictTradeProof` to mint/redeem
/// positions on this manager. Risk of equivocation since `PredictTradeCap` is
/// an owned object — high-frequency callers should trade as the manager owner.
public struct PredictTradeCap has key, store {
    id: UID,
    predict_manager_id: ID,
}

/// `PredictDepositCap` is used to deposit funds into a PredictManager by a
/// non-owner.
public struct PredictDepositCap has key, store {
    id: UID,
    predict_manager_id: ID,
}

/// `PredictWithdrawCap` is used to withdraw funds from a PredictManager by a
/// non-owner.
public struct PredictWithdrawCap has key, store {
    id: UID,
    predict_manager_id: ID,
}

/// Manager owner and `PredictTradeCap` holders can generate a `PredictTradeProof`.
/// Predict modules consume the proof to authorize the trade and to route
/// deposit / withdraw through the manager's inner BalanceManager caps.
public struct PredictTradeProof has drop {
    predict_manager_id: ID,
    trader: address,
}

/// Emitted when a manager owner changes sticky builder-code attribution.
public struct BuilderCodeSet has copy, drop, store {
    predict_manager_id: ID,
    owner: address,
    builder_code_id: Option<ID>,
}

/// Emitted when a `PredictTradeCap` is minted.
public struct PredictTradeCapMinted has copy, drop, store {
    predict_manager_id: ID,
    cap_id: ID,
}

/// Emitted when a `PredictDepositCap` is minted.
public struct PredictDepositCapMinted has copy, drop, store {
    predict_manager_id: ID,
    cap_id: ID,
}

/// Emitted when a `PredictWithdrawCap` is minted.
public struct PredictWithdrawCapMinted has copy, drop, store {
    predict_manager_id: ID,
    cap_id: ID,
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

/// Mint a `PredictTradeCap`. Only the manager owner can mint. Unreachable
/// on self-owned managers; all caps for those are minted by `new_self_owned`.
public fun mint_trade_cap(self: &mut PredictManager, ctx: &mut TxContext): PredictTradeCap {
    self.assert_owner(ctx);
    self.assert_caps_capacity();
    let id = object::new(ctx);
    let cap_id = id.to_inner();
    self.allow_listed.insert(cap_id);
    event::emit(PredictTradeCapMinted { predict_manager_id: self.id(), cap_id });
    PredictTradeCap { id, predict_manager_id: self.id() }
}

/// Mint a `PredictDepositCap`. Only the manager owner can mint. Unreachable
/// on self-owned managers; all caps for those are minted by `new_self_owned`.
public fun mint_deposit_cap(self: &mut PredictManager, ctx: &mut TxContext): PredictDepositCap {
    self.assert_owner(ctx);
    self.assert_caps_capacity();
    let id = object::new(ctx);
    let cap_id = id.to_inner();
    self.allow_listed.insert(cap_id);
    event::emit(PredictDepositCapMinted { predict_manager_id: self.id(), cap_id });
    PredictDepositCap { id, predict_manager_id: self.id() }
}

/// Mint a `PredictWithdrawCap`. Only the manager owner can mint. Unreachable
/// on self-owned managers; all caps for those are minted by `new_self_owned`.
public fun mint_withdraw_cap(self: &mut PredictManager, ctx: &mut TxContext): PredictWithdrawCap {
    self.assert_owner(ctx);
    self.assert_caps_capacity();
    let id = object::new(ctx);
    let cap_id = id.to_inner();
    self.allow_listed.insert(cap_id);
    event::emit(PredictWithdrawCapMinted { predict_manager_id: self.id(), cap_id });
    PredictWithdrawCap { id, predict_manager_id: self.id() }
}

/// Revoke a previously minted cap. Only the manager owner can revoke. Works
/// for any of `PredictTradeCap`, `PredictDepositCap`, or `PredictWithdrawCap`
/// since they all live in the same `allow_listed` set.
public fun revoke_cap(self: &mut PredictManager, cap_id: &ID, ctx: &TxContext) {
    self.assert_owner(ctx);
    assert!(self.allow_listed.contains(cap_id), ECapNotInList);
    self.allow_listed.remove(cap_id);
}

/// Generate a `PredictTradeProof` as the manager owner. No equivocation risk.
public fun generate_proof_as_owner(self: &PredictManager, ctx: &TxContext): PredictTradeProof {
    self.assert_owner(ctx);
    PredictTradeProof { predict_manager_id: self.id(), trader: ctx.sender() }
}

/// Generate a `PredictTradeProof` using a `PredictTradeCap`. Cap is an owned object
/// so the holder risks equivocation when generating proofs in concurrent PTBs.
public fun generate_proof_as_trader(
    self: &PredictManager,
    trade_cap: &PredictTradeCap,
    ctx: &TxContext,
): PredictTradeProof {
    self.validate_trader(trade_cap);
    PredictTradeProof { predict_manager_id: self.id(), trader: ctx.sender() }
}

/// Abort unless the proof was generated for this manager.
public fun validate_proof(self: &PredictManager, proof: &PredictTradeProof) {
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

/// Deposit DUSDC using a `PredictDepositCap`.
public fun deposit_with_cap(
    self: &mut PredictManager,
    cap: &PredictDepositCap,
    coin: Coin<DUSDC>,
    ctx: &TxContext,
) {
    self.validate_depositor(cap);
    self.balance_manager.deposit_with_cap(&self.deposit_cap, coin, ctx);
}

/// Withdraw DUSDC using a `PredictWithdrawCap`.
public fun withdraw_with_cap(
    self: &mut PredictManager,
    cap: &PredictWithdrawCap,
    amount: u64,
    ctx: &mut TxContext,
): Coin<DUSDC> {
    self.validate_withdrawer(cap);
    self.balance_manager.withdraw_with_cap(&self.withdraw_cap, amount, ctx)
}

// === Public-Package Functions ===

/// Create a sender-owned PredictManager. The sender is the BalanceManager
/// owner and can act directly on the manager without holding any cap. Use
/// this when the manager is held by a human/EOA who is expected to be the
/// trust anchor.
public(package) fun new(registry_uid: &mut UID, ctx: &mut TxContext): PredictManager {
    let id = derived_object::claim(
        registry_uid,
        PredictManagerKey(ctx.sender(), constants::sender_owned_manager_slot!()),
    );
    let mut balance_manager = balance_manager::new(ctx);
    let deposit_cap = balance_manager.mint_deposit_cap(ctx);
    let withdraw_cap = balance_manager.mint_withdraw_cap(ctx);

    PredictManager {
        id,
        balance_manager,
        deposit_cap,
        withdraw_cap,
        bm_trade_cap: option::none(),
        allow_listed: vec_set::empty(),
        builder_code_id: option::none(),
        positions: table::new(ctx),
    }
}

/// Create a PredictManager that owns itself: the inner BalanceManager's
/// owner is set to the PredictManager's own ID-as-address, which no
/// transaction sender can ever match. The owner-direct deposit/withdraw and
/// `mint_*_cap` paths are permanently unreachable, so caps minted here are
/// the only authority that will ever exist on this manager.
///
/// Intended for contracts (vaults, custodial products) that don't want a
/// deployer-key trust anchor. The caller receives one cap of each kind and
/// is expected to install them inside its own contract object.
///
/// Requires `PredictApp` to be authorized on the deepbook `Registry` via
/// `deepbook::registry::authorize_app<PredictApp>` — a one-time admin tx
/// on the deepbook side.
public(package) fun new_self_owned(
    registry_uid: &mut UID,
    deepbook_registry: &DeepbookRegistry,
    ctx: &mut TxContext,
): (PredictManager, PredictDepositCap, PredictWithdrawCap, PredictTradeCap) {
    let id = derived_object::claim(
        registry_uid,
        PredictManagerKey(ctx.sender(), constants::self_owned_manager_slot!()),
    );
    let owner_address = id.to_inner().to_address();

    let (
        balance_manager,
        bm_deposit_cap,
        bm_withdraw_cap,
        bm_trade_cap,
    ) = balance_manager::new_with_custom_owner_caps_v2(
        PredictApp {},
        deepbook_registry,
        owner_address,
        ctx,
    );

    let mut manager = PredictManager {
        id,
        balance_manager,
        deposit_cap: bm_deposit_cap,
        withdraw_cap: bm_withdraw_cap,
        bm_trade_cap: option::some(bm_trade_cap),
        allow_listed: vec_set::empty(),
        builder_code_id: option::none(),
        positions: table::new(ctx),
    };

    let manager_id = manager.id();

    let predict_trade_id = object::new(ctx);
    let predict_trade_cap_id = predict_trade_id.to_inner();
    manager.allow_listed.insert(predict_trade_cap_id);
    event::emit(PredictTradeCapMinted {
        predict_manager_id: manager_id,
        cap_id: predict_trade_cap_id,
    });
    let predict_trade_cap = PredictTradeCap {
        id: predict_trade_id,
        predict_manager_id: manager_id,
    };

    let predict_deposit_id = object::new(ctx);
    let predict_deposit_cap_id = predict_deposit_id.to_inner();
    manager.allow_listed.insert(predict_deposit_cap_id);
    event::emit(PredictDepositCapMinted {
        predict_manager_id: manager_id,
        cap_id: predict_deposit_cap_id,
    });
    let predict_deposit_cap = PredictDepositCap {
        id: predict_deposit_id,
        predict_manager_id: manager_id,
    };

    let predict_withdraw_id = object::new(ctx);
    let predict_withdraw_cap_id = predict_withdraw_id.to_inner();
    manager.allow_listed.insert(predict_withdraw_cap_id);
    event::emit(PredictWithdrawCapMinted {
        predict_manager_id: manager_id,
        cap_id: predict_withdraw_cap_id,
    });
    let predict_withdraw_cap = PredictWithdrawCap {
        id: predict_withdraw_id,
        predict_manager_id: manager_id,
    };

    (manager, predict_deposit_cap, predict_withdraw_cap, predict_trade_cap)
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

/// Deposit DUSDC into the manager using a validated `PredictTradeProof`.
public(package) fun deposit_with_proof(
    self: &mut PredictManager,
    proof: &PredictTradeProof,
    coin: Coin<DUSDC>,
    ctx: &TxContext,
) {
    self.validate_proof(proof);
    self.balance_manager.deposit_with_cap(&self.deposit_cap, coin, ctx);
}

/// Withdraw DUSDC from the manager using a validated `PredictTradeProof`.
public(package) fun withdraw_with_proof(
    self: &mut PredictManager,
    proof: &PredictTradeProof,
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
public(package) fun trader(proof: &PredictTradeProof): address {
    proof.trader
}

// === Private Functions ===

fun assert_caps_capacity(self: &PredictManager) {
    assert!(self.allow_listed.length() < MAX_CAPS, EMaxCapsReached);
}

fun validate_trader(self: &PredictManager, trade_cap: &PredictTradeCap) {
    assert!(self.allow_listed.contains(object::borrow_id(trade_cap)), EInvalidCap);
}

fun validate_depositor(self: &PredictManager, deposit_cap: &PredictDepositCap) {
    assert!(self.allow_listed.contains(object::borrow_id(deposit_cap)), EInvalidCap);
}

fun validate_withdrawer(self: &PredictManager, withdraw_cap: &PredictWithdrawCap) {
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
