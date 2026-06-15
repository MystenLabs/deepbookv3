// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unified shared registry for Propbook oracle metadata.
///
/// The registry owns two separate namespaces:
/// - source catalog: one Propbook oracle object per `(oracle kind, source id)`
/// - canonical binding: one immutable oracle per
///   `(propbook underlying, kind, value kind)`
///
/// Source oracle objects are permissionless wrappers around verified source data.
/// Canonical bindings are admin-controlled because they are the trust claim that a
/// source id represents a Propbook underlying such as BTC.
///
/// Intentionally NOT version-gated: a feed created under an old package version
/// just seeds an old version and is migratable by the feed module, so a stale
/// registry caller is harmless.
module propbook::registry;

use propbook::{
    block_scholes_feed::{Self as block_scholes_feed, BlockScholesFeed},
    pyth_feed::{Self as pyth_feed, PythFeed}
};
use std::option::Option;
use sui::{event, table::{Self, Table}};

const ESourceAlreadyExists: u64 = 0;
const ESourceNotFound: u64 = 1;
const EInvalidOracleObject: u64 = 2;
const ESourceAlreadyBound: u64 = 3;
const EBindingAlreadyExists: u64 = 4;

/// Oracle-kind tags stored in registry keys; future oracles add a value here.
public(package) macro fun kind_pyth(): u8 {
    0
}

public(package) macro fun kind_block_scholes(): u8 {
    1
}

public(package) macro fun value_kind_spot(): u8 {
    0
}

public(package) macro fun value_kind_vol_surface(): u8 {
    1
}

/// Capability controlling canonical Propbook oracle bindings.
public struct RegistryAdminCap has key, store {
    id: UID,
}

/// Unified registry for source discovery and canonical Propbook bindings.
public struct OracleRegistry has key {
    id: UID,
    sources: Table<OracleSourceKey, ID>,
    bindings: Table<OracleBindingKey, OracleMetadata>,
    source_bindings: Table<OracleSourceKey, u32>,
}

/// Composite source key: oracle kind plus the source-local oracle id.
public struct OracleSourceKey has copy, drop, store {
    oracle_kind: u8,
    source_id: u32,
}

/// Canonical binding key: Propbook underlying plus the kind of oracle value.
public struct OracleBindingKey has copy, drop, store {
    propbook_underlying_id: u32,
    oracle_kind: u8,
    value_kind: u8,
}

/// Canonical metadata for one immutable Propbook oracle binding.
public struct OracleMetadata has copy, drop, store {
    propbook_underlying_id: u32,
    oracle_kind: u8,
    source_id: u32,
    propbook_oracle_id: ID,
    value_kind: u8,
}

/// Emitted when a Propbook source wrapper is created and registered.
public struct OracleSourceRegistered has copy, drop {
    oracle_kind: u8,
    source_id: u32,
    propbook_oracle_id: ID,
}

/// Emitted when an admin binds an oracle to a canonical Propbook underlying.
public struct OracleBound has copy, drop {
    propbook_underlying_id: u32,
    oracle_kind: u8,
    source_id: u32,
    propbook_oracle_id: ID,
    value_kind: u8,
}

fun init(ctx: &mut TxContext) {
    create_and_share(ctx);
    transfer::public_transfer(RegistryAdminCap { id: object::new(ctx) }, ctx.sender());
}

/// Return the registry object ID.
public fun id(registry: &OracleRegistry): ID {
    registry.id.to_inner()
}

/// Return the registry admin cap object ID.
public fun registry_admin_cap_id(cap: &RegistryAdminCap): ID {
    cap.id.to_inner()
}

/// Whether a Propbook Pyth source wrapper exists for `pyth_source_id`.
public fun contains_pyth_source(registry: &OracleRegistry, pyth_source_id: u32): bool {
    registry.contains_source(kind_pyth!(), pyth_source_id)
}

/// Whether a Propbook Block Scholes source wrapper exists for `bs_source_id`.
public fun contains_block_scholes_source(registry: &OracleRegistry, bs_source_id: u32): bool {
    registry.contains_source(kind_block_scholes!(), bs_source_id)
}

/// Propbook Pyth object ID for a Pyth source id, if a wrapper exists.
public fun propbook_pyth_id_for_source(registry: &OracleRegistry, pyth_source_id: u32): Option<ID> {
    registry.source_oracle_id(kind_pyth!(), pyth_source_id)
}

/// Propbook Block Scholes object ID for a Block Scholes source id, if a wrapper
/// exists.
public fun propbook_block_scholes_id_for_source(
    registry: &OracleRegistry,
    bs_source_id: u32,
): Option<ID> {
    registry.source_oracle_id(kind_block_scholes!(), bs_source_id)
}

/// Canonical Propbook Pyth object ID for `propbook_underlying_id`, if bound.
public fun propbook_pyth_id_for_underlying(
    registry: &OracleRegistry,
    propbook_underlying_id: u32,
): Option<ID> {
    registry.canonical_oracle_id(propbook_underlying_id, kind_pyth!(), value_kind_spot!())
}

/// Canonical Propbook Block Scholes object ID for `propbook_underlying_id`, if
/// bound.
public fun propbook_block_scholes_id_for_underlying(
    registry: &OracleRegistry,
    propbook_underlying_id: u32,
): Option<ID> {
    registry.canonical_oracle_id(
        propbook_underlying_id,
        kind_block_scholes!(),
        value_kind_vol_surface!(),
    )
}

/// Canonical Pyth metadata for `propbook_underlying_id`, if bound.
public fun pyth_metadata_for_underlying(
    registry: &OracleRegistry,
    propbook_underlying_id: u32,
): Option<OracleMetadata> {
    registry.canonical_metadata(propbook_underlying_id, kind_pyth!(), value_kind_spot!())
}

/// Canonical Block Scholes metadata for `propbook_underlying_id`, if bound.
public fun block_scholes_metadata_for_underlying(
    registry: &OracleRegistry,
    propbook_underlying_id: u32,
): Option<OracleMetadata> {
    registry.canonical_metadata(
        propbook_underlying_id,
        kind_block_scholes!(),
        value_kind_vol_surface!(),
    )
}

public fun propbook_underlying_id(metadata: &OracleMetadata): u32 {
    metadata.propbook_underlying_id
}

public fun oracle_kind(metadata: &OracleMetadata): u8 {
    metadata.oracle_kind
}

public fun source_id(metadata: &OracleMetadata): u32 {
    metadata.source_id
}

public fun propbook_oracle_id(metadata: &OracleMetadata): ID {
    metadata.propbook_oracle_id
}

public fun value_kind(metadata: &OracleMetadata): u8 {
    metadata.value_kind
}

/// Create and share the Propbook Pyth wrapper for `pyth_source_id`, then record
/// it in the source catalog. Permissionless: a duplicate source aborts before
/// object creation, and a junk source id creates an inert feed whose storage the
/// caller pays for.
public fun create_and_share_pyth_feed(
    registry: &mut OracleRegistry,
    pyth_source_id: u32,
    ctx: &mut TxContext,
): ID {
    assert_source_available(registry, kind_pyth!(), pyth_source_id);
    let propbook_pyth_id = pyth_feed::create_and_share(pyth_source_id, ctx);
    registry.record_source(kind_pyth!(), pyth_source_id, propbook_pyth_id);
    propbook_pyth_id
}

/// Create and share the Propbook Block Scholes wrapper for `bs_source_id`, then
/// record it in the source catalog. Permissionless: a duplicate source aborts
/// before object creation.
public fun create_and_share_block_scholes_feed(
    registry: &mut OracleRegistry,
    bs_source_id: u32,
    ctx: &mut TxContext,
): ID {
    assert_source_available(registry, kind_block_scholes!(), bs_source_id);
    let propbook_block_scholes_id = block_scholes_feed::create_and_share(bs_source_id, ctx);
    registry.record_source(
        kind_block_scholes!(),
        bs_source_id,
        propbook_block_scholes_id,
    );
    propbook_block_scholes_id
}

/// Admin-bind this Pyth source feed to a canonical Propbook underlying.
public fun bind_pyth_to_underlying(
    registry: &mut OracleRegistry,
    admin_cap: &RegistryAdminCap,
    feed: &PythFeed,
    propbook_underlying_id: u32,
) {
    registry.bind_oracle(
        admin_cap,
        propbook_underlying_id,
        kind_pyth!(),
        pyth_feed::pyth_source_id(feed),
        pyth_feed::id(feed),
        value_kind_spot!(),
    );
}

/// Admin-bind this Block Scholes source feed to a canonical Propbook underlying.
public fun bind_block_scholes_to_underlying(
    registry: &mut OracleRegistry,
    admin_cap: &RegistryAdminCap,
    feed: &BlockScholesFeed,
    propbook_underlying_id: u32,
) {
    registry.bind_oracle(
        admin_cap,
        propbook_underlying_id,
        kind_block_scholes!(),
        block_scholes_feed::bs_source_id(feed),
        block_scholes_feed::id(feed),
        value_kind_vol_surface!(),
    );
}

// === Public-Package Functions ===

/// Create and share the singleton registry. Owning the share in the defining
/// module keeps the struct `key`-only.
public(package) fun create_and_share(ctx: &mut TxContext) {
    transfer::share_object(new(ctx));
}

// === Private Functions ===

/// Bind `(oracle_kind, source_id)` to its Propbook object ID, aborting if a
/// source wrapper already exists for that key.
fun record_source(
    registry: &mut OracleRegistry,
    oracle_kind: u8,
    source_id: u32,
    propbook_oracle_id: ID,
) {
    let key = OracleSourceKey { oracle_kind, source_id };
    assert!(!registry.sources.contains(key), ESourceAlreadyExists);
    registry.sources.add(key, propbook_oracle_id);
    event::emit(OracleSourceRegistered {
        oracle_kind,
        source_id,
        propbook_oracle_id,
    });
}

/// Bind one source oracle object to a canonical Propbook underlying.
/// Source wrapper creation remains permissionless; this canonical mapping is the
/// insert-only admin-controlled trust claim downstream consumers can discover.
fun bind_oracle(
    registry: &mut OracleRegistry,
    _admin_cap: &RegistryAdminCap,
    propbook_underlying_id: u32,
    oracle_kind: u8,
    source_id: u32,
    propbook_oracle_id: ID,
    value_kind: u8,
) {
    let source_key = OracleSourceKey { oracle_kind, source_id };
    assert!(registry.sources.contains(source_key), ESourceNotFound);
    assert!(*registry.sources.borrow(source_key) == propbook_oracle_id, EInvalidOracleObject);

    let binding_key = OracleBindingKey { propbook_underlying_id, oracle_kind, value_kind };
    assert!(!registry.bindings.contains(binding_key), EBindingAlreadyExists);

    if (registry.source_bindings.contains(source_key)) {
        assert!(
            *registry.source_bindings.borrow(source_key) == propbook_underlying_id,
            ESourceAlreadyBound,
        );
    };

    let metadata = OracleMetadata {
        propbook_underlying_id,
        oracle_kind,
        source_id,
        propbook_oracle_id,
        value_kind,
    };
    registry.bindings.add(binding_key, metadata);

    if (!registry.source_bindings.contains(source_key)) {
        registry.source_bindings.add(source_key, propbook_underlying_id);
    };

    event::emit(OracleBound {
        propbook_underlying_id,
        oracle_kind,
        source_id,
        propbook_oracle_id,
        value_kind,
    });
}

fun contains_source(registry: &OracleRegistry, oracle_kind: u8, source_id: u32): bool {
    registry.sources.contains(OracleSourceKey { oracle_kind, source_id })
}

fun source_oracle_id(registry: &OracleRegistry, oracle_kind: u8, source_id: u32): Option<ID> {
    let key = OracleSourceKey { oracle_kind, source_id };
    if (registry.sources.contains(key)) {
        option::some(*registry.sources.borrow(key))
    } else {
        option::none()
    }
}

fun canonical_oracle_id(
    registry: &OracleRegistry,
    propbook_underlying_id: u32,
    oracle_kind: u8,
    value_kind: u8,
): Option<ID> {
    let key = OracleBindingKey { propbook_underlying_id, oracle_kind, value_kind };
    if (registry.bindings.contains(key)) {
        option::some(registry.bindings.borrow(key).propbook_oracle_id)
    } else {
        option::none()
    }
}

fun canonical_metadata(
    registry: &OracleRegistry,
    propbook_underlying_id: u32,
    oracle_kind: u8,
    value_kind: u8,
): Option<OracleMetadata> {
    let key = OracleBindingKey { propbook_underlying_id, oracle_kind, value_kind };
    if (registry.bindings.contains(key)) {
        option::some(*registry.bindings.borrow(key))
    } else {
        option::none()
    }
}

fun new(ctx: &mut TxContext): OracleRegistry {
    OracleRegistry {
        id: object::new(ctx),
        sources: table::new(ctx),
        bindings: table::new(ctx),
        source_bindings: table::new(ctx),
    }
}

fun assert_source_available(registry: &OracleRegistry, oracle_kind: u8, source_id: u32) {
    assert!(
        !registry.sources.contains(OracleSourceKey { oracle_kind, source_id }),
        ESourceAlreadyExists,
    );
}

// === Test-Only Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}
