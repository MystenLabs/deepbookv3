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
    market_manager::{Self, CadenceConfig, MarketManager},
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

/// Return the registry object ID for external discovery and PTB construction.
public fun id(registry: &Registry): ID {
    registry.id.to_inner()
}

/// Resolve an expiry market ID for external discovery and PTB construction.
public fun expiry_market_id(
    registry: &Registry,
    propbook_underlying_id: u32,
    expiry: u64,
): Option<ID> {
    registry.market_manager.expiry_market_id(propbook_underlying_id, expiry)
}

/// Return deployment policy for SDK and devInspect market discovery.
public fun cadence_config(
    registry: &Registry,
    propbook_underlying_id: u32,
    cadence_id: u8,
): CadenceConfig {
    registry.market_manager.cadence_config(propbook_underlying_id, cadence_id)
}

/// Return one underlying's complete deployment policy as a single coherent
/// snapshot, for off-chain consumers (SDK and devInspect cadence discovery by
/// the keeper, price updater, and dashboard) that would otherwise need one
/// read per cadence. The vector holds one entry per supported cadence, indexed
/// by cadence ID; disabled cadences are present as their all-zero
/// configuration. Aborts if the underlying is not registered.
public fun cadence_configs(
    registry: &Registry,
    propbook_underlying_id: u32,
): vector<CadenceConfig> {
    registry.market_manager.cadence_configs(propbook_underlying_id)
}

// === PauseCap Lifecycle (admin) ===

/// Mint a new `PauseCap`. This bypasses the version gate so emergency pause
/// authority remains available from a package version below the runtime floor.
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

/// Mint a version-gated `MarketLifecycleCap` with market-creation and valuation authority.
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

/// Revoke a `MarketLifecycleCap` by ID without applying the version gate.
public fun revoke_lifecycle_cap(
    registry: &mut Registry,
    _admin_cap: &AdminCap,
    lifecycle_cap_id: ID,
) {
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

/// Set all deployment terms for one underlying's cadence. Passing zero for all
/// five values disables the cadence; otherwise all values must be nonzero and
/// valid.
public fun set_template_cadence_config(
    registry: &mut Registry,
    config: &ProtocolConfig,
    _admin_cap: &AdminCap,
    propbook_underlying_id: u32,
    cadence_id: u8,
    tick_size: u64,
    admission_tick_size: u64,
    max_expiry_allocation: u64,
    initial_expiry_cash: u64,
    window_size: u64,
) {
    config.assert_version();
    registry
        .market_manager
        .set_template_cadence_config(
            propbook_underlying_id,
            cadence_id,
            tick_size,
            admission_tick_size,
            max_expiry_allocation,
            initial_expiry_cash,
            window_size,
        );
    config_events::emit_cadence_config_updated(
        registry.id(),
        propbook_underlying_id,
        cadence_id,
        tick_size,
        admission_tick_size,
        max_expiry_allocation,
        initial_expiry_cash,
        window_size,
    );
}

/// Create the next deployable `ExpiryMarket` for one cadence on a Propbook underlying.
///
/// Requires an allowlisted lifecycle capability, a registered underlying with all
/// canonical feed objects bound, and an enabled cadence with a deployable slot.
/// Higher-rank cadence overlaps and existing markets are skipped. The market
/// snapshots cadence and expiry policy, starts with zero cash, and cannot mint
/// until pool rebalancing funds it. Live pricing reads current Propbook bindings.
public fun create_and_share_expiry_market(
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
    let deployable = registry
        .market_manager
        .next_deployable_market(propbook_registry, propbook_underlying_id, cadence_id, clock);
    let expiry = deployable.expiry();
    let tick_size = deployable.tick_size();
    let admission_tick_size = deployable.admission_tick_size();
    let reference_tick_source_timestamp_ms = expiry - market_manager::cadence_period_ms(cadence_id);
    let max_expiry_allocation = deployable.max_expiry_allocation();
    let initial_expiry_cash = deployable.initial_expiry_cash();
    let pool_vault_id = pool_vault.id();
    let expiry_market_id = expiry_market::create_and_share(
        config,
        propbook_underlying_id,
        expiry,
        tick_size,
        admission_tick_size,
        reference_tick_source_timestamp_ms,
        ctx,
    );
    pool_vault.register_expiry(
        expiry_market_id,
        expiry,
        max_expiry_allocation,
        initial_expiry_cash,
        clock,
    );
    registry
        .market_manager
        .record_expiry_creation(propbook_underlying_id, cadence_id, expiry, expiry_market_id);
    config_events::emit_market_created(
        expiry_market_id,
        pool_vault_id,
        propbook_underlying_id,
        expiry,
        tick_size,
        admission_tick_size,
        max_expiry_allocation,
        initial_expiry_cash,
        config.strike_exposure_template_config(),
        config.expiry_cash_template_config(),
    );

    expiry_market_id
}

/// Create a derived shared BuilderCode for the caller and index.
public fun create_and_share_builder_code(
    registry: &mut Registry,
    config: &ProtocolConfig,
    index: u64,
    ctx: &mut TxContext,
): ID {
    config.assert_version();
    builder_code::create_and_share(&mut registry.id, index, ctx)
}

// === Private Functions ===

/// Create and share protocol setup objects and transfer root authority to the publisher.
fun init(ctx: &mut TxContext) {
    let (registry, admin_cap) = new_registry_and_admin_cap(ctx);
    let _ = protocol_config::create_and_share(ctx);
    transfer::share_object(registry);
    transfer::public_transfer(admin_cap, ctx.sender());
}

/// Construct registry state and its root capability.
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
    let _ = protocol_config::create_and_share(ctx);
    transfer::share_object(registry);
    transfer::public_transfer(admin_cap, ctx.sender());

    registry_id
}
