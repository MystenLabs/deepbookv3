// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Owns the derivation root for canonical accounts and the global whitelist of application witness types.
/// App authorization is package-wide rather than per-account: an authorized app can request full mutable authority for any account wrapper supplied to its flow.
/// `account::account` owns wrapper construction, custody, accumulator settlement, and app-data invariants.
module account::account_registry;

use account::{account::{Self, AccountWrapper, Auth}, account_events};
use std::{internal::Permit, type_name};
use sui::{derived_object, dynamic_field as df};

use fun df::add as UID.add;
use fun df::exists as UID.exists_;
use fun df::remove as UID.remove;

// === Errors ===
const EAppAlreadyAuthorized: u64 = 0;
const EAppNotAuthorized: u64 = 1;
const EAccountAlreadyExists: u64 = 2;

/// Root authority over application authorization. The package exposes no on-chain
/// revocation or rotation mechanism for this capability itself.
public struct AccountAdminCap has key, store {
    id: UID,
}

/// Shared derivation root for canonical user accounts.
public struct AccountRegistry has key {
    id: UID,
}

/// Derivation key for the canonical account identity used by app data and account events.
public struct AccountKey(address) has copy, drop, store;

/// Derivation key for the shared wrapper that receives accumulator funds and gates mutable borrows.
public struct AccountWrapperKey(address) has copy, drop, store;

/// Dynamic-field key recording that `App` is authorized to generate app auth.
public struct AppKey<phantom App>() has copy, drop, store;

fun init(ctx: &mut TxContext) {
    transfer::share_object(AccountRegistry { id: object::new(ctx) });
    transfer::public_transfer(AccountAdminCap { id: object::new(ctx) }, ctx.sender());
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

// === Public Functions ===
/// Returns the deterministic canonical account address for external discovery and PTB construction.
public fun derived_address(registry: &AccountRegistry, owner: address): address {
    derived_object::derive_address(registry.id.to_inner(), AccountKey(owner))
}

/// Returns the deterministic wrapper address for external discovery, accumulator delivery, and PTB construction.
public fun derived_wrapper_address(registry: &AccountRegistry, owner: address): address {
    derived_object::derive_address(registry.id.to_inner(), AccountWrapperKey(owner))
}

/// Returns whether the canonical account identity has been claimed.
public fun derived_exists(registry: &AccountRegistry, owner: address): bool {
    derived_object::exists(&registry.id, AccountKey(owner))
}

/// Returns whether the canonical wrapper has been claimed.
public fun derived_wrapper_exists(registry: &AccountRegistry, owner: address): bool {
    derived_object::exists(&registry.id, AccountWrapperKey(owner))
}

/// Creates the sender's canonical account and wrapper, aborting if either derived ID is already claimed.
public fun new(registry: &mut AccountRegistry, ctx: &mut TxContext): AccountWrapper {
    let owner = ctx.sender();
    registry.new_for_owner(owner, false, ctx)
}

/// Creates the canonical account owned by `owner_uid`'s object address, aborting if either derived ID is already claimed.
public fun new_self_owned(
    registry: &mut AccountRegistry,
    owner_uid: &mut UID,
    ctx: &mut TxContext,
): AccountWrapper {
    let owner = owner_uid.to_inner().to_address();
    registry.new_for_owner(owner, true, ctx)
}

/// Returns whether `App` may request package-issued mutable account authority.
public fun is_app_authorized<App>(registry: &AccountRegistry): bool {
    registry.id.exists_(AppKey<App>())
}

/// Globally authorizes `App` to request mutable authority for account wrappers.
public fun authorize_app<App>(registry: &mut AccountRegistry, _cap: &AccountAdminCap) {
    assert!(!registry.is_app_authorized<App>(), EAppAlreadyAuthorized);
    registry.id.add(AppKey<App>(), true);
    account_events::emit_app_authorized(type_name::with_defining_ids<App>().into_string());
}

/// Revokes `App` from requesting new mutable account authority.
public fun deauthorize_app<App>(registry: &mut AccountRegistry, _cap: &AccountAdminCap) {
    registry.assert_app_is_authorized<App>();
    let _authorized: bool = registry.id.remove(AppKey<App>());
    account_events::emit_app_deauthorized(type_name::with_defining_ids<App>().into_string());
}

/// Aborts unless `App` is currently authorized for app-driven account access.
public fun assert_app_is_authorized<App>(registry: &AccountRegistry) {
    assert!(registry.is_app_authorized<App>(), EAppNotAuthorized);
}

/// Generates full mutable account authority after checking the global app whitelist.
/// `Permit<App>` restricts the request to the module that defines `App`; the returned authority is not bound to an owner, wrapper, or operation.
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

fun new_for_owner(
    registry: &mut AccountRegistry,
    owner: address,
    self_owned: bool,
    ctx: &mut TxContext,
): AccountWrapper {
    registry.assert_account_does_not_exist(owner);
    let wrapper = account::new_derived(
        &mut registry.id,
        AccountWrapperKey(owner),
        AccountKey(owner),
        owner,
        ctx,
    );
    account_events::emit_account_created(
        wrapper.load_account().account_id(),
        wrapper.id(),
        owner,
        self_owned,
    );
    wrapper
}
