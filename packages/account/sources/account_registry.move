// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Shared registry for canonical account creation.
///
/// The registry owns deterministic account ID derivation and enforces one
/// account per owner address. `account::account` owns the resulting Account's
/// custody, proof, settlement, and app-data invariants.
module account::account_registry;

use account::account::{Self, Account};
use sui::derived_object;

// === Errors ===
const EAccountAlreadyExists: u64 = 0;

/// Shared derivation root for canonical user accounts.
public struct AccountRegistry has key {
    id: UID,
}

/// Canonical account derivation key: one account per owner address under the
/// package's `AccountRegistry`.
public struct AccountKey(address) has copy, drop, store;

fun init(ctx: &mut TxContext) {
    transfer::share_object(AccountRegistry { id: object::new(ctx) });
}

// === Public Functions ===
/// Return the registry object ID.
public fun id(registry: &AccountRegistry): ID {
    registry.id.to_inner()
}

/// Return the deterministic account address for `owner` under `registry_id`.
public fun derived_address(registry_id: ID, owner: address): address {
    derived_object::derive_address(registry_id, AccountKey(owner))
}

/// Return the deterministic account ID for `owner` under `registry_id`.
public fun derived_id(registry_id: ID, owner: address): ID {
    derived_address(registry_id, owner).to_id()
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

// === Private Functions ===
fun assert_account_does_not_exist(registry: &AccountRegistry, owner: address) {
    assert!(!registry.derived_exists(owner), EAccountAlreadyExists);
}
