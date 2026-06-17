// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Shared registry for canonical account creation.
///
/// The registry owns deterministic account ID derivation and allocates monotonically
/// increasing slots per sender. `account::account` owns the resulting Account's
/// custody, proof, settlement, and app-data invariants.
module account::account_registry;

use account::account::{Self, Account, OwnerCap};
use sui::{derived_object, table::{Self, Table}};

/// Shared derivation root and slot allocator for canonical user accounts.
public struct AccountRegistry has key {
    id: UID,
    next_slots: Table<address, u64>,
}

/// Canonical account derivation key: one shared account namespace per
/// `(owner, slot)` under the package's `AccountRegistry`.
public struct AccountKey(address, u64) has copy, drop, store;

fun init(ctx: &mut TxContext) {
    transfer::share_object(AccountRegistry { id: object::new(ctx), next_slots: table::new(ctx) });
}

// === Public Functions ===
/// Return the registry object ID.
public fun id(registry: &AccountRegistry): ID {
    registry.id.to_inner()
}

/// Return the next slot that would be assigned to `owner`.
public fun next_slot(registry: &AccountRegistry, owner: address): u64 {
    if (registry.next_slots.contains(owner)) {
        *registry.next_slots.borrow(owner)
    } else {
        0
    }
}

/// Return the deterministic account address for `owner` and `slot` under
/// `registry_id`.
public fun derived_address(registry_id: ID, owner: address, slot: u64): address {
    derived_object::derive_address(registry_id, AccountKey(owner, slot))
}

/// Return the deterministic account ID for `owner` and `slot` under
/// `registry_id`.
public fun derived_id(registry_id: ID, owner: address, slot: u64): ID {
    derived_address(registry_id, owner, slot).to_id()
}

/// Return whether the derived account slot has already been claimed.
public fun derived_exists(registry: &AccountRegistry, owner: address, slot: u64): bool {
    derived_object::exists(&registry.id, AccountKey(owner, slot))
}

/// Create the sender's next derived account.
public fun new(registry: &mut AccountRegistry, ctx: &mut TxContext): Account {
    let owner = ctx.sender();
    let slot = registry.allocate_slot(owner);
    account::new_derived(&mut registry.id, AccountKey(owner, slot), owner, ctx)
}

/// Create the sender's next derived self-owned account and its `OwnerCap`.
public fun new_self_owned(
    registry: &mut AccountRegistry,
    ctx: &mut TxContext,
): (Account, OwnerCap) {
    let owner = ctx.sender();
    let slot = registry.allocate_slot(owner);
    account::new_self_owned_derived(&mut registry.id, AccountKey(owner, slot), ctx)
}

// === Private Functions ===
fun allocate_slot(registry: &mut AccountRegistry, owner: address): u64 {
    let slot = registry.next_slot(owner);
    if (registry.next_slots.contains(owner)) {
        *registry.next_slots.borrow_mut(owner) = slot + 1;
    } else {
        registry.next_slots.add(owner, slot + 1);
    };
    slot
}
