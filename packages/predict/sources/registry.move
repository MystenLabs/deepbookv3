// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Registry, versioning, and creation entrypoints for the Predict protocol.
///
/// This module creates shared setup objects, stores admin-approved Propbook
/// underlying configs and the expiry uniqueness index, and exposes
/// registry-owned governance entrypoints. Runtime pool accounting, expiry risk,
/// oracle feeds, and user positions stay in their owning modules.
module deepbook_predict::registry;

use deepbook::registry::Registry as DeepbookRegistry;
use deepbook_predict::{
    admin::{Self, AdminCap},
    builder_code,
    config_constants,
    constants,
    expiry_market::{Self, ExpiryMarket},
    market_lifecycle_cap::{Self, MarketLifecycleCap, MarketLifecycleProof},
    pause_cap::{Self, PauseCap},
    plp::PoolVault,
    predict_deposit_cap::PredictDepositCap,
    predict_manager::{Self, PredictManager},
    predict_trade_cap::PredictTradeCap,
    predict_withdraw_cap::PredictWithdrawCap,
    protocol_config::{Self, ProtocolConfig}
};
use propbook::registry::OracleRegistry;
use sui::{clock::Clock, table::{Self, Table}, vec_set::{Self, VecSet}};

const EUnderlyingNotRegistered: u64 = 0;
const EUnderlyingAlreadyRegistered: u64 = 1;
const EInvalidExpiry: u64 = 2;
const EMarketAlreadyCreated: u64 = 3;
const EPauseCapNotValid: u64 = 4;
const EPackageVersionDisabled: u64 = 5;
const EVersionAlreadyEnabled: u64 = 6;
const EVersionNotEnabled: u64 = 7;
const ECannotDisableLastVersion: u64 = 8;
const EInvalidMarketTickSize: u64 = 9;
const ELifecycleCapNotValid: u64 = 10;
const ELifecycleCapNotFound: u64 = 11;
const EPythFeedNotBoundToUnderlying: u64 = 12;
const EBlockScholesFeedNotBoundToUnderlying: u64 = 13;
const EExpiryNotOnResolutionGrid: u64 = 14;

/// Registry-owned config for one admin-approved Propbook underlying.
public struct UnderlyingConfig has copy, drop, store {
    /// Minimum tick size for markets on this underlying. A market may choose this
    /// value or a 10x multiple above it.
    min_tick_size: u64,
}

/// Market uniqueness key. Predict permits one market per Propbook underlying and
/// expiry; the market's chosen tick size is committed by the first creation.
public struct MarketKey has copy, drop, store {
    propbook_underlying_id: u32,
    expiry: u64,
}

/// Shared registry for underlying admission and expiry uniqueness.
public struct Registry has key {
    id: UID,
    /// Propbook underlying ID -> admin-approved minimum market tick size.
    underlying_configs: Table<u32, UnderlyingConfig>,
    /// Created markets keyed by `(propbook_underlying_id, expiry)`.
    market_ids: Table<MarketKey, ID>,
    /// IDs of `PauseCap` objects currently authorized to use pause-only entries.
    /// Admin mints into this set and revokes from it.
    allowed_pause_caps: VecSet<ID>,
    /// IDs of `MarketLifecycleCap` objects currently authorized for market
    /// lifecycle entries (market creation). Admin mints into this set and
    /// revokes from it.
    allowed_lifecycle_caps: VecSet<ID>,
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

/// Return the configured minimum tick size for a Propbook underlying, if
/// registered.
public fun underlying_min_tick_size(registry: &Registry, propbook_underlying_id: u32): Option<u64> {
    if (registry.underlying_configs.contains(propbook_underlying_id)) {
        option::some(registry.underlying_configs.borrow(propbook_underlying_id).min_tick_size)
    } else {
        option::none()
    }
}

/// Return the expiry market ID for `(propbook_underlying_id, expiry)`, if one
/// has been created.
public fun expiry_market_id(
    registry: &Registry,
    propbook_underlying_id: u32,
    expiry: u64,
): Option<ID> {
    let key = MarketKey { propbook_underlying_id, expiry };
    if (registry.market_ids.contains(key)) {
        option::some(*registry.market_ids.borrow(key))
    } else {
        option::none()
    }
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

// === PauseCap Lifecycle (admin) ===

/// Mint a new `PauseCap`. Admin-only and bypasses the version gate so the
/// kill switch remains available even when admin has misconfigured versions.
public fun mint_pause_cap(
    registry: &mut Registry,
    _admin_cap: &AdminCap,
    ctx: &mut TxContext,
): PauseCap {
    let cap = pause_cap::new(ctx);
    registry.allowed_pause_caps.insert(cap.id());
    cap
}

/// Revoke a previously minted `PauseCap` by ID. Admin-only.
public fun revoke_pause_cap(registry: &mut Registry, _admin_cap: &AdminCap, pause_cap_id: ID) {
    assert!(registry.allowed_pause_caps.contains(&pause_cap_id), EPauseCapNotValid);
    registry.allowed_pause_caps.remove(&pause_cap_id);
}

// === MarketLifecycleCap Lifecycle (admin) ===

/// Mint a new `MarketLifecycleCap`. Admin-only and version-gated (granting
/// market-creation authority under a version freeze is the risky direction).
public fun mint_lifecycle_cap(
    registry: &mut Registry,
    _admin_cap: &AdminCap,
    ctx: &mut TxContext,
): MarketLifecycleCap {
    registry.assert_version_allowed();
    let cap = market_lifecycle_cap::new(ctx);
    registry.allowed_lifecycle_caps.insert(cap.id());
    cap
}

/// Revoke a previously minted `MarketLifecycleCap` by ID. Admin-only.
/// Deliberately not version-gated (like pause-cap revocation): revocation is
/// harm-reducing and must stay available even when per-object version mirrors
/// transiently disagree with the gates on this cap's lifecycle entries.
public fun revoke_lifecycle_cap(
    registry: &mut Registry,
    _admin_cap: &AdminCap,
    lifecycle_cap_id: ID,
) {
    // Distinct from the gate code so expected_failure tests that revoke first
    // stay pinned to the create gate under test.
    assert!(registry.allowed_lifecycle_caps.contains(&lifecycle_cap_id), ELifecycleCapNotFound);
    registry.allowed_lifecycle_caps.remove(&lifecycle_cap_id);
}

/// Generate a transaction-local proof that `lifecycle_cap` is currently
/// allowlisted. Consumers take the proof by value so a revoked lifecycle cap
/// cannot authorize cross-module lifecycle actions.
public fun generate_lifecycle_proof(
    registry: &Registry,
    lifecycle_cap: &MarketLifecycleCap,
): MarketLifecycleProof {
    registry.assert_valid_lifecycle_cap(lifecycle_cap);
    lifecycle_cap.new_proof()
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

/// Record admin approval of one Propbook underlying and its minimum market tick
/// size. Source IDs and canonical oracle object IDs remain owned by Propbook;
/// this row only gates which underlyings Predict will build markets on and the
/// smallest tick size those markets may choose.
public fun register_underlying(
    registry: &mut Registry,
    _admin_cap: &AdminCap,
    propbook_underlying_id: u32,
    min_tick_size: u64,
) {
    registry.assert_version_allowed();
    assert!(
        !registry.underlying_configs.contains(propbook_underlying_id),
        EUnderlyingAlreadyRegistered,
    );
    config_constants::assert_market_tick_size_bounds(min_tick_size);
    registry.underlying_configs.add(propbook_underlying_id, UnderlyingConfig { min_tick_size });
}

/// Create the ExpiryMarket for one future expiry on a Propbook underlying.
///
/// The registry enforces one market per `(propbook_underlying_id, expiry)`, that
/// the underlying is admin-approved for Predict, that the chosen tick size is a
/// valid 10x multiple of the underlying's minimum, and — via Propbook's
/// admin-gated canonical binding — that both required oracle kinds are currently
/// bound for the underlying. The market snapshots only the underlying and its
/// tick size; priced flows resolve the current canonical oracle object IDs from
/// Propbook so a Propbook rebind affects existing markets. The market is created
/// with zero cash and registered with the pool vault as an accounting row only;
/// it is not mintable until `plp::rebalance_expiry_cash` funds it.
///
/// `expiry` must fall on the resolution-feed grid (`expiry %
/// constants::resolution_period_ms!() == 0`). Terminal settlement reads the exact
/// Pyth observation keyed at `expiry`, which the off-chain resolution relayer
/// publishes only on that grid; an off-grid expiry could never settle. While a
/// past-expiry market is awaiting its settling observation it has no solvency-safe
/// NAV, so the pool flush (`plp::value_expiry`) aborts until the observation lands
/// — the keeper retries and does not flush while an active market is in that
/// pending-settlement window (bounded to a few seconds at the grid cadence).
public fun create_expiry_market(
    registry: &mut Registry,
    pool_vault: &mut PoolVault,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    lifecycle_cap: &MarketLifecycleCap,
    propbook_underlying_id: u32,
    expiry: u64,
    tick_size: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    registry.assert_version_allowed();
    registry.assert_valid_lifecycle_cap(lifecycle_cap);
    config.assert_trading_allowed();
    assert!(expiry > clock.timestamp_ms(), EInvalidExpiry);
    // Expiry must land on the resolution-feed grid so the exact-ms settling Pyth
    // observation is always producible; an off-grid expiry could never settle and
    // would block the pool flush indefinitely.
    assert!(expiry % constants::resolution_period_ms!() == 0, EExpiryNotOnResolutionGrid);
    let market_key = MarketKey { propbook_underlying_id, expiry };
    let min_tick_size = registry.assert_underlying_registered(propbook_underlying_id);
    assert_market_tick_size(min_tick_size, tick_size);
    assert!(
        propbook_registry.propbook_pyth_id_for_underlying(propbook_underlying_id).is_some(),
        EPythFeedNotBoundToUnderlying,
    );
    assert!(
        propbook_registry
            .propbook_block_scholes_id_for_underlying(propbook_underlying_id)
            .is_some(),
        EBlockScholesFeedNotBoundToUnderlying,
    );
    assert!(!registry.market_ids.contains(market_key), EMarketAlreadyCreated);
    let allowed_versions = registry.allowed_versions;
    let expiry_market_id = expiry_market::create_and_share(
        config,
        allowed_versions,
        propbook_underlying_id,
        pool_vault.id(),
        expiry,
        tick_size,
        ctx,
    );
    pool_vault.register_expiry(expiry_market_id);
    registry.market_ids.add(market_key, expiry_market_id);

    expiry_market_id
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

/// Create a derived self-owned PredictManager for callers that don't want a
/// deployer-key trust anchor (vaults, structured products). The inner
/// BalanceManager owner is set to the manager's own ID-as-address, so the
/// returned caps are the only authority that will ever exist on this manager.
///
/// Requires `PredictApp` to be authorized on the deepbook `Registry` via
/// `deepbook::registry::authorize_app<PredictApp>` — a one-time admin tx on
/// the deepbook side.
public fun create_self_owned_manager(
    registry: &mut Registry,
    deepbook_registry: &DeepbookRegistry,
    ctx: &mut TxContext,
): (PredictManager, PredictDepositCap, PredictWithdrawCap, PredictTradeCap) {
    predict_manager::new_self_owned(&mut registry.id, deepbook_registry, ctx)
}

// === Private Functions ===

/// Abort if the running package version is not in the allowed set.
///
/// Bypasses are package-internal version-management entries
/// (`enable_version`, `disable_version`, PauseCap-based disables) so admin
/// can recover from any disabled state.
fun assert_version_allowed(registry: &Registry) {
    assert!(
        registry.allowed_versions.contains(&constants::current_version!()),
        EPackageVersionDisabled,
    );
}

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
            underlying_configs: table::new(ctx),
            market_ids: table::new(ctx),
            allowed_pause_caps: vec_set::empty(),
            allowed_lifecycle_caps: vec_set::empty(),
            allowed_versions: vec_set::singleton(constants::current_version!()),
        },
        admin::new(ctx),
    )
}

/// Abort unless the supplied `PauseCap` was minted by admin and not revoked.
fun assert_valid_pause_cap(registry: &Registry, pause_cap: &PauseCap) {
    assert!(registry.allowed_pause_caps.contains(&pause_cap.id()), EPauseCapNotValid);
}

/// Abort unless the supplied `MarketLifecycleCap` was minted by admin and not
/// revoked.
fun assert_valid_lifecycle_cap(registry: &Registry, cap: &MarketLifecycleCap) {
    assert!(registry.allowed_lifecycle_caps.contains(&cap.id()), ELifecycleCapNotValid);
}

fun assert_underlying_registered(registry: &Registry, propbook_underlying_id: u32): u64 {
    assert!(registry.underlying_configs.contains(propbook_underlying_id), EUnderlyingNotRegistered);
    registry.underlying_configs.borrow(propbook_underlying_id).min_tick_size
}

fun assert_market_tick_size(min_tick_size: u64, tick_size: u64) {
    config_constants::assert_market_tick_size_bounds(tick_size);
    assert!(tick_size >= min_tick_size, EInvalidMarketTickSize);
    let mut allowed = min_tick_size;
    while (allowed < tick_size) {
        allowed = allowed * 10;
    };
    assert!(allowed == tick_size, EInvalidMarketTickSize);
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

// `new_for_testing` and `destroy_registry_drop_for_testing` removed: tests use
// the production-mirroring `init_for_testing` shared-object path instead.
