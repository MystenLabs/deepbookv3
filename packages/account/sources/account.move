// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A pure, reusable on-chain account: a shared object wrapping a custody
/// `Vault` (`account_core`) with an owner.
///
/// Value moves only against a movement `Proof`, and a `Proof` is minted only by
/// the account's owner — an EOA (`owner = Some(sender)`) via `ctx.sender()`, or a
/// self-owned account (`owner = None`) via its `OwnerCap`. Consumers receive a
/// proof and spend it; they never mint one, so no caller can move an account's
/// value without the owner's authorization. `account_core` is the only place
/// coins move; `account` is the only public surface that mints proofs and moves
/// value. Coin reads include funds delivered to this account's accumulator
/// address, and coin writes first settle those funds into the vault.
///
/// Apps also store opaque per-account state through the app-data lane
/// (`attach` / `borrow_data` / `detach`): a dynamic field namespaced by the app's
/// witness type, so apps cannot collide. Mutations require both the app witness
/// and an owner-minted `Proof`; reads are open.
module account::account;

use account::account_core::{Self, Proof, Vault};
use sui::{accumulator::AccumulatorRoot, balance, coin::Coin, dynamic_field as df};

use fun df::add as UID.add;
use fun df::borrow as UID.borrow;
use fun df::borrow_mut as UID.borrow_mut;
use fun df::exists as UID.exists_;
use fun df::remove as UID.remove;

// === Errors ===
const EInvalidOwner: u64 = 0;
const EInvalidOwnerCap: u64 = 1;

// === Structs ===
/// Shared account: an owner plus a custody `Vault`.
public struct Account has key, store {
    id: UID,
    /// `Some(addr)` => EOA-owned, authority by sender. `None` => self-owned,
    /// authority by `OwnerCap`.
    owner: Option<address>,
    vault: Vault,
}

/// Object form of owner authority for a self-owned account.
public struct OwnerCap has key, store {
    id: UID,
    account_id: ID,
}

/// Dynamic-field key for one app's per-account data slot. The phantom `App` is the
/// app's witness type, so each app gets a distinct, collision-free namespace.
public struct DataKey<phantom App>() has copy, drop, store;

// === Public Functions ===
/// Create an EOA-owned account owned by the transaction sender.
public fun new(ctx: &mut TxContext): Account {
    let id = object::new(ctx);
    let vault = account_core::new_vault(id.to_inner(), ctx);
    Account { id, owner: option::some(ctx.sender()), vault }
}

/// Create a self-owned account (no address owner) and its `OwnerCap`.
public fun new_self_owned(ctx: &mut TxContext): (Account, OwnerCap) {
    let id = object::new(ctx);
    let account_id = id.to_inner();
    let vault = account_core::new_vault(account_id, ctx);
    let account = Account { id, owner: option::none(), vault };
    let cap = OwnerCap { id: object::new(ctx), account_id };

    (account, cap)
}

/// Returns the total balance of `T` available to the account, including funds
/// delivered through the ambient accumulator but not yet settled into the vault.
public fun balance<T>(self: &Account, root: &AccumulatorRoot): u64 {
    self.vault.balance<T>() + balance::settled_funds_value<T>(root, self.id.to_address())
}

/// Returns the account owner: `Some(addr)` for EOA-owned, `None` for self-owned.
public fun owner(self: &Account): Option<address> {
    self.owner
}

/// Returns the account object id.
public fun id(self: &Account): ID {
    self.id.to_inner()
}

/// Mint a movement proof as the EOA owner.
public fun generate_proof_as_owner(self: &Account, ctx: &TxContext): Proof {
    self.assert_owner(ctx);
    self.vault.issue_proof()
}

/// Mint a movement proof for a self-owned account with its `OwnerCap`.
public fun generate_proof_with_owner_cap(self: &Account, cap: &OwnerCap): Proof {
    self.assert_owner_cap(cap);
    self.vault.issue_proof()
}

/// Abort unless `proof` was minted for this account. This is the kernel's
/// per-movement binding check (`account_core::assert_bound`) surfaced for
/// owner-gated actions that move no value: a `Proof` is the single "may mutate this
/// account" authority — minted only by the owner — so it gates value movement and
/// owner-gated state (e.g. app config) with one check.
public fun assert_proof(self: &Account, proof: &Proof) {
    self.vault.assert_bound(proof);
}

/// Deposit `coin`. Requires a movement `Proof` and first settles any accumulator
/// funds for `T` into the vault. The proof is taken by reference so one proof can
/// fund many movements in a PTB.
public fun deposit<T>(self: &mut Account, proof: &Proof, root: &AccumulatorRoot, coin: Coin<T>) {
    self.settle<T>(proof, root);
    self.vault.deposit_with_proof(proof, coin.into_balance());
}

/// Withdraw `amount` of `T`. Requires a movement `Proof` and first settles any
/// accumulator funds for `T` into the vault.
public fun withdraw<T>(
    self: &mut Account,
    proof: &Proof,
    root: &AccumulatorRoot,
    amount: u64,
    ctx: &mut TxContext,
): Coin<T> {
    self.settle<T>(proof, root);
    self.vault.withdraw_with_proof<T>(proof, amount).into_coin(ctx)
}

/// Settle any accumulator-delivered funds for `T` into the vault.
public fun settle<T>(self: &mut Account, proof: &Proof, root: &AccumulatorRoot) {
    let amount = balance::settled_funds_value<T>(root, self.id.to_address());
    if (amount == 0) return;
    let withdrawal = balance::withdraw_funds_from_object<T>(&mut self.id, amount);
    self.vault.deposit_with_proof(proof, balance::redeem_funds(withdrawal));
}

// === App-data Lane ===
/// Attach an app's `Data` under its witness namespace. Requires a movement
/// `Proof` and an app witness. Aborts if `App` already has data attached.
public fun attach<App: drop, Data: store>(
    self: &mut Account,
    proof: &Proof,
    _app: App,
    data: Data,
) {
    self.assert_proof(proof);
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

/// Mutably borrow an app's attached `Data`. Requires a movement `Proof` and an
/// app witness. Aborts if nothing is attached.
public fun borrow_data_mut<App: drop, Data: store>(
    self: &mut Account,
    proof: &Proof,
    _app: App,
): &mut Data {
    self.assert_proof(proof);
    self.id.borrow_mut(DataKey<App>())
}

/// Detach and return an app's `Data`. Requires a movement `Proof` and an app
/// witness. Aborts if nothing is attached.
public fun detach<App: drop, Data: store>(self: &mut Account, proof: &Proof, _app: App): Data {
    self.assert_proof(proof);
    self.id.remove(DataKey<App>())
}

// === Private Functions ===
fun assert_owner(self: &Account, ctx: &TxContext) {
    assert!(self.owner.contains(&ctx.sender()), EInvalidOwner);
}

fun assert_owner_cap(self: &Account, cap: &OwnerCap) {
    assert!(cap.account_id == self.id.to_inner(), EInvalidOwnerCap);
}
