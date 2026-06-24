// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unified shared registry for Propbook oracle metadata.
///
/// The registry owns two separate namespaces:
/// - source catalog: one Propbook oracle object per source-local key
/// - canonical binding: one immutable oracle per canonical consumer key
///
/// Source oracle objects are permissionless wrappers around verified source data.
/// Canonical bindings are admin-controlled because they are the trust claim that
/// source data represents a Propbook underlying such as BTC.
///
/// Intentionally NOT version-gated: a feed created under an old package version
/// just seeds an old version and is migratable by the feed module, so a stale
/// registry caller is harmless.
module propbook::registry;

use propbook::{
    block_scholes_forward_feed::{Self as block_scholes_forward_feed, BlockScholesForwardFeed},
    block_scholes_spot_feed::{Self as block_scholes_spot_feed, BlockScholesSpotFeed},
    block_scholes_svi_feed::{Self as block_scholes_svi_feed, BlockScholesSVIFeed},
    pyth_feed::{Self as pyth_feed, PythFeed}
};
use std::option::{Self, Option};
use sui::{event, table::{Self, Table}};

const ESourceAlreadyExists: u64 = 0;
const ESourceNotFound: u64 = 1;
const EInvalidOracleObject: u64 = 2;
const ESourceAlreadyBound: u64 = 3;
const EBindingAlreadyExists: u64 = 4;
const EBlockScholesSpotNotBound: u64 = 5;
const EWrongBlockScholesSource: u64 = 6;

/// Oracle-kind tags stored in registry keys; future oracles add a value here.
public(package) macro fun kind_pyth(): u8 {
    0
}

public(package) macro fun kind_block_scholes_spot(): u8 {
    1
}

public(package) macro fun kind_block_scholes_forward(): u8 {
    2
}

public(package) macro fun kind_block_scholes_svi(): u8 {
    3
}

public(package) macro fun value_kind_spot(): u8 {
    0
}

public(package) macro fun value_kind_forward(): u8 {
    1
}

public(package) macro fun value_kind_svi(): u8 {
    2
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

/// Composite source key: oracle kind plus source-local identity.
public struct OracleSourceKey has copy, drop, store {
    oracle_kind: u8,
    source_id: u32,
}

/// Canonical binding key: Propbook underlying plus oracle value identity.
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
    registry.contains_source(pyth_source_key(pyth_source_id))
}

/// Whether a Propbook BS spot wrapper exists for `bs_source_id`.
public fun contains_block_scholes_spot_source(
    registry: &OracleRegistry,
    bs_source_id: u32,
): bool {
    registry.contains_source(block_scholes_spot_source_key(bs_source_id))
}

/// Whether a Propbook BS forward wrapper exists for `bs_source_id`.
public fun contains_block_scholes_forward_source(
    registry: &OracleRegistry,
    bs_source_id: u32,
): bool {
    registry.contains_source(block_scholes_forward_source_key(bs_source_id))
}

/// Whether a Propbook BS SVI wrapper exists for `bs_source_id`.
public fun contains_block_scholes_svi_source(
    registry: &OracleRegistry,
    bs_source_id: u32,
): bool {
    registry.contains_source(block_scholes_svi_source_key(bs_source_id))
}

/// Propbook Pyth object ID for a Pyth source id, if a wrapper exists.
public fun propbook_pyth_id_for_source(registry: &OracleRegistry, pyth_source_id: u32): Option<ID> {
    registry.source_oracle_id(pyth_source_key(pyth_source_id))
}

/// Propbook BS spot object ID for a BS source id, if a wrapper exists.
public fun propbook_block_scholes_spot_id_for_source(
    registry: &OracleRegistry,
    bs_source_id: u32,
): Option<ID> {
    registry.source_oracle_id(block_scholes_spot_source_key(bs_source_id))
}

/// Propbook BS forward object ID for `bs_source_id`, if a wrapper exists.
public fun propbook_block_scholes_forward_id_for_source(
    registry: &OracleRegistry,
    bs_source_id: u32,
): Option<ID> {
    registry.source_oracle_id(block_scholes_forward_source_key(bs_source_id))
}

/// Propbook BS SVI object ID for `bs_source_id`, if a wrapper exists.
public fun propbook_block_scholes_svi_id_for_source(
    registry: &OracleRegistry,
    bs_source_id: u32,
): Option<ID> {
    registry.source_oracle_id(block_scholes_svi_source_key(bs_source_id))
}

/// Canonical Propbook Pyth object ID for `propbook_underlying_id`, if bound.
public fun propbook_pyth_id_for_underlying(
    registry: &OracleRegistry,
    propbook_underlying_id: u32,
): Option<ID> {
    registry.canonical_oracle_id(pyth_binding_key(propbook_underlying_id))
}

/// Canonical Propbook BS spot object ID for `propbook_underlying_id`, if bound.
public fun propbook_block_scholes_spot_id_for_underlying(
    registry: &OracleRegistry,
    propbook_underlying_id: u32,
): Option<ID> {
    registry.canonical_oracle_id(block_scholes_spot_binding_key(propbook_underlying_id))
}

/// Canonical Propbook BS forward object ID for `propbook_underlying_id`, if bound.
public fun propbook_block_scholes_forward_id_for_underlying(
    registry: &OracleRegistry,
    propbook_underlying_id: u32,
): Option<ID> {
    registry.canonical_oracle_id(block_scholes_forward_binding_key(propbook_underlying_id))
}

/// Canonical Propbook BS SVI object ID for `propbook_underlying_id`, if bound.
public fun propbook_block_scholes_svi_id_for_underlying(
    registry: &OracleRegistry,
    propbook_underlying_id: u32,
): Option<ID> {
    registry.canonical_oracle_id(block_scholes_svi_binding_key(propbook_underlying_id))
}

/// Canonical Pyth metadata for `propbook_underlying_id`, if bound.
public fun pyth_metadata_for_underlying(
    registry: &OracleRegistry,
    propbook_underlying_id: u32,
): Option<OracleMetadata> {
    registry.canonical_metadata(pyth_binding_key(propbook_underlying_id))
}

/// Canonical BS spot metadata for `propbook_underlying_id`, if bound.
public fun block_scholes_spot_metadata_for_underlying(
    registry: &OracleRegistry,
    propbook_underlying_id: u32,
): Option<OracleMetadata> {
    registry.canonical_metadata(block_scholes_spot_binding_key(propbook_underlying_id))
}

/// Canonical BS forward metadata for `propbook_underlying_id`, if bound.
public fun block_scholes_forward_metadata_for_underlying(
    registry: &OracleRegistry,
    propbook_underlying_id: u32,
): Option<OracleMetadata> {
    registry.canonical_metadata(block_scholes_forward_binding_key(propbook_underlying_id))
}

/// Canonical BS SVI metadata for `propbook_underlying_id`, if bound.
public fun block_scholes_svi_metadata_for_underlying(
    registry: &OracleRegistry,
    propbook_underlying_id: u32,
): Option<OracleMetadata> {
    registry.canonical_metadata(block_scholes_svi_binding_key(propbook_underlying_id))
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
    let source_key = pyth_source_key(pyth_source_id);
    assert_source_available(registry, source_key);
    let propbook_pyth_id = pyth_feed::create_and_share(pyth_source_id, ctx);
    registry.record_source(source_key, propbook_pyth_id);
    propbook_pyth_id
}

/// Create and share the Propbook BS spot wrapper for `bs_source_id`, then record
/// it in the source catalog. Permissionless: a duplicate source aborts before
/// object creation.
public fun create_and_share_block_scholes_spot_feed(
    registry: &mut OracleRegistry,
    bs_source_id: u32,
    ctx: &mut TxContext,
): ID {
    let source_key = block_scholes_spot_source_key(bs_source_id);
    assert_source_available(registry, source_key);
    let propbook_spot_id = block_scholes_spot_feed::create_and_share(bs_source_id, ctx);
    registry.record_source(source_key, propbook_spot_id);
    propbook_spot_id
}

/// Create and share the Propbook BS forward wrapper for `bs_source_id`, then
/// record it in the source catalog.
public fun create_and_share_block_scholes_forward_feed(
    registry: &mut OracleRegistry,
    bs_source_id: u32,
    ctx: &mut TxContext,
): ID {
    let source_key = block_scholes_forward_source_key(bs_source_id);
    assert_source_available(registry, source_key);
    let propbook_forward_id = block_scholes_forward_feed::create_and_share(bs_source_id, ctx);
    registry.record_source(source_key, propbook_forward_id);
    propbook_forward_id
}

/// Create and share the Propbook BS SVI wrapper for `bs_source_id`, then record
/// it in the source catalog.
public fun create_and_share_block_scholes_svi_feed(
    registry: &mut OracleRegistry,
    bs_source_id: u32,
    ctx: &mut TxContext,
): ID {
    let source_key = block_scholes_svi_source_key(bs_source_id);
    assert_source_available(registry, source_key);
    let propbook_svi_id = block_scholes_svi_feed::create_and_share(bs_source_id, ctx);
    registry.record_source(source_key, propbook_svi_id);
    propbook_svi_id
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
        pyth_source_key(pyth_feed::pyth_source_id(feed)),
        pyth_feed::id(feed),
        pyth_binding_key(propbook_underlying_id),
    );
}

/// Admin-bind this BS spot source feed to a canonical Propbook underlying.
public fun bind_block_scholes_spot_to_underlying(
    registry: &mut OracleRegistry,
    admin_cap: &RegistryAdminCap,
    feed: &BlockScholesSpotFeed,
    propbook_underlying_id: u32,
) {
    registry.bind_oracle(
        admin_cap,
        propbook_underlying_id,
        block_scholes_spot_source_key(block_scholes_spot_feed::bs_source_id(feed)),
        block_scholes_spot_feed::id(feed),
        block_scholes_spot_binding_key(propbook_underlying_id),
    );
}

/// Admin-bind this BS forward/SVI surface pair to a canonical Propbook underlying.
/// The underlying's BS spot feed must already be bound, and all three BS feeds
/// must come from the same source id.
public fun bind_block_scholes_surface_to_underlying(
    registry: &mut OracleRegistry,
    admin_cap: &RegistryAdminCap,
    forward_feed: &BlockScholesForwardFeed,
    svi_feed: &BlockScholesSVIFeed,
    propbook_underlying_id: u32,
) {
    let bs_source_id = block_scholes_forward_feed::bs_source_id(forward_feed);
    assert!(
        bs_source_id == block_scholes_svi_feed::bs_source_id(svi_feed),
        EWrongBlockScholesSource,
    );
    registry.assert_bound_block_scholes_spot_source(propbook_underlying_id, bs_source_id);

    let forward_source_key = block_scholes_forward_source_key(bs_source_id);
    let svi_source_key = block_scholes_svi_source_key(bs_source_id);
    let forward_binding_key = block_scholes_forward_binding_key(propbook_underlying_id);
    let svi_binding_key = block_scholes_svi_binding_key(propbook_underlying_id);

    registry.assert_registered_source_object(
        forward_source_key,
        block_scholes_forward_feed::id(forward_feed),
    );
    registry.assert_registered_source_object(svi_source_key, block_scholes_svi_feed::id(svi_feed));
    registry.assert_binding_available(forward_binding_key);
    registry.assert_binding_available(svi_binding_key);

    registry.bind_oracle(
        admin_cap,
        propbook_underlying_id,
        forward_source_key,
        block_scholes_forward_feed::id(forward_feed),
        forward_binding_key,
    );
    registry.bind_oracle(
        admin_cap,
        propbook_underlying_id,
        svi_source_key,
        block_scholes_svi_feed::id(svi_feed),
        svi_binding_key,
    );
}

// === Public-Package Functions ===

/// Create and share the singleton registry. Owning the share in the defining
/// module keeps the struct `key`-only.
public(package) fun create_and_share(ctx: &mut TxContext) {
    transfer::share_object(new(ctx));
}

// === Private Functions ===

/// Bind a source key to its Propbook object ID, aborting if a source wrapper
/// already exists for that key.
fun record_source(registry: &mut OracleRegistry, source_key: OracleSourceKey, propbook_oracle_id: ID) {
    assert!(!registry.sources.contains(source_key), ESourceAlreadyExists);
    registry.sources.add(source_key, propbook_oracle_id);
    event::emit(OracleSourceRegistered {
        oracle_kind: source_key.oracle_kind,
        source_id: source_key.source_id,
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
    source_key: OracleSourceKey,
    propbook_oracle_id: ID,
    binding_key: OracleBindingKey,
) {
    registry.assert_registered_source_object(source_key, propbook_oracle_id);
    registry.assert_binding_available(binding_key);

    if (registry.source_bindings.contains(source_key)) {
        assert!(
            *registry.source_bindings.borrow(source_key) == propbook_underlying_id,
            ESourceAlreadyBound,
        );
    };

    let metadata = OracleMetadata {
        propbook_underlying_id,
        oracle_kind: source_key.oracle_kind,
        source_id: source_key.source_id,
        propbook_oracle_id,
        value_kind: binding_key.value_kind,
    };
    registry.bindings.add(binding_key, metadata);

    if (!registry.source_bindings.contains(source_key)) {
        registry.source_bindings.add(source_key, propbook_underlying_id);
    };

    event::emit(OracleBound {
        propbook_underlying_id,
        oracle_kind: source_key.oracle_kind,
        source_id: source_key.source_id,
        propbook_oracle_id,
        value_kind: binding_key.value_kind,
    });
}

fun contains_source(registry: &OracleRegistry, source_key: OracleSourceKey): bool {
    registry.sources.contains(source_key)
}

fun source_oracle_id(registry: &OracleRegistry, source_key: OracleSourceKey): Option<ID> {
    if (registry.sources.contains(source_key)) {
        option::some(*registry.sources.borrow(source_key))
    } else {
        option::none()
    }
}

fun canonical_oracle_id(registry: &OracleRegistry, binding_key: OracleBindingKey): Option<ID> {
    if (registry.bindings.contains(binding_key)) {
        option::some(registry.bindings.borrow(binding_key).propbook_oracle_id)
    } else {
        option::none()
    }
}

fun canonical_metadata(
    registry: &OracleRegistry,
    binding_key: OracleBindingKey,
): Option<OracleMetadata> {
    if (registry.bindings.contains(binding_key)) {
        option::some(*registry.bindings.borrow(binding_key))
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

fun assert_source_available(registry: &OracleRegistry, source_key: OracleSourceKey) {
    assert!(!registry.sources.contains(source_key), ESourceAlreadyExists);
}

fun assert_registered_source_object(
    registry: &OracleRegistry,
    source_key: OracleSourceKey,
    propbook_oracle_id: ID,
) {
    assert!(registry.sources.contains(source_key), ESourceNotFound);
    assert!(*registry.sources.borrow(source_key) == propbook_oracle_id, EInvalidOracleObject);
}

fun assert_binding_available(registry: &OracleRegistry, binding_key: OracleBindingKey) {
    assert!(!registry.bindings.contains(binding_key), EBindingAlreadyExists);
}

fun assert_bound_block_scholes_spot_source(
    registry: &OracleRegistry,
    propbook_underlying_id: u32,
    bs_source_id: u32,
) {
    let spot_metadata = registry.canonical_metadata(
        block_scholes_spot_binding_key(propbook_underlying_id),
    );
    assert!(spot_metadata.is_some(), EBlockScholesSpotNotBound);
    assert!(spot_metadata.destroy_some().source_id == bs_source_id, EWrongBlockScholesSource);
}

fun pyth_source_key(pyth_source_id: u32): OracleSourceKey {
    OracleSourceKey {
        oracle_kind: kind_pyth!(),
        source_id: pyth_source_id,
    }
}

fun block_scholes_spot_source_key(bs_source_id: u32): OracleSourceKey {
    OracleSourceKey {
        oracle_kind: kind_block_scholes_spot!(),
        source_id: bs_source_id,
    }
}

fun block_scholes_forward_source_key(bs_source_id: u32): OracleSourceKey {
    OracleSourceKey {
        oracle_kind: kind_block_scholes_forward!(),
        source_id: bs_source_id,
    }
}

fun block_scholes_svi_source_key(bs_source_id: u32): OracleSourceKey {
    OracleSourceKey {
        oracle_kind: kind_block_scholes_svi!(),
        source_id: bs_source_id,
    }
}

fun pyth_binding_key(propbook_underlying_id: u32): OracleBindingKey {
    OracleBindingKey {
        propbook_underlying_id,
        oracle_kind: kind_pyth!(),
        value_kind: value_kind_spot!(),
    }
}

fun block_scholes_spot_binding_key(propbook_underlying_id: u32): OracleBindingKey {
    OracleBindingKey {
        propbook_underlying_id,
        oracle_kind: kind_block_scholes_spot!(),
        value_kind: value_kind_spot!(),
    }
}

fun block_scholes_forward_binding_key(propbook_underlying_id: u32): OracleBindingKey {
    OracleBindingKey {
        propbook_underlying_id,
        oracle_kind: kind_block_scholes_forward!(),
        value_kind: value_kind_forward!(),
    }
}

fun block_scholes_svi_binding_key(propbook_underlying_id: u32): OracleBindingKey {
    OracleBindingKey {
        propbook_underlying_id,
        oracle_kind: kind_block_scholes_svi!(),
        value_kind: value_kind_svi!(),
    }
}

// === Test-Only Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}
