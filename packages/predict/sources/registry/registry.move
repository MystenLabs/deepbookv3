// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Registry and creation entrypoints for the Predict protocol.
///
/// This module creates shared setup objects, owns registry-level capabilities,
/// and exposes registry-owned governance/creation entrypoints. Market identity,
/// cadence policy, underlying watermarks, and market uniqueness live in the
/// embedded `market_manager`. Runtime pool accounting, expiry risk, oracle feeds,
/// and user positions stay in their owning modules.
module deepbook_predict::registry;

use deepbook_predict::{
    admin::{Self, AdminCap},
    builder_code,
    config_events,
    expiry_market::{Self, ExpiryMarket},
    market_lifecycle_cap::{Self, MarketLifecycleCap, MarketLifecycleProof},
    market_manager::{Self, MarketManager},
    pause_cap::{Self, PauseCap},
    plp::PoolVault,
    protocol_config::{Self, ProtocolConfig}
};
use propbook::registry::OracleRegistry;
use sui::{clock::Clock, vec_set::{Self, VecSet}};

const EPauseCapNotValid: u64 = 0;
const ELifecycleCapNotValid: u64 = 1;
const ELifecycleCapNotFound: u64 = 2;

/// Shared registry for setup, capabilities, and market creation entrypoints.
public struct Registry has key {
    id: UID,
    /// Market identity, cadence deployment terms, underlying watermarks, and uniqueness.
    market_manager: MarketManager,
    /// IDs of `PauseCap` objects currently authorized to use pause-only entries.
    /// Admin mints into this set and revokes from it.
    allowed_pause_caps: VecSet<ID>,
    /// IDs of `MarketLifecycleCap` objects currently authorized for privileged
    /// lifecycle entries such as market creation and full-pool valuation. Admin
    /// mints into this set and revokes from it.
    allowed_lifecycle_caps: VecSet<ID>,
}

// === Public Functions ===

/// Return the registry object ID.
public fun id(registry: &Registry): ID {
    registry.id.to_inner()
}

/// Return the expiry market ID for `(propbook_underlying_id, expiry)`, if one
/// has been created.
public fun expiry_market_id(
    registry: &Registry,
    propbook_underlying_id: u32,
    expiry: u64,
): Option<ID> {
    registry.market_manager.expiry_market_id(propbook_underlying_id, expiry)
}

/// Return `(tick_size, max_expiry_allocation, window_size)` for a cadence.
public fun cadence_config(registry: &Registry, cadence_id: u8): (u64, u64, u64) {
    registry.market_manager.cadence_config(cadence_id)
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

/// Mint a new `MarketLifecycleCap`. Admin-only and version-gated because
/// granting privileged lifecycle authority under a version freeze is risky.
public fun mint_lifecycle_cap(
    registry: &mut Registry,
    config: &ProtocolConfig,
    _admin_cap: &AdminCap,
    ctx: &mut TxContext,
): MarketLifecycleCap {
    config.assert_version();
    let cap = market_lifecycle_cap::new(ctx);
    registry.allowed_lifecycle_caps.insert(cap.id());
    cap
}

/// Revoke a previously minted `MarketLifecycleCap` by ID. Admin-only.
/// Deliberately not version-gated (like pause-cap revocation): revocation is
/// harm-reducing and must stay available even when the running package version
/// is frozen below the protocol watermark.
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

/// Record admin approval of one Propbook underlying. Source IDs and canonical
/// oracle object IDs remain owned by Propbook; this row only gates which
/// underlyings Predict will build markets on and stores deployment watermarks.
public fun register_underlying(
    registry: &mut Registry,
    config: &ProtocolConfig,
    _admin_cap: &AdminCap,
    propbook_underlying_id: u32,
) {
    config.assert_version();
    registry.market_manager.register_underlying(propbook_underlying_id);
}

/// Set all deployment terms for one cadence. Passing zero for all three values
/// disables the cadence; otherwise all values must be nonzero and valid.
public fun set_cadence_config(
    registry: &mut Registry,
    config: &ProtocolConfig,
    _admin_cap: &AdminCap,
    cadence_id: u8,
    tick_size: u64,
    max_expiry_allocation: u64,
    window_size: u64,
) {
    config.assert_version();
    registry
        .market_manager
        .set_cadence_config(cadence_id, tick_size, max_expiry_allocation, window_size);
    config_events::emit_cadence_config_updated(
        registry.id(),
        cadence_id,
        tick_size,
        max_expiry_allocation,
        window_size,
    );
}

/// Create the next deployable `ExpiryMarket` for one cadence on a Propbook underlying.
///
/// Requires an allowlisted `MarketLifecycleCap`. The market manager enforces one
/// market per `(propbook_underlying_id, expiry)`, that the underlying is
/// admin-approved for Predict, that the cadence is enabled and inside its
/// deployment window after skipping enabled higher-rank cadence slots, and — via
/// Propbook's admin-gated canonical binding — that both
/// required oracle kinds are currently bound for the underlying. The market
/// snapshots the cadence tick size, while pool accounting snapshots the cadence
/// allocation cap. Priced flows resolve current canonical oracle object IDs from
/// Propbook so a Propbook rebind affects existing markets. The market is created
/// with zero cash and registered with the pool vault as an accounting row only; it
/// is not mintable until `plp::rebalance_expiry_cash` funds it.
public fun create_expiry_market(
    registry: &mut Registry,
    pool_vault: &mut PoolVault,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    lifecycle_cap: &MarketLifecycleCap,
    propbook_underlying_id: u32,
    cadence_id: u8,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    config.assert_version();
    registry.assert_valid_lifecycle_cap(lifecycle_cap);
    config.assert_trading_allowed();
    config.assert_not_valuation_in_progress();
    let (expiry, tick_size, max_expiry_allocation) = registry
        .market_manager
        .next_deployable_market(propbook_registry, propbook_underlying_id, cadence_id, clock);
    let pool_vault_id = pool_vault.id();
    let expiry_market_id = expiry_market::create_and_share(
        config,
        propbook_underlying_id,
        expiry,
        tick_size,
        ctx,
    );
    pool_vault.register_expiry(expiry_market_id, max_expiry_allocation);
    registry
        .market_manager
        .record_expiry_creation(propbook_underlying_id, cadence_id, expiry, expiry_market_id);
    config_events::emit_market_created(
        expiry_market_id,
        pool_vault_id,
        propbook_underlying_id,
        expiry,
        tick_size,
        max_expiry_allocation,
    );

    expiry_market_id
}

/// Create a derived shared BuilderCode for the caller and index.
public fun create_builder_code(
    registry: &mut Registry,
    config: &ProtocolConfig,
    index: u64,
    ctx: &mut TxContext,
): ID {
    config.assert_version();
    builder_code::create_and_share(&mut registry.id, index, ctx)
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
            market_manager: market_manager::new(ctx),
            allowed_pause_caps: vec_set::empty(),
            allowed_lifecycle_caps: vec_set::empty(),
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
