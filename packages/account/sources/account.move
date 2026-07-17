// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Owns shared account wrappers, typed coin custody, accumulator settlement, and application-scoped data.
/// Consuming `Auth` is the mutable-borrow boundary: owner auth is checked against the account, while package-issued app auth yields the same full `&mut Account` and is not bound to an owner or operation.
/// The wrapper address receives accumulator funds; a distinct derived account UID identifies the account and anchors app data, while typed balances remain embedded in the account.
/// App data is namespaced by witness type, requires `Permit<App>` to mutate, and remains publicly readable.
module account::account;

use account::account_events;
use std::{internal::Permit, type_name};
use sui::{
    accumulator::AccumulatorRoot,
    bag::{Self, Bag},
    balance::{Self, Balance},
    clock::Clock,
    coin::Coin,
    derived_object,
    dynamic_field as df
};

use fun df::add as UID.add;
use fun df::borrow as UID.borrow;
use fun df::borrow_mut as UID.borrow_mut;
use fun df::exists as UID.exists_;
use fun df::remove as UID.remove;

// === Errors ===
const EInvalidOwner: u64 = 0;
const EBalanceTooLow: u64 = 1;
const EInvalidAuth: u64 = 2;

// === Auth Kinds ===
const AUTH_OWNER: u8 = 0;
const AUTH_APP: u8 = 1;

// === Structs ===
/// Addressable shell that receives accumulator funds and gates mutable access to the embedded account.
public struct AccountWrapper has key {
    id: UID,
    account: Account,
}

/// Account state and custody; `account_id` is the canonical identity and app-data root, while `receive_address` is the wrapper address used for accumulator delivery.
public struct Account has store {
    /// Dynamic-field parent for account-owned application data.
    account_id: UID,
    /// EOA address or object-ID-as-address that owns this account.
    owner: address,
    /// Wrapper-object address used as the accumulator delivery and withdrawal anchor.
    receive_address: address,
    /// Type-indexed stored `Balance<T>` values.
    balances: Bag,
    /// Type-indexed timestamps of the latest settlement attempt.
    settlements: Bag,
}

/// Dynamic-field key for one app's per-account data slot. The phantom `App` is the
/// app's witness type, so each app gets a distinct, collision-free namespace.
public struct DataKey<phantom App>() has copy, drop, store;

/// Per-coin bag key.
public struct CoinKey<phantom T>() has copy, drop, store;

/// Single-use authority to mutably open an `AccountWrapper` as its owner or as an authorized app.
public struct Auth {
    kind: u8,
    owner: address,
}

// === Public Functions ===
/// Returns the wrapper object ID.
public fun id(self: &AccountWrapper): ID {
    self.id.to_inner()
}

/// Borrows the wrapped account for read-only composition.
public fun load_account(self: &AccountWrapper): &Account {
    &self.account
}

/// Returns the total balance of `T` available to the account, including funds
/// delivered through the ambient accumulator but not yet settled into the account.
public fun balance<T>(self: &Account, root: &AccumulatorRoot, clock: &Clock): u64 {
    self.stored_balance<T>() + self.unsettled_balance<T>(root, clock)
}

/// Returns the account owner address. This may be an EOA address or an
/// object-ID-as-address.
public fun owner(self: &Account): address {
    self.owner
}

/// Returns the canonical account ID.
public fun account_id(self: &Account): ID {
    self.account_id.to_inner()
}

/// Returns the accumulator receive address for this account (the wrapper address).
public fun receive_address(self: &Account): address {
    self.receive_address
}

/// Creates owner authority bound to the transaction sender.
public fun generate_auth(ctx: &mut TxContext): Auth {
    Auth { kind: AUTH_OWNER, owner: ctx.sender() }
}

/// Creates owner authority bound to an owning object's address.
public fun generate_auth_as_object(uid: &mut UID): Auth {
    Auth { kind: AUTH_OWNER, owner: uid.to_inner().to_address() }
}

/// Shares a newly created account wrapper.
public fun share(self: AccountWrapper) {
    transfer::share_object(self);
}

/// Consumes owner or app authority and returns the account's full mutable surface.
/// Owner authority must match the stored owner; app authority is package-issued after registry authorization and carries no owner or operation restriction.
public fun load_account_mut(self: &mut AccountWrapper, auth: Auth): &mut Account {
    let Auth { kind, owner } = auth;
    if (kind == AUTH_OWNER) {
        self.assert_owner(owner);
    } else {
        assert!(kind == AUTH_APP, EInvalidAuth);
    };
    &mut self.account
}

/// Permissionlessly folds accumulator-delivered `T` at the wrapper address into stored account balance.
/// The per-coin timestamp is latched before reading the accumulator, preventing duplicate withdrawal and same-timestamp double counting even when no funds are available.
/// Only the wrapper UID can authenticate the address-balance withdrawal; value leaving the account still requires a mutable borrow through `Auth`.
public fun settle<T>(wrapper: &mut AccountWrapper, root: &AccumulatorRoot, clock: &Clock) {
    if (wrapper.account.settled_this_timestamp<T>(clock)) return;
    let now = clock.timestamp_ms();
    wrapper.account.set_last_settlement_ms<T>(now);

    let amount = balance::settled_funds_value<T>(root, wrapper.id.to_address());
    if (amount == 0) return;
    let withdrawal = balance::withdraw_funds_from_object<T>(&mut wrapper.id, amount);
    wrapper.account.deposit_balance(balance::redeem_funds(withdrawal));
    account_events::emit_funds_settled(
        wrapper.account.account_id(),
        type_name::with_defining_ids<T>().into_string(),
        amount,
        wrapper.account.stored_balance<T>(),
    );
}

/// Deposits into stored balance only; callers that include accumulator funds must settle through the wrapper first.
public fun deposit<T>(self: &mut Account, coin: Coin<T>) {
    let amount = coin.value();
    self.deposit_balance(coin.into_balance());
    account_events::emit_deposited(
        self.account_id(),
        type_name::with_defining_ids<T>().into_string(),
        amount,
        self.stored_balance<T>(),
    );
}

/// Withdraws from stored balance only; callers that include accumulator funds must settle through the wrapper first.
public fun withdraw<T>(self: &mut Account, amount: u64, ctx: &mut TxContext): Coin<T> {
    let coin = self.withdraw_balance<T>(amount).into_coin(ctx);
    account_events::emit_withdrawn(
        self.account_id(),
        type_name::with_defining_ids<T>().into_string(),
        amount,
        self.stored_balance<T>(),
    );
    coin
}

/// PTB entrypoint that settles accumulator funds, consumes authority, and deposits into stored balance in one call.
public fun deposit_funds<T>(
    wrapper: &mut AccountWrapper,
    auth: Auth,
    coin: Coin<T>,
    root: &AccumulatorRoot,
    clock: &Clock,
) {
    wrapper.settle<T>(root, clock);
    wrapper.load_account_mut(auth).deposit(coin);
}

/// PTB entrypoint that settles accumulator funds, consumes authority, and withdraws from stored balance in one call.
public fun withdraw_funds<T>(
    wrapper: &mut AccountWrapper,
    auth: Auth,
    amount: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<T> {
    wrapper.settle<T>(root, clock);
    wrapper.load_account_mut(auth).withdraw<T>(amount, ctx)
}

// === App-data Lane ===
/// Attach an app's `Data` under its witness namespace. Requires `Permit<App>`.
/// Aborts if `App` already has data attached.
public fun attach<App, Data: store>(self: &mut Account, _permit: Permit<App>, data: Data) {
    self.account_id.add(DataKey<App>(), data);
}

/// Whether `App` has data attached to this account.
public fun has_data<App>(self: &Account): bool {
    self.account_id.exists_(DataKey<App>())
}

/// Borrow an app's attached `Data`. Open (no witness): the slot is namespaced by
/// `App` and on-chain state is public, so composing apps can read it. Aborts if
/// nothing is attached.
public fun borrow_data<App, Data: store>(self: &Account): &Data {
    self.account_id.borrow(DataKey<App>())
}

/// Mutably borrow an app's attached `Data`. Requires `Permit<App>`. Aborts if
/// nothing is attached.
public fun borrow_data_mut<App, Data: store>(self: &mut Account, _permit: Permit<App>): &mut Data {
    self.account_id.borrow_mut(DataKey<App>())
}

/// Detach and return an app's `Data`. Requires `Permit<App>`. Aborts if
/// nothing is attached.
public fun detach<App, Data: store>(self: &mut Account, _permit: Permit<App>): Data {
    self.account_id.remove(DataKey<App>())
}

// === Public-Package Functions ===
/// Claims distinct wrapper and account UIDs from the registry root and constructs the wrapper where the derived key-object UIDs are obtained.
public(package) fun new_derived<WrapperKey: copy + drop + store, AccountKey: copy + drop + store>(
    parent: &mut UID,
    wrapper_key: WrapperKey,
    account_key: AccountKey,
    owner: address,
    ctx: &mut TxContext,
): AccountWrapper {
    let id = derived_object::claim(parent, wrapper_key);
    let account_id = derived_object::claim(parent, account_key);
    AccountWrapper {
        account: Account {
            account_id,
            owner,
            receive_address: id.to_address(),
            balances: bag::new(ctx),
            settlements: bag::new(ctx),
        },
        id,
    }
}

/// Constructs app authority for the package-level caller that owns the registry authorization check.
public(package) fun new_app_auth(): Auth {
    Auth { kind: AUTH_APP, owner: @0x0 }
}

// === Private Functions ===
fun assert_owner(self: &AccountWrapper, owner: address) {
    assert!(owner == self.account.owner, EInvalidOwner);
}

fun stored_balance<T>(self: &Account): u64 {
    let key = CoinKey<T>();
    if (self.balances.contains(key)) {
        let bal: &Balance<T> = &self.balances[key];
        bal.value()
    } else {
        0
    }
}

fun unsettled_balance<T>(self: &Account, root: &AccumulatorRoot, clock: &Clock): u64 {
    if (self.settled_this_timestamp<T>(clock)) {
        0
    } else {
        balance::settled_funds_value<T>(root, self.receive_address)
    }
}

/// The settlement timestamp is both the duplicate-withdraw latch and the read-side
/// accumulator suppression. `settled_funds_value` observes beginning-of-commit
/// funds, so same-timestamp balance reads after `settle` must not add that
/// accumulator view on top of the newly stored balance.
fun settled_this_timestamp<T>(self: &Account, clock: &Clock): bool {
    clock.timestamp_ms() == self.last_settlement_ms<T>()
}

fun last_settlement_ms<T>(self: &Account): u64 {
    let key = CoinKey<T>();
    if (self.settlements.contains(key)) {
        let timestamp: &u64 = &self.settlements[key];
        *timestamp
    } else {
        0
    }
}

fun set_last_settlement_ms<T>(self: &mut Account, timestamp: u64) {
    let key = CoinKey<T>();
    if (self.settlements.contains(key)) {
        let last_settlement_ms: &mut u64 = &mut self.settlements[key];
        *last_settlement_ms = timestamp;
    } else {
        self.settlements.add(key, timestamp);
    }
}

fun deposit_balance<T>(self: &mut Account, balance: Balance<T>) {
    let key = CoinKey<T>();
    if (self.balances.contains(key)) {
        let bal: &mut Balance<T> = &mut self.balances[key];
        bal.join(balance);
    } else {
        self.balances.add(key, balance);
    }
}

fun withdraw_balance<T>(self: &mut Account, amount: u64): Balance<T> {
    let key = CoinKey<T>();
    assert!(self.balances.contains(key), EBalanceTooLow);
    let bal: &mut Balance<T> = &mut self.balances[key];
    assert!(bal.value() >= amount, EBalanceTooLow);
    if (bal.value() == amount) {
        self.balances.remove(key)
    } else {
        bal.split(amount)
    }
}
