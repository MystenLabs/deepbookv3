// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Owns Propbook's permissionless source catalog and admin-selected canonical oracle bindings.
/// Registering a source creates its wrapper but does not make it canonical; a binding is the trust claim that the source represents a particular Propbook underlying and value kind.
/// A source key can serve only one underlying for its lifetime, even after its active binding is replaced.
/// Registry operations are not version-gated because each feed owns its write version and migration path.
module propbook::registry;

use propbook::{
    block_scholes_forward_feed::{Self, BlockScholesForwardFeed},
    block_scholes_spot_feed::{Self, BlockScholesSpotFeed},
    block_scholes_svi_feed::{Self, BlockScholesSVIFeed},
    pyth_feed::{Self, PythFeed}
};
use sui::{event, table::{Self, Table}};

const ESourceAlreadyExists: u64 = 0;
const ESourceNotFound: u64 = 1;
const EInvalidOracleObject: u64 = 2;
const ESourceAlreadyBound: u64 = 3;
const EBindingAlreadyExists: u64 = 4;
const EBlockScholesSpotNotBound: u64 = 5;
const EWrongBlockScholesSource: u64 = 6;
const EBindingNotFound: u64 = 7;

// Stable discriminators stored in source keys, binding keys, metadata, and events.
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

/// Root capability authorized to choose and replace canonical oracle bindings.
/// The package exposes no on-chain revocation or rotation mechanism for it.
public struct RegistryAdminCap has key, store {
    id: UID,
}

/// Shared source catalog, canonical binding table, and permanent source-to-underlying assignments.
public struct OracleRegistry has key {
    id: UID,
    /// Provider/source pair to the shared feed object created for that source.
    sources: Table<OracleSourceKey, ID>,
    /// Underlying/provider/value tuple to its active canonical feed metadata.
    bindings: Table<OracleBindingKey, OracleMetadata>,
    /// Provider/source pair to the sole underlying it may serve.
    source_bindings: Table<OracleSourceKey, u32>,
}

/// Unique identity of a provider source within one oracle kind.
public struct OracleSourceKey has copy, drop, store {
    oracle_kind: u8,
    source_id: u32,
}

/// Canonical slot for one underlying, oracle kind, and value kind.
public struct OracleBindingKey has copy, drop, store {
    propbook_underlying_id: u32,
    oracle_kind: u8,
    value_kind: u8,
}

/// Metadata for an active binding returned to protocol and off-chain consumers.
public struct OracleMetadata has copy, drop, store {
    propbook_underlying_id: u32,
    oracle_kind: u8,
    source_id: u32,
    propbook_oracle_id: ID,
    value_kind: u8,
}

/// Records creation and registration of a source wrapper.
public struct OracleSourceRegistered has copy, drop {
    oracle_kind: u8,
    source_id: u32,
    propbook_oracle_id: ID,
}

/// Records the first canonical assignment of a binding slot.
public struct OracleBound has copy, drop {
    propbook_underlying_id: u32,
    oracle_kind: u8,
    source_id: u32,
    propbook_oracle_id: ID,
    value_kind: u8,
}

/// Records an atomic replacement of an existing canonical binding slot.
public struct OracleRebound has copy, drop {
    propbook_underlying_id: u32,
    oracle_kind: u8,
    value_kind: u8,
    old_source_id: u32,
    old_propbook_oracle_id: ID,
    new_source_id: u32,
    new_propbook_oracle_id: ID,
}

fun init(ctx: &mut TxContext) {
    create_and_share(ctx);
    transfer::public_transfer(RegistryAdminCap { id: object::new(ctx) }, ctx.sender());
}

// === External Reads ===

/// Returns the registry identity for external composition and PTB construction.
public fun id(registry: &OracleRegistry): ID {
    registry.id.to_inner()
}

/// Returns the admin capability identity for administration tooling and object discovery.
public fun registry_admin_cap_id(cap: &RegistryAdminCap): ID {
    cap.id.to_inner()
}

/// Returns whether the Pyth source wrapper exists in the external source catalog.
public fun contains_pyth_source(registry: &OracleRegistry, pyth_source_id: u32): bool {
    registry.contains_source(pyth_source_key(pyth_source_id))
}

/// Returns whether the Block Scholes spot wrapper exists in the external source catalog.
public fun contains_block_scholes_spot_source(registry: &OracleRegistry, bs_source_id: u32): bool {
    registry.contains_source(block_scholes_spot_source_key(bs_source_id))
}

/// Returns whether the Block Scholes forward wrapper exists in the external source catalog.
public fun contains_block_scholes_forward_source(
    registry: &OracleRegistry,
    bs_source_id: u32,
): bool {
    registry.contains_source(block_scholes_forward_source_key(bs_source_id))
}

/// Returns whether the Block Scholes SVI wrapper exists in the external source catalog.
public fun contains_block_scholes_svi_source(registry: &OracleRegistry, bs_source_id: u32): bool {
    registry.contains_source(block_scholes_svi_source_key(bs_source_id))
}

/// Resolves a registered Pyth source wrapper for external composition or discovery.
public fun propbook_pyth_id_for_source(registry: &OracleRegistry, pyth_source_id: u32): Option<ID> {
    registry.source_oracle_id(pyth_source_key(pyth_source_id))
}

/// Resolves a registered Block Scholes spot wrapper for external composition or discovery.
public fun propbook_block_scholes_spot_id_for_source(
    registry: &OracleRegistry,
    bs_source_id: u32,
): Option<ID> {
    registry.source_oracle_id(block_scholes_spot_source_key(bs_source_id))
}

/// Resolves a registered Block Scholes forward wrapper for external composition or discovery.
public fun propbook_block_scholes_forward_id_for_source(
    registry: &OracleRegistry,
    bs_source_id: u32,
): Option<ID> {
    registry.source_oracle_id(block_scholes_forward_source_key(bs_source_id))
}

/// Resolves a registered Block Scholes SVI wrapper for external composition or discovery.
public fun propbook_block_scholes_svi_id_for_source(
    registry: &OracleRegistry,
    bs_source_id: u32,
): Option<ID> {
    registry.source_oracle_id(block_scholes_svi_source_key(bs_source_id))
}

/// Resolves the canonical Pyth feed for external composition or discovery.
public fun propbook_pyth_id_for_underlying(
    registry: &OracleRegistry,
    propbook_underlying_id: u32,
): Option<ID> {
    registry.canonical_oracle_id(pyth_binding_key(propbook_underlying_id))
}

/// Resolves the canonical Block Scholes spot feed for external composition or discovery.
public fun propbook_block_scholes_spot_id_for_underlying(
    registry: &OracleRegistry,
    propbook_underlying_id: u32,
): Option<ID> {
    registry.canonical_oracle_id(block_scholes_spot_binding_key(propbook_underlying_id))
}

/// Resolves the canonical Block Scholes forward feed for external composition or discovery.
public fun propbook_block_scholes_forward_id_for_underlying(
    registry: &OracleRegistry,
    propbook_underlying_id: u32,
): Option<ID> {
    registry.canonical_oracle_id(block_scholes_forward_binding_key(propbook_underlying_id))
}

/// Resolves the canonical Block Scholes SVI feed for external composition or discovery.
public fun propbook_block_scholes_svi_id_for_underlying(
    registry: &OracleRegistry,
    propbook_underlying_id: u32,
): Option<ID> {
    registry.canonical_oracle_id(block_scholes_svi_binding_key(propbook_underlying_id))
}

/// Returns the canonical Pyth binding metadata for external composition or inspection.
public fun pyth_metadata_for_underlying(
    registry: &OracleRegistry,
    propbook_underlying_id: u32,
): Option<OracleMetadata> {
    registry.canonical_metadata(pyth_binding_key(propbook_underlying_id))
}

/// Returns the canonical Block Scholes spot binding metadata for external composition or inspection.
public fun block_scholes_spot_metadata_for_underlying(
    registry: &OracleRegistry,
    propbook_underlying_id: u32,
): Option<OracleMetadata> {
    registry.canonical_metadata(block_scholes_spot_binding_key(propbook_underlying_id))
}

/// Returns the canonical Block Scholes forward binding metadata for external composition or inspection.
public fun block_scholes_forward_metadata_for_underlying(
    registry: &OracleRegistry,
    propbook_underlying_id: u32,
): Option<OracleMetadata> {
    registry.canonical_metadata(block_scholes_forward_binding_key(propbook_underlying_id))
}

/// Returns the canonical Block Scholes SVI binding metadata for external composition or inspection.
public fun block_scholes_svi_metadata_for_underlying(
    registry: &OracleRegistry,
    propbook_underlying_id: u32,
): Option<OracleMetadata> {
    registry.canonical_metadata(block_scholes_svi_binding_key(propbook_underlying_id))
}

/// Return the bound underlying ID for external registry discovery.
public fun propbook_underlying_id(metadata: &OracleMetadata): u32 {
    metadata.propbook_underlying_id
}

/// Return the oracle-kind discriminator for external registry discovery.
public fun oracle_kind(metadata: &OracleMetadata): u8 {
    metadata.oracle_kind
}

/// Return the provider source ID for external registry discovery.
public fun source_id(metadata: &OracleMetadata): u32 {
    metadata.source_id
}

/// Return the canonical feed object ID for external PTB construction.
public fun propbook_oracle_id(metadata: &OracleMetadata): ID {
    metadata.propbook_oracle_id
}

/// Return the value-kind discriminator for external registry discovery.
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
        pyth_source_key(pyth_feed::pyth_source_id(feed)),
        pyth_feed::id(feed),
        pyth_binding_key(propbook_underlying_id),
    );
}

/// Admin-replace the canonical Pyth source feed for a Propbook underlying.
///
/// The replacement feed must already be registered in the source catalog. A
/// source key already assigned to another underlying remains ineligible forever;
/// replacement does not create an unbound intermediate state.
public fun replace_pyth_binding_for_underlying(
    registry: &mut OracleRegistry,
    admin_cap: &RegistryAdminCap,
    feed: &PythFeed,
    propbook_underlying_id: u32,
) {
    registry.replace_oracle(
        admin_cap,
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

    registry.bind_oracle(
        admin_cap,
        forward_source_key,
        block_scholes_forward_feed::id(forward_feed),
        forward_binding_key,
    );
    registry.bind_oracle(
        admin_cap,
        svi_source_key,
        block_scholes_svi_feed::id(svi_feed),
        svi_binding_key,
    );
}

/// Admin-replace all canonical Block Scholes feeds for a Propbook underlying.
///
/// Spot, forward, and SVI are replaced atomically and must all come from the same
/// `bs_source_id`, preserving the same-source surface invariant consumers rely on.
public fun replace_block_scholes_bindings_for_underlying(
    registry: &mut OracleRegistry,
    admin_cap: &RegistryAdminCap,
    spot_feed: &BlockScholesSpotFeed,
    forward_feed: &BlockScholesForwardFeed,
    svi_feed: &BlockScholesSVIFeed,
    propbook_underlying_id: u32,
) {
    let bs_source_id = block_scholes_spot_feed::bs_source_id(spot_feed);
    assert!(
        bs_source_id == block_scholes_forward_feed::bs_source_id(forward_feed),
        EWrongBlockScholesSource,
    );
    assert!(
        bs_source_id == block_scholes_svi_feed::bs_source_id(svi_feed),
        EWrongBlockScholesSource,
    );

    let spot_source_key = block_scholes_spot_source_key(bs_source_id);
    let forward_source_key = block_scholes_forward_source_key(bs_source_id);
    let svi_source_key = block_scholes_svi_source_key(bs_source_id);
    let spot_binding_key = block_scholes_spot_binding_key(propbook_underlying_id);
    let forward_binding_key = block_scholes_forward_binding_key(propbook_underlying_id);
    let svi_binding_key = block_scholes_svi_binding_key(propbook_underlying_id);

    registry.replace_oracle(
        admin_cap,
        spot_source_key,
        block_scholes_spot_feed::id(spot_feed),
        spot_binding_key,
    );
    registry.replace_oracle(
        admin_cap,
        forward_source_key,
        block_scholes_forward_feed::id(forward_feed),
        forward_binding_key,
    );
    registry.replace_oracle(
        admin_cap,
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

fun record_source(
    registry: &mut OracleRegistry,
    source_key: OracleSourceKey,
    propbook_oracle_id: ID,
) {
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
/// initial admin-controlled trust claim downstream consumers can discover.
fun bind_oracle(
    registry: &mut OracleRegistry,
    _admin_cap: &RegistryAdminCap,
    source_key: OracleSourceKey,
    propbook_oracle_id: ID,
    binding_key: OracleBindingKey,
) {
    let propbook_underlying_id = binding_key.propbook_underlying_id;
    registry.assert_registered_source_object(source_key, propbook_oracle_id);
    registry.assert_binding_available(binding_key);
    registry.assert_source_assignable(source_key, propbook_underlying_id);

    let metadata = OracleMetadata {
        propbook_underlying_id,
        oracle_kind: source_key.oracle_kind,
        source_id: source_key.source_id,
        propbook_oracle_id,
        value_kind: binding_key.value_kind,
    };
    registry.bindings.add(binding_key, metadata);
    registry.record_source_binding_if_missing(source_key, propbook_underlying_id);

    event::emit(OracleBound {
        propbook_underlying_id,
        oracle_kind: source_key.oracle_kind,
        source_id: source_key.source_id,
        propbook_oracle_id,
        value_kind: binding_key.value_kind,
    });
}

/// Replace one active binding without clearing the canonical key. Callers that
/// pass objects through the stable lookup APIs automatically follow the new ID.
fun replace_oracle(
    registry: &mut OracleRegistry,
    _admin_cap: &RegistryAdminCap,
    source_key: OracleSourceKey,
    propbook_oracle_id: ID,
    binding_key: OracleBindingKey,
) {
    let propbook_underlying_id = binding_key.propbook_underlying_id;
    registry.assert_binding_exists(binding_key);
    registry.assert_registered_source_object(source_key, propbook_oracle_id);
    registry.assert_source_assignable(source_key, propbook_underlying_id);

    let old_metadata = *registry.bindings.borrow(binding_key);
    let metadata = OracleMetadata {
        propbook_underlying_id,
        oracle_kind: source_key.oracle_kind,
        source_id: source_key.source_id,
        propbook_oracle_id,
        value_kind: binding_key.value_kind,
    };
    *registry.bindings.borrow_mut(binding_key) = metadata;
    registry.record_source_binding_if_missing(source_key, propbook_underlying_id);

    event::emit(OracleRebound {
        propbook_underlying_id,
        oracle_kind: source_key.oracle_kind,
        value_kind: binding_key.value_kind,
        old_source_id: old_metadata.source_id,
        old_propbook_oracle_id: old_metadata.propbook_oracle_id,
        new_source_id: source_key.source_id,
        new_propbook_oracle_id: propbook_oracle_id,
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

fun assert_binding_exists(registry: &OracleRegistry, binding_key: OracleBindingKey) {
    assert!(registry.bindings.contains(binding_key), EBindingNotFound);
}

fun assert_source_assignable(
    registry: &OracleRegistry,
    source_key: OracleSourceKey,
    propbook_underlying_id: u32,
) {
    if (registry.source_bindings.contains(source_key)) {
        assert!(
            *registry.source_bindings.borrow(source_key) == propbook_underlying_id,
            ESourceAlreadyBound,
        );
    };
}

fun record_source_binding_if_missing(
    registry: &mut OracleRegistry,
    source_key: OracleSourceKey,
    propbook_underlying_id: u32,
) {
    if (!registry.source_bindings.contains(source_key)) {
        registry.source_bindings.add(source_key, propbook_underlying_id);
    };
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
