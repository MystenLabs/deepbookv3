// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Shared registry for canonical account creation.
///
/// The registry owns the derivation root and controls the ecosystem app
/// whitelist. `account::account` owns deterministic account address derivation,
/// account construction, custody, proof, settlement, and app-data invariants.
module account::account_registry;

use account::account::{Self, Account, Proof};
use std::internal::Permit;
use sui::{derived_object, dynamic_field as df};

use fun df::add as UID.add;
use fun df::exists as UID.exists_;
use fun df::remove as UID.remove;

// === Errors ===
const EAppAlreadyAuthorized: u64 = 0;
const EAppNotAuthorized: u64 = 1;
const EAccountAlreadyExists: u64 = 2;

/// Administrative authority over the account registry.
public struct AccountAdminCap has key, store {
    id: UID,
}

/// Shared derivation root for canonical user accounts.
public struct AccountRegistry has key {
    id: UID,
}

/// Canonical account derivation key: one account per owner address under this
/// registry root.
public struct AccountKey(address) has copy, drop, store;

/// Dynamic-field key recording that `App` is authorized to mint account proofs.
public struct AppKey<phantom App>() has copy, drop, store;

fun init(ctx: &mut TxContext) {
    transfer::share_object(AccountRegistry { id: object::new(ctx) });
    transfer::public_transfer(AccountAdminCap { id: object::new(ctx) }, ctx.sender());
}

// === Public Functions ===
/// Return the deterministic account address for `owner` under this registry.
public fun derived_address(registry: &AccountRegistry, owner: address): address {
    derived_object::derive_address(registry.id.to_inner(), AccountKey(owner))
}

/// Return the deterministic account ID for `owner` under this registry.
public fun derived_id(registry: &AccountRegistry, owner: address): ID {
    registry.derived_address(owner).to_id()
}

/// Return whether the derived account has already been claimed.
public fun derived_exists(registry: &AccountRegistry, owner: address): bool {
    derived_object::exists(&registry.id, AccountKey(owner))
}

/// Create the sender's canonical derived account.
public fun new(registry: &mut AccountRegistry, ctx: &mut TxContext): Account {
    let owner = ctx.sender();
    registry.assert_account_does_not_exist(owner);
    account::new_derived(&mut registry.id, AccountKey(owner), owner, ctx)
}

/// Create the canonical derived account owned by `owner_uid`'s object address.
public fun new_self_owned(
    registry: &mut AccountRegistry,
    owner_uid: &mut UID,
    ctx: &mut TxContext,
): Account {
    let owner = owner_uid.to_inner().to_address();
    registry.assert_account_does_not_exist(owner);
    account::new_derived(&mut registry.id, AccountKey(owner), owner, ctx)
}

/// Return whether `App` is authorized for app-driven account proof minting.
public fun is_app_authorized<App>(registry: &AccountRegistry): bool {
    registry.id.exists_(AppKey<App>())
}

/// Authorize `App` to mint movement proofs for any account through this registry.
public fun authorize_app<App>(registry: &mut AccountRegistry, _cap: &AccountAdminCap) {
    assert!(!registry.is_app_authorized<App>(), EAppAlreadyAuthorized);
    registry.id.add(AppKey<App>(), true);
}

/// Remove `App` from the app proof-minting whitelist.
public fun deauthorize_app<App>(registry: &mut AccountRegistry, _cap: &AccountAdminCap) {
    registry.assert_app_is_authorized<App>();
    let _authorized: bool = registry.id.remove(AppKey<App>());
}

/// Assert that `App` is authorized for app-driven account proof minting.
public fun assert_app_is_authorized<App>(registry: &AccountRegistry) {
    assert!(registry.is_app_authorized<App>(), EAppNotAuthorized);
}

/// Mint a movement proof for a whitelisted app. The `Permit<App>` proves the
/// caller is the module defining `App`; the registry whitelist decides whether
/// that app has ecosystem account authority.
public fun generate_proof_as_app<App>(
    registry: &AccountRegistry,
    account: &Account,
    _permit: Permit<App>,
): Proof {
    registry.assert_app_is_authorized<App>();
    account.issue_proof_unchecked()
}

// === Private Functions ===
fun assert_account_does_not_exist(registry: &AccountRegistry, owner: address) {
    assert!(!registry.derived_exists(owner), EAccountAlreadyExists);
}
