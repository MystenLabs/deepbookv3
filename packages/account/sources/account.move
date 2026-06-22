// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A pure, reusable on-chain account: a shared wrapper owns the account data and
/// controls who can borrow it mutably.
///
/// Owner, object-owner, and app flows consume an `Auth` hot potato to load
/// `&mut Account` from the wrapper. Once a caller has a mutable account reference,
/// value movement needs no extra proof: the borrow itself is the authority
/// boundary. Coin reads include funds delivered to this account's accumulator
/// address, and coin writes first settle those funds into the account.
///
/// Apps also store opaque per-account state through the app-data lane
/// (`attach` / `borrow_data` / `detach`): a dynamic field namespaced by the app's
/// witness type, so apps cannot collide. Mutations require `Permit<App>`; reads
/// are open.
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
const AUTH_OWNER: u8 = 0;
const AUTH_APP: u8 = 1;

// === Structs ===
/// Shared account wrapper: owner-gated shell around the reusable account state.
public struct AccountWrapper has key {
    id: UID,
    account: Account,
}

/// Wrapped account state and custody. Its ID is the canonical account identity,
/// receive address, and app-data storage root.
public struct Account has store {
    account_id: UID,
    /// EOA address or object-ID-as-address that owns this account.
    owner: address,
    /// The wrapper object's address: the accumulator/funds-receive anchor. Funds are
    /// delivered here and settled out via `&mut AccountWrapper.id` — a real shared
    /// object the runtime can authenticate, unlike the nested `account_id` UID, which
    /// can never back an address-balance withdrawal.
    receive_address: address,
    balances: Bag,
    settlements: Bag,
}

/// Dynamic-field key for one app's per-account data slot. The phantom `App` is the
/// app's witness type, so each app gets a distinct, collision-free namespace.
public struct DataKey<phantom App>() has copy, drop, store;

/// Per-coin bag key.
public struct CoinKey<phantom T> has copy, drop, store {}

/// Hot-potato authority to mutably open an `AccountWrapper`.
public struct Auth {
    kind: u8,
    owner: address,
}

// === Public Functions ===
/// Share a newly created account object.
public fun share(self: AccountWrapper) {
    transfer::share_object(self);
}

/// Returns the wrapper object ID.
public fun id(self: &AccountWrapper): ID {
    self.id.to_inner()
}

/// Generate owner authority from the transaction sender.
public fun generate_auth(ctx: &TxContext): Auth {
    Auth { kind: AUTH_OWNER, owner: ctx.sender() }
}

/// Generate owner authority from an owning object's UID.
public fun generate_auth_as_object(uid: &mut UID): Auth {
    Auth { kind: AUTH_OWNER, owner: uid.to_inner().to_address() }
}

/// Borrow the wrapped account for read-only use.
public fun load_account(self: &AccountWrapper): &Account {
    &self.account
}

/// Borrow the wrapped account mutably by consuming an `Auth` hot potato.
public fun load_account_mut(self: &mut AccountWrapper, auth: Auth): &mut Account {
    let Auth { kind, owner } = auth;
    if (kind == AUTH_OWNER) {
        self.assert_owner(owner);
    } else {
        assert!(kind == AUTH_APP, EInvalidAuth);
    };
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

/// Returns the canonical account ID.
public fun account_id(self: &Account): ID {
    self.account_id.to_inner()
}

/// Returns the accumulator receive address for this account (the wrapper address).
public fun receive_address(self: &Account): address {
    self.receive_address
}

/// Fold any accumulator-delivered funds for `T` (sent to this account's receive
/// address) into stored balance. Withdrawing the address balance uses `&mut wrapper.id`
/// — a real shared object the runtime authenticates as a transaction input. Each
/// public flow that touches `T` settles at its boundary, where the wrapper is in
/// scope, so the deep `&mut Account` custody ops below stay pure stored-balance.
///
/// Permissionless: it only consolidates the account's own funds and moves nothing out,
/// so it needs no `Auth`; pulling funds out still requires `load_account_mut(auth)`.
public fun settle<T>(wrapper: &mut AccountWrapper, root: &AccumulatorRoot, clock: &Clock) {
    let now = clock.timestamp_ms();
    if (now == wrapper.account.last_settlement_ms<T>()) return;
    wrapper.account.set_last_settlement_ms<T>(now);

    let amount = balance::settled_funds_value<T>(root, wrapper.id.to_address());
    if (amount == 0) return;
    let withdrawal = balance::withdraw_funds_from_object<T>(&mut wrapper.id, amount);
    wrapper.account.deposit_balance(balance::redeem_funds(withdrawal));
    // NOTE(barrier): a nonzero settlement needs barrier-delivered funds, which has no
    // Move test seam — covered by the localnet simulation, see ACCUMULATOR_TESTING_STATUS.md.
    account_events::emit_funds_settled(
        wrapper.account.account_id(),
        type_name::with_defining_ids<T>().into_string(),
        amount,
        wrapper.account.stored_balance<T>(),
    );
}

/// Deposit `coin` into the wrapped account's stored `T` balance. Pure stored-balance:
/// callers settle accumulator funds at the flow boundary via `settle` (the deep
/// `&mut Account` here cannot reach the wrapper id needed to authenticate a settle).
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

/// Withdraw `amount` of `T` from stored balance. Pure stored-balance (see `deposit`):
/// callers settle accumulator funds at the flow boundary via `settle` first.
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

/// Deposit `coin` into the wrapped account's stored `T` balance from a transaction.
/// `deposit` borrows `&mut Account`, which a PTB cannot carry across commands out of
/// `load_account_mut`, so this folds settle → authorize → load → deposit into one
/// entrypoint (the same shape predict's `mint`/`redeem` use for account-authorized flows).
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

/// PTB-callable withdraw: folds settle → authorize → load → withdraw into one
/// entrypoint (see `deposit_funds`).
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
/// Create an account from the registry derivation root. The UID is claimed here
/// because Sui requires key objects to be built in the same function that obtains
/// their fresh UID.
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

/// Mint app authority after the registry has checked its app whitelist.
public(package) fun new_app_auth(): Auth {
    Auth { kind: AUTH_APP, owner: @0x0 }
}

// === Private Functions ===
fun assert_owner(self: &AccountWrapper, owner: address) {
    assert!(owner == self.account.owner, EInvalidOwner);
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
        balance::settled_funds_value<T>(root, self.receive_address)
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
