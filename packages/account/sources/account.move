// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A pure, reusable on-chain account: a shared wrapper owns the account data and
/// controls who can borrow it mutably.
///
/// Owner and object-owner flows load `&mut Account` through this module. App flows
/// load it through `account_registry`, which checks the app whitelist. Once a
/// caller has a mutable account reference, value movement needs no extra proof:
/// the borrow itself is the authority boundary. Coin reads include funds
/// delivered to this account's accumulator address, and coin writes first settle
/// those funds into the account.
///
/// Apps also store opaque per-account state through the app-data lane
/// (`attach` / `borrow_data` / `detach`): a dynamic field namespaced by the app's
/// witness type, so apps cannot collide. Mutations require `Permit<App>`; reads
/// are open.
module account::account;

use std::internal::Permit;
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
const EProofAccountMismatch: u64 = 1;
const EBalanceTooLow: u64 = 2;

// === Structs ===
/// Shared account wrapper: owner-gated shell around the reusable account state.
public struct AccountWrapper has key {
    id: UID,
    /// EOA address or object-ID-as-address that owns this account.
    owner: address,
    account: Account,
}

/// Wrapped account state and custody.
public struct Account has key, store {
    id: UID,
    /// EOA address or object-ID-as-address that owns this account.
    owner: address,
    balances: Bag,
    settlements: Bag,
}

/// Dynamic-field key for one app's per-account data slot. The phantom `App` is the
/// app's witness type, so each app gets a distinct, collision-free namespace.
public struct DataKey<phantom App>() has copy, drop, store;

/// Per-coin bag key.
public struct CoinKey<phantom T> has copy, drop, store {}

// === Public Functions ===
/// Share a newly created account object.
public fun share(self: AccountWrapper) {
    transfer::share_object(self);
}

/// Borrow the wrapped account for read-only use.
public fun load_account(self: &AccountWrapper): &Account {
    &self.account
}

/// Borrow the wrapped account mutably after validating the transaction sender owns it.
public fun load_account_mut(self: &mut AccountWrapper, ctx: &TxContext): &mut Account {
    self.assert_owner(ctx.sender());
    &mut self.account
}

/// Borrow the wrapped account mutably after validating `uid` owns it.
/// The mutable UID borrow proves the caller is executing through the owning
/// object's module.
public fun load_account_mut_as_object(self: &mut AccountWrapper, uid: &mut UID): &mut Account {
    self.assert_owner(uid.to_inner().to_address());
    &mut self.account
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

/// Returns the account object id.
public fun id(self: &Account): ID {
    self.id.to_inner()
}

/// Returns the accumulator receive address for this account.
public fun receive_address(self: &Account): address {
    self.id.to_address()
}

/// Deposit `coin` and first settle any accumulator funds for `T` into the account.
public fun deposit<T>(self: &mut Account, coin: Coin<T>, root: &AccumulatorRoot, clock: &Clock) {
    self.settle_unchecked<T>(root, clock);
    self.deposit_balance(coin.into_balance());
}

/// Withdraw `amount` of `T` and first settle any accumulator funds for `T`.
public fun withdraw<T>(
    self: &mut Account,
    amount: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<T> {
    self.settle_unchecked<T>(root, clock);
    self.withdraw_balance<T>(amount).into_coin(ctx)
}

// === App-data Lane ===
/// Attach an app's `Data` under its witness namespace. Requires `Permit<App>`.
/// Aborts if `App` already has data attached.
public fun attach<App, Data: store>(self: &mut Account, _permit: Permit<App>, data: Data) {
    self.id.add(DataKey<App>(), data);
}

/// Whether `App` has data attached to this account.
public fun has_data<App>(self: &Account): bool {
    self.id.exists_(DataKey<App>())
}

/// Borrow an app's attached `Data`. Open (no witness): the slot is namespaced by
/// `App` and on-chain state is public, so composing apps can read it. Aborts if
/// nothing is attached.
public fun borrow_data<App, Data: store>(self: &Account): &Data {
    self.id.borrow(DataKey<App>())
}

/// Mutably borrow an app's attached `Data`. Requires `Permit<App>`. Aborts if
/// nothing is attached.
public fun borrow_data_mut<App, Data: store>(self: &mut Account, _permit: Permit<App>): &mut Data {
    self.id.borrow_mut(DataKey<App>())
}

/// Detach and return an app's `Data`. Requires `Permit<App>`. Aborts if
/// nothing is attached.
public fun detach<App, Data: store>(self: &mut Account, _permit: Permit<App>): Data {
    self.id.remove(DataKey<App>())
}

// === Public-Package Functions ===
/// Create an account from the registry derivation root. The UID is claimed here
/// because Sui requires key objects to be built in the same function that obtains
/// their fresh UID.
public(package) fun new_derived<K: copy + drop + store>(
    parent: &mut UID,
    key: K,
    owner: address,
    ctx: &mut TxContext,
): AccountWrapper {
    let id = derived_object::claim(parent, key);
    AccountWrapper {
        id,
        owner,
        account: Account {
            id: object::new(ctx),
            owner,
            balances: bag::new(ctx),
            settlements: bag::new(ctx),
        },
    }
}

/// Borrow the wrapped account after a package-level caller has checked authority.
public(package) fun load_account_mut_unchecked(self: &mut AccountWrapper): &mut Account {
    &mut self.account
}

// === Private Functions ===
/// Settle any accumulator-delivered funds for `T` into the account. The caller
/// must have already validated authority.
fun settle_unchecked<T>(self: &mut Account, root: &AccumulatorRoot, clock: &Clock) {
    let now = clock.timestamp_ms();
    if (now == self.last_settlement_ms<T>()) return;
    self.set_last_settlement_ms<T>(now);

    let amount = balance::settled_funds_value<T>(root, self.id.to_address());
    if (amount == 0) return;
    let withdrawal = balance::withdraw_funds_from_object<T>(&mut self.id, amount);
    self.deposit_balance(balance::redeem_funds(withdrawal));
}

fun assert_owner(self: &AccountWrapper, owner: address) {
    assert!(owner == self.owner, EInvalidOwner);
}

fun stored_balance<T>(self: &Account): u64 {
    let key = CoinKey<T> {};
    if (self.balances.contains(key)) {
        let bal: &Balance<T> = &self.balances[key];
        bal.value()
    } else {
        0
    }
}

fun unsettled_balance<T>(self: &Account, root: &AccumulatorRoot, clock: &Clock): u64 {
    if (clock.timestamp_ms() == self.last_settlement_ms<T>()) {
        0
    } else {
        balance::settled_funds_value<T>(root, self.id.to_address())
    }
}

fun last_settlement_ms<T>(self: &Account): u64 {
    let key = CoinKey<T> {};
    if (self.settlements.contains(key)) {
        let timestamp: &u64 = &self.settlements[key];
        *timestamp
    } else {
        0
    }
}

fun set_last_settlement_ms<T>(self: &mut Account, timestamp: u64) {
    let key = CoinKey<T> {};
    if (self.settlements.contains(key)) {
        let last_settlement_ms: &mut u64 = &mut self.settlements[key];
        *last_settlement_ms = timestamp;
    } else {
        self.settlements.add(key, timestamp);
    }
}

fun deposit_balance<T>(self: &mut Account, balance: Balance<T>) {
    let key = CoinKey<T> {};
    if (self.balances.contains(key)) {
        let bal: &mut Balance<T> = &mut self.balances[key];
        bal.join(balance);
    } else {
        self.balances.add(key, balance);
    }
}

fun withdraw_balance<T>(self: &mut Account, amount: u64): Balance<T> {
    let key = CoinKey<T> {};
    assert!(self.balances.contains(key), EBalanceTooLow);
    let bal: &mut Balance<T> = &mut self.balances[key];
    assert!(bal.value() >= amount, EBalanceTooLow);
    if (bal.value() == amount) {
        self.balances.remove(key)
    } else {
        bal.split(amount)
    }
}
