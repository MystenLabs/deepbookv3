// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The BalanceManager is a shared object that holds all of the balances for different assets. A combination of `BalanceManager` and
/// `TradeProof` are passed into a pool to perform trades. A `TradeProof` can be generated in two ways: by the
/// owner directly, or by any `TradeCap` owner. The owner can generate a `TradeProof` without the risk of
/// equivocation. The `TradeCap` owner, due to it being an owned object, risks equivocation when generating
/// a `TradeProof`. Generally, a high frequency trading engine will trade as the default owner.
module deepbook::balance_manager;

use deepbook::registry::Registry;
use std::type_name::{Self, TypeName};
use sui::{
    bag::{Self, Bag},
    balance::{Self, Balance},
    coin::Coin,
    dynamic_field as df,
    event,
    object::id_from_address,
    vec_set::{Self, VecSet}
};

use fun df::borrow as UID.borrow;
use fun df::exists_ as UID.exists_;
use fun df::remove_if_exists as UID.remove_if_exists;
use fun df::add as UID.add;

// === Errors ===
const EInvalidOwner: u64 = 0;
const EInvalidTrader: u64 = 1;
const EInvalidProof: u64 = 2;
const EBalanceManagerBalanceTooLow: u64 = 3;
const EMaxCapsReached: u64 = 4;
const ECapNotInList: u64 = 5;
const EInvalidReferralOwner: u64 = 6;

// === Constants ===
const MAX_TRADE_CAPS: u64 = 1000;

// === Structs ===
/// A shared object that is passed into pools for placing orders.
public struct BalanceManager has key, store {
    id: UID,
    owner: address,
    balances: Bag,
    allow_listed: VecSet<ID>,
}

/// Event emitted when a new balance_manager is created.
public struct BalanceManagerEvent has copy, drop {
    balance_manager_id: ID,
    owner: address,
}

/// Event emitted when a deposit or withdrawal occurs.
public struct BalanceEvent has copy, drop {
    balance_manager_id: ID,
    asset: TypeName,
    amount: u64,
    deposit: bool,
}

/// Balance identifier.
public struct BalanceKey<phantom T> has copy, drop, store {}

/// Referral identifier.
public struct ReferralKey(ID) has copy, drop, store;

/// Owners of a `TradeCap` need to get a `TradeProof` to trade across pools in a single PTB (drops after).
public struct TradeCap has key, store {
    id: UID,
    balance_manager_id: ID,
}

/// `DepositCap` is used to deposit funds to a balance_manager by a non-owner.
public struct DepositCap has key, store {
    id: UID,
    balance_manager_id: ID,
}

/// WithdrawCap is used to withdraw funds from a balance_manager by a non-owner.
public struct WithdrawCap has key, store {
    id: UID,
    balance_manager_id: ID,
}

#[deprecated(note = b"This struct is deprecated, replaced by `DeepBookPoolReferral`.")]
public struct DeepBookReferral has key, store {
    id: UID,
    owner: address,
}

public struct DeepBookPoolReferral has key, store {
    id: UID,
    owner: address,
    pool_id: ID,
}

public struct DeepBookReferralCreatedEvent has copy, drop {
    referral_id: ID,
    owner: address,
}

public struct DeepBookReferralSetEvent has copy, drop {
    referral_id: ID,
    balance_manager_id: ID,
}

/// BalanceManager owner and `TradeCap` owners can generate a `TradeProof`.
/// `TradeProof` is used to validate the balance_manager when trading on DeepBook.
public struct TradeProof has drop {
    balance_manager_id: ID,
    trader: address,
}

// === Public-Mutative Functions ===
public fun new(ctx: &mut TxContext): BalanceManager {
    let id = object::new(ctx);
    event::emit(BalanceManagerEvent {
        balance_manager_id: id.to_inner(),
        owner: ctx.sender(),
    });

    BalanceManager {
        id,
        owner: ctx.sender(),
        balances: bag::new(ctx),
        allow_listed: vec_set::empty(),
    }
}

#[deprecated(note = b"This function is deprecated, use `new_with_custom_owner` instead.")]
public fun new_with_owner(_ctx: &mut TxContext, _owner: address): BalanceManager {
    abort 1337
}

/// Create a new balance manager with an owner.
public fun new_with_custom_owner(owner: address, ctx: &mut TxContext): BalanceManager {
    let id = object::new(ctx);
    event::emit(BalanceManagerEvent {
        balance_manager_id: id.to_inner(),
        owner,
    });

    BalanceManager {
        id,
        owner,
        balances: bag::new(ctx),
        allow_listed: vec_set::empty(),
    }
}

#[deprecated(note = b"This function is deprecated, use `new_with_custom_owner_caps` instead.")]
public fun new_with_custom_owner_and_caps(
    _owner: address,
    _ctx: &mut TxContext,
): (BalanceManager, DepositCap, WithdrawCap, TradeCap) { abort 1337 }

public fun new_with_custom_owner_caps<App: drop>(
    deepbook_registry: &Registry,
    owner: address,
    ctx: &mut TxContext,
): (BalanceManager, DepositCap, WithdrawCap, TradeCap) {
    deepbook_registry.assert_app_is_authorized<App>();
    let mut balance_manager = new_with_custom_owner(owner, ctx);

    let deposit_cap = mint_deposit_cap_internal(&mut balance_manager, ctx);
    let withdraw_cap = mint_withdraw_cap_internal(&mut balance_manager, ctx);
    let trade_cap = mint_trade_cap_internal(&mut balance_manager, ctx);

    (balance_manager, deposit_cap, withdraw_cap, trade_cap)
}

#[deprecated(note = b"This function is deprecated, use `set_balance_manager_referral` instead.")]
public fun set_referral(
    _balance_manager: &mut BalanceManager,
    _referral: &DeepBookReferral,
    _trade_cap: &TradeCap,
) { abort }

/// Set the referral for the balance manager.
public fun set_balance_manager_referral(
    balance_manager: &mut BalanceManager,
    referral: &DeepBookPoolReferral,
    trade_cap: &TradeCap,
) {
    balance_manager.validate_trader(trade_cap);
    let _: Option<ID> = balance_manager.id.remove_if_exists(ReferralKey(referral.pool_id));
    balance_manager.id.add(ReferralKey(referral.pool_id), referral.id.to_inner());

    event::emit(DeepBookReferralSetEvent {
        referral_id: referral.id.to_inner(),
        balance_manager_id: balance_manager.id.to_inner(),
    });
}

#[deprecated(note = b"This function is deprecated, use `unset_balance_manager_referral` instead.")]
public fun unset_referral(_balance_manager: &mut BalanceManager, _trade_cap: &TradeCap) {
    abort
}

/// Unset the referral for the balance manager.
public fun unset_balance_manager_referral(
    balance_manager: &mut BalanceManager,
    pool_id: ID,
    trade_cap: &TradeCap,
) {
    balance_manager.validate_trader(trade_cap);
    let _: Option<ID> = balance_manager.id.remove_if_exists(ReferralKey(pool_id));

    event::emit(DeepBookReferralSetEvent {
        referral_id: id_from_address(@0x0),
        balance_manager_id: balance_manager.id.to_inner(),
    });
}

/// Returns the balance of a Coin in a balance manager.
public fun balance<T>(balance_manager: &BalanceManager): u64 {
    let key = BalanceKey<T> {};
    if (!balance_manager.balances.contains(key)) {
        0
    } else {
        let acc_balance: &Balance<T> = &balance_manager.balances[key];
        acc_balance.value()
    }
}

/// Mint a `TradeCap`, only owner can mint a `TradeCap`.
public fun mint_trade_cap(balance_manager: &mut BalanceManager, ctx: &mut TxContext): TradeCap {
    balance_manager.validate_owner(ctx);
    balance_manager.mint_trade_cap_internal(ctx)
}

/// Mint a `DepositCap`, only owner can mint.
public fun mint_deposit_cap(balance_manager: &mut BalanceManager, ctx: &mut TxContext): DepositCap {
    balance_manager.validate_owner(ctx);
    balance_manager.mint_deposit_cap_internal(ctx)
}

/// Mint a `WithdrawCap`, only owner can mint.
public fun mint_withdraw_cap(
    balance_manager: &mut BalanceManager,
    ctx: &mut TxContext,
): WithdrawCap {
    balance_manager.validate_owner(ctx);
    balance_manager.mint_withdraw_cap_internal(ctx)
}

/// Revoke a `TradeCap`. Only the owner can revoke a `TradeCap`.
/// Can also be used to revoke `DepositCap` and `WithdrawCap`.
public fun revoke_trade_cap(
    balance_manager: &mut BalanceManager,
    trade_cap_id: &ID,
    ctx: &TxContext,
) {
    balance_manager.validate_owner(ctx);

    assert!(balance_manager.allow_listed.contains(trade_cap_id), ECapNotInList);
    balance_manager.allow_listed.remove(trade_cap_id);
}

/// Generate a `TradeProof` by the owner. The owner does not require a capability
/// and can generate TradeProofs without the risk of equivocation.
public fun generate_proof_as_owner(
    balance_manager: &mut BalanceManager,
    ctx: &TxContext,
): TradeProof {
    balance_manager.validate_owner(ctx);

    TradeProof {
        balance_manager_id: object::id(balance_manager),
        trader: ctx.sender(),
    }
}

/// Generate a `TradeProof` with a `TradeCap`.
/// Risk of equivocation since `TradeCap` is an owned object.
public fun generate_proof_as_trader(
    balance_manager: &mut BalanceManager,
    trade_cap: &TradeCap,
    ctx: &TxContext,
): TradeProof {
    balance_manager.validate_trader(trade_cap);

    TradeProof {
        balance_manager_id: object::id(balance_manager),
        trader: ctx.sender(),
    }
}

/// Deposit funds to a balance manager. Only owner can call this directly.
public fun deposit<T>(balance_manager: &mut BalanceManager, coin: Coin<T>, ctx: &mut TxContext) {
    balance_manager.emit_balance_event(
        type_name::with_defining_ids<T>(),
        coin.value(),
        true,
    );

    let proof = balance_manager.generate_proof_as_owner(ctx);
    balance_manager.deposit_with_proof(&proof, coin.into_balance());
}

/// Deposit funds into a balance manager by a `DepositCap` owner.
public fun deposit_with_cap<T>(
    balance_manager: &mut BalanceManager,
    deposit_cap: &DepositCap,
    coin: Coin<T>,
    ctx: &TxContext,
) {
    balance_manager.emit_balance_event(
        type_name::with_defining_ids<T>(),
        coin.value(),
        true,
    );

    let proof = balance_manager.generate_proof_as_depositor(deposit_cap, ctx);
    balance_manager.deposit_with_proof(&proof, coin.into_balance());
}

/// Withdraw funds from a balance manager by a `WithdrawCap` owner.
public fun withdraw_with_cap<T>(
    balance_manager: &mut BalanceManager,
    withdraw_cap: &WithdrawCap,
    withdraw_amount: u64,
    ctx: &mut TxContext,
): Coin<T> {
    let proof = balance_manager.generate_proof_as_withdrawer(
        withdraw_cap,
        ctx,
    );
    let coin = balance_manager.withdraw_with_proof(&proof, withdraw_amount, false).into_coin(ctx);
    balance_manager.emit_balance_event(
        type_name::with_defining_ids<T>(),
        coin.value(),
        false,
    );

    coin
}

/// Withdraw funds from a balance_manager. Only owner can call this directly.
/// If withdraw_all is true, amount is ignored and full balance withdrawn.
/// If withdraw_all is false, withdraw_amount will be withdrawn.
public fun withdraw<T>(
    balance_manager: &mut BalanceManager,
    withdraw_amount: u64,
    ctx: &mut TxContext,
): Coin<T> {
    let proof = generate_proof_as_owner(balance_manager, ctx);
    let coin = balance_manager.withdraw_with_proof(&proof, withdraw_amount, false).into_coin(ctx);
    balance_manager.emit_balance_event(
        type_name::with_defining_ids<T>(),
        coin.value(),
        false,
    );

    coin
}

public fun withdraw_all<T>(balance_manager: &mut BalanceManager, ctx: &mut TxContext): Coin<T> {
    let proof = generate_proof_as_owner(balance_manager, ctx);
    let coin = balance_manager.withdraw_with_proof(&proof, 0, true).into_coin(ctx);
    balance_manager.emit_balance_event(
        type_name::with_defining_ids<T>(),
        coin.value(),
        false,
    );

    coin
}

#[deprecated(note = b"This function is deprecated, use `register_balance_manager` instead.")]
public fun register_manager(_balance_manager: &BalanceManager, _registry: &mut Registry) {
    abort 1337
}

public fun register_balance_manager(
    balance_manager: &BalanceManager,
    registry: &mut Registry,
    ctx: &mut TxContext,
) {
    balance_manager.validate_owner(ctx);
    let owner = balance_manager.owner();
    let manager_id = balance_manager.id();
    registry.add_balance_manager(owner, manager_id);
}

#[deprecated(note = b"This function is deprecated, use `get_balance_manager_referral_id` instead.")]
public fun get_referral_id(_balance_manager: &BalanceManager): Option<ID> {
    abort
}

/// Get the referral id from the balance manager.
public fun get_balance_manager_referral_id(
    balance_manager: &BalanceManager,
    pool_id: ID,
): Option<ID> {
    let ref_key = ReferralKey(pool_id);
    if (!balance_manager.id.exists_(ref_key)) {
        return option::none()
    };
    let referral_id: &ID = balance_manager.id.borrow(ref_key);

    option::some(*referral_id)
}

public fun validate_proof(balance_manager: &BalanceManager, proof: &TradeProof) {
    assert!(object::id(balance_manager) == proof.balance_manager_id, EInvalidProof);
}

/// Returns the owner of the balance_manager.
public fun owner(balance_manager: &BalanceManager): address {
    balance_manager.owner
}

/// Returns the owner of the balance_manager.
public fun id(balance_manager: &BalanceManager): ID {
    balance_manager.id.to_inner()
}

#[deprecated(note = b"This function is deprecated, use `balance_manager_referral_owner` instead.")]
public fun referral_owner(_referral: &DeepBookReferral): address {
    abort
}

public fun balance_manager_referral_owner(referral: &DeepBookPoolReferral): address {
    referral.owner
}

public fun balance_manager_referral_pool_id(referral: &DeepBookPoolReferral): ID {
    referral.pool_id
}

// === Public-Package Functions ===
/// Mint a `DeepBookReferral` and share it.
public(package) fun mint_referral(pool_id: ID, ctx: &mut TxContext): ID {
    let id = object::new(ctx);
    let referral_id = id.to_inner();
    let referral = DeepBookPoolReferral {
        id,
        owner: ctx.sender(),
        pool_id,
    };

    event::emit(DeepBookReferralCreatedEvent {
        referral_id,
        owner: ctx.sender(),
    });

    transfer::share_object(referral);

    referral_id
}

public(package) fun assert_referral_owner(referral: &DeepBookPoolReferral, ctx: &TxContext) {
    assert!(ctx.sender() == referral.owner, EInvalidReferralOwner);
}

/// Deposit funds to a balance_manager. Pool will call this to deposit funds.
public(package) fun deposit_with_proof<T>(
    balance_manager: &mut BalanceManager,
    proof: &TradeProof,
    to_deposit: Balance<T>,
) {
    balance_manager.validate_proof(proof);

    let key = BalanceKey<T> {};

    if (balance_manager.balances.contains(key)) {
        let balance: &mut Balance<T> = &mut balance_manager.balances[key];
        balance.join(to_deposit);
    } else {
        balance_manager.balances.add(key, to_deposit);
    }
}

/// Deposit funds to a balance_manager. Pool will call this to deposit funds.
/// This function is used by withdraw_settled_amounts_permissionless to deposit funds.
public(package) fun deposit_permissionless<T>(
    balance_manager: &mut BalanceManager,
    to_deposit: Balance<T>,
) {
    let key = BalanceKey<T> {};

    if (balance_manager.balances.contains(key)) {
        let balance: &mut Balance<T> = &mut balance_manager.balances[key];
        balance.join(to_deposit);
    } else {
        balance_manager.balances.add(key, to_deposit);
    }
}

/// Generate a `TradeProof` by a `DepositCap` owner.
public(package) fun generate_proof_as_depositor(
    balance_manager: &BalanceManager,
    deposit_cap: &DepositCap,
    ctx: &TxContext,
): TradeProof {
    balance_manager.validate_deposit_cap(deposit_cap);

    TradeProof {
        balance_manager_id: object::id(balance_manager),
        trader: ctx.sender(),
    }
}

/// Generate a `TradeProof` by a `WithdrawCap` owner.
public(package) fun generate_proof_as_withdrawer(
    balance_manager: &BalanceManager,
    withdraw_cap: &WithdrawCap,
    ctx: &TxContext,
): TradeProof {
    balance_manager.validate_withdraw_cap(withdraw_cap);

    TradeProof {
        balance_manager_id: object::id(balance_manager),
        trader: ctx.sender(),
    }
}

/// Withdraw funds from a balance_manager. Pool will call this to withdraw funds.
public(package) fun withdraw_with_proof<T>(
    balance_manager: &mut BalanceManager,
    proof: &TradeProof,
    withdraw_amount: u64,
    withdraw_all: bool,
): Balance<T> {
    balance_manager.validate_proof(proof);

    let key = BalanceKey<T> {};
    let key_exists = balance_manager.balances.contains(key);
    if (!key_exists) {
        balance_manager.balances.add(key, balance::zero<T>());
    };
    if (withdraw_all) {
        balance_manager.balances.remove(key)
    } else {
        let acc_balance: &mut Balance<T> = &mut balance_manager.balances[key];
        let acc_value = acc_balance.value();
        assert!(acc_value >= withdraw_amount, EBalanceManagerBalanceTooLow);
        if (withdraw_amount == acc_value) {
            balance_manager.balances.remove(key)
        } else {
            acc_balance.split(withdraw_amount)
        }
    }
}

/// Deletes a balance_manager.
/// This is used for deleting temporary balance_managers for direct swap with pool.
public(package) fun delete(balance_manager: BalanceManager) {
    let BalanceManager {
        id,
        owner: _,
        balances,
        allow_listed: _,
    } = balance_manager;

    id.delete();
    balances.destroy_empty();
}

public(package) fun trader(trade_proof: &TradeProof): address {
    trade_proof.trader
}

public(package) fun emit_balance_event(
    balance_manager: &BalanceManager,
    asset: TypeName,
    amount: u64,
    deposit: bool,
) {
    event::emit(BalanceEvent {
        balance_manager_id: balance_manager.id(),
        asset,
        amount,
        deposit,
    });
}

// === Private Functions ===
fun mint_trade_cap_internal(balance_manager: &mut BalanceManager, ctx: &mut TxContext): TradeCap {
    assert!(balance_manager.allow_listed.length() < MAX_TRADE_CAPS, EMaxCapsReached);

    let id = object::new(ctx);
    balance_manager.allow_listed.insert(id.to_inner());

    TradeCap {
        id,
        balance_manager_id: object::id(balance_manager),
    }
}

fun mint_deposit_cap_internal(
    balance_manager: &mut BalanceManager,
    ctx: &mut TxContext,
): DepositCap {
    assert!(balance_manager.allow_listed.length() < MAX_TRADE_CAPS, EMaxCapsReached);

    let id = object::new(ctx);
    balance_manager.allow_listed.insert(id.to_inner());

    DepositCap {
        id,
        balance_manager_id: object::id(balance_manager),
    }
}

fun mint_withdraw_cap_internal(
    balance_manager: &mut BalanceManager,
    ctx: &mut TxContext,
): WithdrawCap {
    assert!(balance_manager.allow_listed.length() < MAX_TRADE_CAPS, EMaxCapsReached);

    let id = object::new(ctx);
    balance_manager.allow_listed.insert(id.to_inner());

    WithdrawCap {
        id,
        balance_manager_id: object::id(balance_manager),
    }
}

fun validate_owner(balance_manager: &BalanceManager, ctx: &TxContext) {
    assert!(ctx.sender() == balance_manager.owner(), EInvalidOwner);
}

fun validate_trader(balance_manager: &BalanceManager, trade_cap: &TradeCap) {
    assert!(balance_manager.allow_listed.contains(object::borrow_id(trade_cap)), EInvalidTrader);
}

fun validate_deposit_cap(balance_manager: &BalanceManager, deposit_cap: &DepositCap) {
    assert!(balance_manager.allow_listed.contains(object::borrow_id(deposit_cap)), EInvalidTrader);
}

fun validate_withdraw_cap(balance_manager: &BalanceManager, withdraw_cap: &WithdrawCap) {
    assert!(balance_manager.allow_listed.contains(object::borrow_id(withdraw_cap)), EInvalidTrader);
}
