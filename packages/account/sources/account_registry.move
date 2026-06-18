// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Shared registry for canonical account creation.
///
/// The registry owns the derivation root and controls the ecosystem app
/// whitelist. `account::account` owns deterministic wrapper derivation, account
/// construction, custody, settlement, and app-data invariants.
module account::account_registry;

use account::account::{Self, AccountWrapper, Auth};
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
/// registry root. This derived ID is used for app data, funds settlement, and events.
public struct AccountKey(address) has copy, drop, store;

/// Derived wrapper object key for the shared object that gates mutable account borrows.
public struct AccountWrapperKey(address) has copy, drop, store;

/// Dynamic-field key recording that `App` is authorized to generate app auth.
public struct AppKey<phantom App>() has copy, drop, store;

fun init(ctx: &mut TxContext) {
    transfer::share_object(AccountRegistry { id: object::new(ctx) });
    transfer::public_transfer(AccountAdminCap { id: object::new(ctx) }, ctx.sender());
}

// === Public Functions ===
/// Return the deterministic canonical account address for `owner` under this registry.
public fun derived_address(registry: &AccountRegistry, owner: address): address {
    derived_object::derive_address(registry.id.to_inner(), AccountKey(owner))
}

/// Return the deterministic canonical account ID for `owner` under this registry.
public fun derived_id(registry: &AccountRegistry, owner: address): ID {
    registry.derived_address(owner).to_id()
}

/// Return the deterministic account wrapper address for `owner` under this registry.
public fun derived_wrapper_address(registry: &AccountRegistry, owner: address): address {
    derived_object::derive_address(registry.id.to_inner(), AccountWrapperKey(owner))
}

/// Return the deterministic account wrapper ID for `owner` under this registry.
public fun derived_wrapper_id(registry: &AccountRegistry, owner: address): ID {
    registry.derived_wrapper_address(owner).to_id()
}

/// Return whether the canonical derived account has already been claimed.
public fun derived_exists(registry: &AccountRegistry, owner: address): bool {
    derived_object::exists(&registry.id, AccountKey(owner))
}

/// Return whether the derived account wrapper has already been claimed.
public fun derived_wrapper_exists(registry: &AccountRegistry, owner: address): bool {
    derived_object::exists(&registry.id, AccountWrapperKey(owner))
}

/// Create the sender's canonical derived account wrapper.
public fun new(registry: &mut AccountRegistry, ctx: &mut TxContext): AccountWrapper {
    let owner = ctx.sender();
    registry.assert_account_does_not_exist(owner);
    account::new_derived(
        &mut registry.id,
        AccountWrapperKey(owner),
        AccountKey(owner),
        owner,
        ctx,
    )
}

/// Create the canonical derived account wrapper owned by `owner_uid`'s object address.
public fun new_self_owned(
    registry: &mut AccountRegistry,
    owner_uid: &mut UID,
    ctx: &mut TxContext,
): AccountWrapper {
    let owner = owner_uid.to_inner().to_address();
    registry.assert_account_does_not_exist(owner);
    account::new_derived(
        &mut registry.id,
        AccountWrapperKey(owner),
        AccountKey(owner),
        owner,
        ctx,
    )
}

/// Return whether `App` is authorized for app-driven account access.
public fun is_app_authorized<App>(registry: &AccountRegistry): bool {
    registry.id.exists_(AppKey<App>())
}

/// Authorize `App` to generate app auth through this registry.
public fun authorize_app<App>(registry: &mut AccountRegistry, _cap: &AccountAdminCap) {
    assert!(!registry.is_app_authorized<App>(), EAppAlreadyAuthorized);
    registry.id.add(AppKey<App>(), true);
}

/// Remove `App` from the app account-loading whitelist.
public fun deauthorize_app<App>(registry: &mut AccountRegistry, _cap: &AccountAdminCap) {
    registry.assert_app_is_authorized<App>();
    let _authorized: bool = registry.id.remove(AppKey<App>());
}

/// Assert that `App` is authorized for app-driven account access.
public fun assert_app_is_authorized<App>(registry: &AccountRegistry) {
    assert!(registry.is_app_authorized<App>(), EAppNotAuthorized);
}

/// Generate app authority after checking the registry whitelist. The
/// `Permit<App>` proves the caller is the module defining `App`.
public fun generate_auth_as_app<App>(registry: &AccountRegistry, _permit: Permit<App>): Auth {
    registry.assert_app_is_authorized<App>();
    account::new_app_auth()
}

// === Private Functions ===
fun assert_account_does_not_exist(registry: &AccountRegistry, owner: address) {
    assert!(
        !registry.derived_exists(owner) && !registry.derived_wrapper_exists(owner),
        EAccountAlreadyExists,
    );
}
