// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Registry and creation entrypoints for the Predict protocol.
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
const EInvalidMarketTickSize: u64 = 9;
const ELifecycleCapNotValid: u64 = 10;
const ELifecycleCapNotFound: u64 = 11;
const EPythFeedNotBoundToUnderlying: u64 = 12;
const EBlockScholesFeedNotBoundToUnderlying: u64 = 13;
const EExpiryNotOnResolutionGrid: u64 = 14;

/// Market uniqueness key. Predict permits one market per Propbook underlying and
/// expiry; the market's chosen tick size is committed by the first creation.
public struct MarketKey has copy, drop, store {
    propbook_underlying_id: u32,
    expiry: u64,
}

/// Shared registry for underlying admission and expiry uniqueness.
public struct Registry has key {
    id: UID,
    /// Propbook underlying ID -> admin-approved minimum market tick size. A market
    /// on this underlying may choose this value or a 10x multiple above it.
    underlying_min_tick_sizes: Table<u32, u64>,
    /// Created markets keyed by `(propbook_underlying_id, expiry)`.
    market_ids: Table<MarketKey, ID>,
    /// IDs of `PauseCap` objects currently authorized to use pause-only entries.
    /// Admin mints into this set and revokes from it.
    allowed_pause_caps: VecSet<ID>,
    /// IDs of `MarketLifecycleCap` objects currently authorized for market
    /// lifecycle entries (market creation). Admin mints into this set and
    /// revokes from it.
    allowed_lifecycle_caps: VecSet<ID>,
}

// === Public Functions ===

/// Return the registry object ID.
public fun id(registry: &Registry): ID {
    registry.id.to_inner()
}

/// Return the configured minimum tick size for a Propbook underlying, if
/// registered.
public fun underlying_min_tick_size(registry: &Registry, propbook_underlying_id: u32): Option<u64> {
    if (registry.underlying_min_tick_sizes.contains(propbook_underlying_id)) {
        option::some(*registry.underlying_min_tick_sizes.borrow(propbook_underlying_id))
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

/// Record admin approval of one Propbook underlying and its minimum market tick
/// size. Source IDs and canonical oracle object IDs remain owned by Propbook;
/// this row only gates which underlyings Predict will build markets on and the
/// smallest tick size those markets may choose.
public fun register_underlying(
    registry: &mut Registry,
    config: &ProtocolConfig,
    _admin_cap: &AdminCap,
    propbook_underlying_id: u32,
    min_tick_size: u64,
) {
    config.assert_version();
    assert!(
        !registry.underlying_min_tick_sizes.contains(propbook_underlying_id),
        EUnderlyingAlreadyRegistered,
    );
    config_constants::assert_market_tick_size_bounds(min_tick_size);
    registry.underlying_min_tick_sizes.add(propbook_underlying_id, min_tick_size);
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
/// constants::resolution_period_ms!() == 0`). Terminal settlement is an exact
/// whole-millisecond lookup keyed at `expiry` (`pyth_feed::insert_at` accepts only
/// a print at exactly that millisecond), which the off-chain resolution relayer
/// sources from Pyth Lazer's exact-timestamp resolution endpoints and inserts only
/// on that grid; an off-grid expiry could never settle. While a past-expiry market
/// is awaiting its settling observation it has no solvency-safe NAV, so the pool
/// flush (`plp::value_expiry`) aborts until the observation lands — the keeper
/// retries and does not flush while an active market is in that pending-settlement
/// window (bounded to a few seconds at the grid cadence).
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
    config.assert_version();
    registry.assert_valid_lifecycle_cap(lifecycle_cap);
    config.assert_trading_allowed();
    config.assert_not_valuation_in_progress();
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
    let expiry_market_id = expiry_market::create_and_share(
        config,
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
public fun create_builder_code(
    registry: &mut Registry,
    config: &ProtocolConfig,
    index: u64,
    ctx: &mut TxContext,
): ID {
    config.assert_version();
    builder_code::create_and_share(&mut registry.id, index, ctx)
}

/// Create a derived PredictManager for the caller.
public fun create_manager(
    registry: &mut Registry,
    config: &ProtocolConfig,
    ctx: &mut TxContext,
): PredictManager {
    config.assert_version();
    predict_manager::new(&mut registry.id, ctx)
}

/// Create and share a derived PredictManager for the caller.
public fun create_and_share_manager(
    registry: &mut Registry,
    config: &ProtocolConfig,
    ctx: &mut TxContext,
) {
    config.assert_version();
    create_manager(registry, config, ctx).share();
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
    config: &ProtocolConfig,
    deepbook_registry: &DeepbookRegistry,
    ctx: &mut TxContext,
): (PredictManager, PredictDepositCap, PredictWithdrawCap, PredictTradeCap) {
    config.assert_version();
    predict_manager::new_self_owned(&mut registry.id, deepbook_registry, ctx)
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
            underlying_min_tick_sizes: table::new(ctx),
            market_ids: table::new(ctx),
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

fun assert_underlying_registered(registry: &Registry, propbook_underlying_id: u32): u64 {
    assert!(
        registry.underlying_min_tick_sizes.contains(propbook_underlying_id),
        EUnderlyingNotRegistered,
    );
    *registry.underlying_min_tick_sizes.borrow(propbook_underlying_id)
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
