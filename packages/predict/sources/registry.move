// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Registry, versioning, and creation entrypoints for the Predict protocol.
///
/// This module creates shared setup objects, stores uniqueness indexes for
/// Pyth sources and expiries, and exposes registry-owned governance entrypoints. Runtime
/// pool accounting, expiry risk, oracle state, and user positions stay in their
/// owning modules.
module deepbook_predict::registry;

use deepbook_predict::{
    admin::{Self, AdminCap},
    builder_code,
    config_constants,
    config_events,
    constants,
    expiry_market::{Self, ExpiryMarket},
    market_oracle::{Self, MarketOracle, MarketOracleCap},
    plp::PoolVault,
    predict_manager::{Self, PredictManager},
    pricing,
    protocol_config::{Self, ProtocolConfig},
    pyth_source::{Self, PythSource}
};
use sui::{clock::Clock, table::{Self, Table}, vec_set::{Self, VecSet}};

const EFeedIdMismatch: u64 = 0;
const EPythSourceAlreadyCreated: u64 = 1;
const EInvalidExpiry: u64 = 2;
const EExpiryMarketAlreadyCreated: u64 = 3;
const EPauseCapNotValid: u64 = 4;
const EPackageVersionDisabled: u64 = 5;
const EVersionAlreadyEnabled: u64 = 6;
const EVersionNotEnabled: u64 = 7;
const ECannotDisableLastVersion: u64 = 8;
const EPythFeedNotRegistered: u64 = 9;

/// Registry-owned config for one Pyth Lazer feed.
public struct PythFeedConfig has copy, drop, store {
    /// Shared PythSource object bound to the feed.
    pyth_source_id: ID,
    /// Admin-selected strike tick size for future expiries.
    tick_size: u64,
    /// Fee multiplier reached at expiry, in FLOAT_SCALING; 1x disables. Snapshotted into
    /// each market at creation. The ramp window is `constants::expiry_fee_window_ms!()`.
    expiry_fee_max_multiplier: u64,
}

/// Capability for emergency pause operations. Admin can mint these for
/// trusted operators; holders can disable versions, pause global trading,
/// and pause per-market minting. Cannot unpause anything.
public struct PauseCap has key, store {
    id: UID,
}

/// Shared registry for source and expiry uniqueness.
public struct Registry has key {
    id: UID,
    /// Pyth Lazer feed ID -> source object and creation-time market config.
    pyth_feed_configs: Table<u32, PythFeedConfig>,
    /// Created expiry markets keyed by expiry timestamp.
    expiry_market_ids: Table<u64, ID>,
    /// IDs of `PauseCap` objects currently authorized to use pause-only entries.
    /// Admin mints into this set and revokes from it.
    allowed_pause_caps: VecSet<ID>,
    /// Package versions currently permitted to mutate per-pool state. Authoritative
    /// source; pool objects mirror this set and refresh via permissionless sync.
    allowed_versions: VecSet<u64>,
}

// === Public Functions ===

/// Return the registry object ID.
public fun id(registry: &Registry): ID {
    registry.id.to_inner()
}

/// Return the set of package versions currently permitted to mutate per-pool
/// state. Pool sync helpers snapshot this; newly-created pools inherit it.
public fun allowed_versions(registry: &Registry): VecSet<u64> {
    registry.allowed_versions
}

/// Return the shared PythSource ID for a feed, if it has been created.
public fun pyth_source_id(registry: &Registry, pyth_lazer_feed_id: u32): Option<ID> {
    if (registry.pyth_feed_configs.contains(pyth_lazer_feed_id)) {
        option::some(registry.pyth_feed_configs.borrow(pyth_lazer_feed_id).pyth_source_id)
    } else {
        option::none()
    }
}

/// Return the configured strike tick size for a Pyth Lazer feed, if registered.
public fun pyth_feed_tick_size(registry: &Registry, pyth_lazer_feed_id: u32): Option<u64> {
    if (registry.pyth_feed_configs.contains(pyth_lazer_feed_id)) {
        option::some(registry.pyth_feed_configs.borrow(pyth_lazer_feed_id).tick_size)
    } else {
        option::none()
    }
}

/// Return the configured expiry-fee max multiplier for a Pyth Lazer feed, if registered.
public fun pyth_feed_expiry_fee_max_multiplier(
    registry: &Registry,
    pyth_lazer_feed_id: u32,
): Option<u64> {
    if (registry.pyth_feed_configs.contains(pyth_lazer_feed_id)) {
        option::some(registry
            .pyth_feed_configs
            .borrow(pyth_lazer_feed_id)
            .expiry_fee_max_multiplier)
    } else {
        option::none()
    }
}

/// Set the per-asset expiry-fee max multiplier snapshotted by future expiry markets
/// for one Pyth feed. `max_multiplier` (FLOAT_SCALING, 1x disables) is the multiplier
/// reached at expiry over the `constants::expiry_fee_window_ms!()` ramp window. Larger
/// values suit more volatile assets.
public fun set_pyth_feed_expiry_fee_max_multiplier(
    registry: &mut Registry,
    _admin_cap: &AdminCap,
    pyth_lazer_feed_id: u32,
    max_multiplier: u64,
) {
    assert!(registry.pyth_feed_configs.contains(pyth_lazer_feed_id), EPythFeedNotRegistered);
    config_constants::assert_expiry_fee_max_multiplier(max_multiplier);
    registry.pyth_feed_configs.borrow_mut(pyth_lazer_feed_id).expiry_fee_max_multiplier =
        max_multiplier;
}

/// Set the strike tick size used by future expiry markets for one Pyth feed.
public fun set_pyth_feed_tick_size(
    registry: &mut Registry,
    _admin_cap: &AdminCap,
    pyth_lazer_feed_id: u32,
    tick_size: u64,
) {
    assert!(registry.pyth_feed_configs.contains(pyth_lazer_feed_id), EPythFeedNotRegistered);
    config_constants::assert_oracle_tick_size(tick_size);
    registry.pyth_feed_configs.borrow_mut(pyth_lazer_feed_id).tick_size = tick_size;
}

// === Version Management (admin) ===

/// Add `version` to the registry's allowed set.
///
/// Not version-gated so admin can re-enable a previously disabled version.
public fun enable_version(registry: &mut Registry, _admin_cap: &AdminCap, version: u64) {
    assert!(!registry.allowed_versions.contains(&version), EVersionAlreadyEnabled);
    registry.allowed_versions.insert(version);
}

/// Remove `version` from the registry's allowed set.
///
/// Not version-gated so admin can revoke a version even after the active
/// version has been paused. The set may not be left empty.
public fun disable_version(registry: &mut Registry, _admin_cap: &AdminCap, version: u64) {
    registry.disable_version_internal(version);
}

// === Version Sync (permissionless) ===
//
// Each shared object that gates flows on a mirrored `allowed_versions` set
// exposes one `sync_*` entry below. The registry is the source of truth: the
// caller supplies `&Registry`, and the entry copies its current set into the
// target. The package-internal `set_allowed_versions` setters on the target
// modules are not callable from outside the package, so user-supplied
// `VecSet<u64>` cannot reach a mirror through any other path.

/// Sync an expiry market's `allowed_versions` mirror from the registry.
public fun sync_expiry_market_allowed_versions(registry: &Registry, market: &mut ExpiryMarket) {
    market.set_allowed_versions(registry.allowed_versions);
}

/// Sync a pool vault's `allowed_versions` mirror from the registry.
public fun sync_pool_vault_allowed_versions(registry: &Registry, vault: &mut PoolVault) {
    vault.set_allowed_versions(registry.allowed_versions);
}

/// Sync a market oracle's `allowed_versions` mirror from the registry.
public fun sync_market_oracle_allowed_versions(registry: &Registry, market: &mut MarketOracle) {
    market.set_allowed_versions(registry.allowed_versions);
}

/// Sync a Pyth source's `allowed_versions` mirror from the registry.
public fun sync_pyth_source_allowed_versions(registry: &Registry, source: &mut PythSource) {
    source.set_allowed_versions(registry.allowed_versions);
}

// === PauseCap Lifecycle (admin) ===

/// Mint a new `PauseCap`. Admin-only and bypasses the version gate so the
/// kill switch remains available even when admin has misconfigured versions.
public fun mint_pause_cap(
    registry: &mut Registry,
    _admin_cap: &AdminCap,
    ctx: &mut TxContext,
): PauseCap {
    let id = object::new(ctx);
    registry.allowed_pause_caps.insert(id.to_inner());
    PauseCap { id }
}

/// Revoke a previously minted `PauseCap` by ID. Admin-only.
public fun revoke_pause_cap(registry: &mut Registry, _admin_cap: &AdminCap, pause_cap_id: ID) {
    assert!(registry.allowed_pause_caps.contains(&pause_cap_id), EPauseCapNotValid);
    registry.allowed_pause_caps.remove(&pause_cap_id);
}

/// Destroy a `PauseCap` the holder no longer needs.
public fun destroy_pause_cap(cap: PauseCap) {
    let PauseCap { id } = cap;
    id.delete();
}

// === Emergency Pause (PauseCap) ===

/// Disable a package version via a valid `PauseCap`. One-way: admin must
/// `enable_version` to restore.
public fun disable_version_pause_cap(registry: &mut Registry, pause_cap: &PauseCap, version: u64) {
    registry.assert_valid_pause_cap(pause_cap);
    registry.disable_version_internal(version);
}

/// Force `trading_paused = true` via a valid `PauseCap`. One-way.
public fun pause_trading_pause_cap(
    config: &mut ProtocolConfig,
    registry: &Registry,
    pause_cap: &PauseCap,
) {
    registry.assert_valid_pause_cap(pause_cap);
    config.pause_trading();
}

/// Force `mint_paused = true` on a single expiry market via a valid `PauseCap`.
/// One-way; admin's `expiry_market::set_mint_paused` is needed to unpause.
public fun pause_expiry_market_mint_pause_cap(
    market: &mut ExpiryMarket,
    registry: &Registry,
    pause_cap: &PauseCap,
) {
    registry.assert_valid_pause_cap(pause_cap);
    market.pause_mint();
}

/// Create a shared Pyth source for one admin-approved Lazer feed, configuring
/// the per-asset expiry-fee max multiplier up front (1x disables the ramp).
///
/// The registry enforces one source object per feed ID.
public fun create_pyth_source(
    registry: &mut Registry,
    _admin_cap: &AdminCap,
    pyth_lazer_feed_id: u32,
    tick_size: u64,
    expiry_fee_max_multiplier: u64,
    ctx: &mut TxContext,
): ID {
    registry.assert_version_allowed();
    assert!(!registry.pyth_feed_configs.contains(pyth_lazer_feed_id), EPythSourceAlreadyCreated);
    config_constants::assert_oracle_tick_size(tick_size);
    config_constants::assert_expiry_fee_max_multiplier(expiry_fee_max_multiplier);
    let pyth_source_id = pyth_source::create_and_share(
        pyth_lazer_feed_id,
        registry.allowed_versions,
        ctx,
    );
    registry
        .pyth_feed_configs
        .add(
            pyth_lazer_feed_id,
            PythFeedConfig {
                pyth_source_id,
                tick_size,
                expiry_fee_max_multiplier,
            },
        );
    pyth_source_id
}

/// Create the MarketOracle and ExpiryMarket objects for one future expiry.
///
/// The registry enforces one market per expiry, validates the registered Pyth
/// source, and registers the expiry as active. Pool funding happens later through
/// PLP rebalancing.
public fun create_expiry_market(
    registry: &mut Registry,
    pool_vault: &mut PoolVault,
    config: &ProtocolConfig,
    pyth: &PythSource,
    cap: &MarketOracleCap,
    expiry: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (ID, ID) {
    registry.assert_version_allowed();
    config.assert_trading_allowed();
    assert!(expiry > clock.timestamp_ms(), EInvalidExpiry);
    let pyth_lazer_feed_id = pyth.feed_id();
    assert!(registry.pyth_feed_configs.contains(pyth_lazer_feed_id), EFeedIdMismatch);
    let pyth_config = registry.pyth_feed_configs.borrow(pyth_lazer_feed_id);
    assert!(pyth_config.pyth_source_id == pyth.id(), EFeedIdMismatch);
    let tick_size = pyth_config.tick_size;
    let expiry_fee_max_multiplier = pyth_config.expiry_fee_max_multiplier;
    pricing::assert_pyth_spot_fresh(config.pricing_config(), pyth, clock);
    let min_strike = centered_min_strike(pyth.spot(), tick_size);
    let preallocated_ticks = expiry_preallocated_ticks(expiry, clock.timestamp_ms());
    assert!(!registry.expiry_market_ids.contains(expiry), EExpiryMarketAlreadyCreated);
    let allowed_versions = registry.allowed_versions;
    let market_oracle_id = market_oracle::create_and_share(
        pyth,
        config.market_oracle_config(),
        cap,
        expiry,
        allowed_versions,
        ctx,
    );
    let expiry_market_id = expiry_market::create_and_share(
        config,
        allowed_versions,
        market_oracle_id,
        pyth_lazer_feed_id,
        expiry,
        min_strike,
        tick_size,
        preallocated_ticks,
        expiry_fee_max_multiplier,
        ctx,
    );
    pool_vault.register_expiry_market(expiry_market_id);
    registry.expiry_market_ids.add(expiry, expiry_market_id);

    config_events::emit_market_created(
        expiry_market_id,
        market_oracle_id,
        pool_vault.id(),
        expiry,
        min_strike,
        tick_size,
    );

    (expiry_market_id, market_oracle_id)
}

/// Create a derived shared BuilderCode for the caller and index.
public fun create_builder_code(registry: &mut Registry, index: u64, ctx: &mut TxContext): ID {
    builder_code::create_and_share(&mut registry.id, index, ctx)
}

/// Create a derived PredictManager for the caller.
public fun create_manager(registry: &mut Registry, ctx: &mut TxContext): PredictManager {
    predict_manager::new(&mut registry.id, ctx)
}

/// Create and share a derived PredictManager for the caller.
public fun create_and_share_manager(registry: &mut Registry, ctx: &mut TxContext) {
    create_manager(registry, ctx).share();
}

// === Public-Package Functions ===

/// Abort if the running package version is not in the allowed set.
///
/// Bypasses are package-internal version-management entries
/// (`enable_version`, `disable_version`, PauseCap-based disables) so admin
/// can recover from any disabled state.
public(package) fun assert_version_allowed(registry: &Registry) {
    assert!(
        registry.allowed_versions.contains(&constants::current_version!()),
        EPackageVersionDisabled,
    );
}

// === Private Functions ===

/// Package initializer - creates Registry and AdminCap.
fun init(ctx: &mut TxContext) {
    let (registry, admin_cap) = new_registry_and_admin_cap(ctx);
    protocol_config::create_and_share(ctx);
    transfer::share_object(registry);
    transfer::public_transfer(admin_cap, ctx.sender());
}

/// Construct registry and admin cap during package init or tests.
fun new_registry_and_admin_cap(ctx: &mut TxContext): (Registry, AdminCap) {
    (
        Registry {
            id: object::new(ctx),
            pyth_feed_configs: table::new(ctx),
            expiry_market_ids: table::new(ctx),
            allowed_pause_caps: vec_set::empty(),
            allowed_versions: vec_set::singleton(constants::current_version!()),
        },
        admin::new(ctx),
    )
}

/// Abort unless the supplied `PauseCap` was minted by admin and not revoked.
fun assert_valid_pause_cap(registry: &Registry, pause_cap: &PauseCap) {
    assert!(registry.allowed_pause_caps.contains(&pause_cap.id.to_inner()), EPauseCapNotValid);
}

/// Floor spot to the configured tick and center the fixed oracle grid around it.
fun centered_min_strike(spot: u64, tick_size: u64): u64 {
    config_constants::assert_oracle_tick_size_covers_spot(tick_size, spot);
    let center_ticks = constants::oracle_strike_grid_ticks!() / 2;

    (spot / tick_size - center_ticks) * tick_size
}

fun expiry_preallocated_ticks(expiry: u64, now_ms: u64): u64 {
    let time_to_expiry = expiry - now_ms;
    if (time_to_expiry <= constants::short_expiry_preallocation_window_ms!()) {
        constants::short_expiry_preallocated_ticks!()
    } else if (time_to_expiry <= constants::medium_expiry_preallocation_window_ms!()) {
        constants::medium_expiry_preallocated_ticks!()
    } else {
        constants::default_expiry_preallocated_ticks!()
    }
}

/// Remove a version from the allowed set, enforcing the non-empty invariant.
/// Shared by the admin `disable_version` and PauseCap `disable_version_pause_cap`.
fun disable_version_internal(registry: &mut Registry, version: u64) {
    assert!(registry.allowed_versions.contains(&version), EVersionNotEnabled);
    assert!(registry.allowed_versions.length() > 1, ECannotDisableLastVersion);
    registry.allowed_versions.remove(&version);
}

// === Test-Only Functions ===

#[test_only]
/// Initialize registry and admin cap for tests, returning the registry ID.
public fun init_for_testing(ctx: &mut TxContext): ID {
    let (registry, admin_cap) = new_registry_and_admin_cap(ctx);
    let registry_id = registry.id();
    protocol_config::create_and_share(ctx);
    transfer::share_object(registry);
    transfer::public_transfer(admin_cap, ctx.sender());

    registry_id
}

#[test_only]
/// Return a Registry + AdminCap without sharing or storing the registry.
/// Use this when a test wants direct access without `test_scenario`.
public fun new_for_testing(ctx: &mut TxContext): (Registry, AdminCap) {
    new_registry_and_admin_cap(ctx)
}

#[test_only]
public fun destroy_registry_for_testing(registry: Registry) {
    let Registry {
        id,
        pyth_feed_configs,
        expiry_market_ids,
        allowed_pause_caps: _,
        allowed_versions: _,
    } = registry;
    id.delete();
    pyth_feed_configs.destroy_empty();
    expiry_market_ids.destroy_empty();
}

/// Variant for tests that exercise registration paths: drops the uniqueness
/// tables without requiring them to be empty.
#[test_only]
public fun destroy_registry_drop_for_testing(registry: Registry) {
    let Registry {
        id,
        pyth_feed_configs,
        expiry_market_ids,
        allowed_pause_caps: _,
        allowed_versions: _,
    } = registry;
    id.delete();
    pyth_feed_configs.drop();
    expiry_market_ids.drop();
}
