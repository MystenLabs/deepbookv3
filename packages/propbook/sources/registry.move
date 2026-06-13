// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unified shared registry enforcing one feed per `(oracle kind, id)` and serving
/// off-chain discovery. Created and shared once at publish — it is the package
/// singleton. Kind-keyed so multiple oracle families (pyth today, block_scholes
/// later) share one registry.
///
/// Intentionally NOT version-gated: a feed created under an old package version
/// just seeds an old version and is migratable (`feed_core::migrate`), so a stale
/// registry caller is harmless.
module propbook::registry;

use std::option::Option;
use sui::table::{Self, Table};

const EFeedAlreadyExists: u64 = 0;

/// Oracle-kind tags stored in `RegistryKey`; future oracles add a value here.
public(package) macro fun kind_pyth(): u8 {
    0
}

public(package) macro fun kind_block_scholes(): u8 {
    1
}

/// Unified registry keyed by `(kind, id)` so multiple oracle families share one
/// shared singleton.
public struct OracleRegistry has key {
    id: UID,
    feeds: Table<RegistryKey, ID>,
}

/// Composite key: oracle kind plus the family-local feed/asset id.
public struct RegistryKey has copy, drop, store {
    kind: u8,
    id: u32,
}

fun init(ctx: &mut TxContext) {
    create_and_share(ctx);
}

/// Whether a feed of `kind` with `id` has been created.
public fun contains_feed(reg: &OracleRegistry, kind: u8, id: u32): bool {
    reg.feeds.contains(RegistryKey { kind, id })
}

/// The feed object id bound to `(kind, id)`, or none. For off-chain discovery.
public fun feed_object_id(reg: &OracleRegistry, kind: u8, id: u32): Option<ID> {
    let key = RegistryKey { kind, id };
    if (reg.feeds.contains(key)) {
        option::some(*reg.feeds.borrow(key))
    } else {
        option::none()
    }
}

// === Public-Package Functions ===

/// Create and share the singleton registry. Owning the share in the defining
/// module keeps the struct `key`-only.
public(package) fun create_and_share(ctx: &mut TxContext) {
    transfer::share_object(new(ctx));
}

/// Bind `(kind, id)` to its feed object, aborting if one already exists.
public(package) fun record(reg: &mut OracleRegistry, kind: u8, id: u32, feed_obj_id: ID) {
    let key = RegistryKey { kind, id };
    assert!(!reg.feeds.contains(key), EFeedAlreadyExists);
    reg.feeds.add(key, feed_obj_id);
}

// === Private Functions ===

fun new(ctx: &mut TxContext): OracleRegistry {
    OracleRegistry { id: object::new(ctx), feeds: table::new(ctx) }
}

// === Test-Only Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}
