// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Registry and admin entrypoints for the Predict protocol.
///
/// This module creates shared setup objects, tracks market oracle IDs, and
/// exposes admin-only wiring functions used during setup and governance.
module deepbook_predict::registry;

use deepbook_predict::{
    constants,
    expiry_market,
    market_oracle::{Self, MarketOracle, MarketOracleCap},
    plp::PLP,
    pool_vault::{Self, PoolVault},
    predict_manager::{Self, PredictManager},
    protocol_config,
    pyth_source::{Self, PythSource},
    tuning_constants
};
use sui::{clock::Clock, coin::TreasuryCap, dynamic_field as df, event, table::{Self, Table}};

use fun df::exists_ as UID.exists_;
use fun df::add as UID.add;

const EInvalidTickSize: u64 = 1;
const EInvalidStrikeGrid: u64 = 2;
const EFeedIdOverflow: u64 = 3;
const EFeedIdMismatch: u64 = 4;
const EPythSourceAlreadyCreated: u64 = 5;
const EInvalidExpiry: u64 = 6;
const EProtocolConfigAlreadyCreated: u64 = 7;
const EPoolVaultAlreadyCreated: u64 = 8;

/// Emitted when a Pyth source is created.
public struct PythSourceCreated has copy, drop, store {
    pyth_source_id: ID,
    pyth_lazer_feed_id: u64,
}

/// Emitted when an expiry market and its paired oracle are registered.
public struct ExpiryMarketCreated has copy, drop, store {
    expiry_market_id: ID,
    market_oracle_id: ID,
    market_oracle_cap_id: ID,
    pyth_source_id: ID,
    pyth_lazer_feed_id: u64,
    expiry: u64,
    min_strike: u64,
    max_strike: u64,
    tick_size: u64,
}

public struct MarketOracleCapRegistered has copy, drop, store {
    market_oracle_id: ID,
    cap_id: ID,
}

public struct MarketOracleCapUnregistered has copy, drop, store {
    market_oracle_id: ID,
    cap_id: ID,
}

/// Capability for admin operations.
/// Created during package init, transferred to deployer (multisig).
public struct AdminCap has key, store {
    id: UID,
}

/// Shared object tracking global state.
public struct Registry has key {
    id: UID,
    /// Pyth Lazer feed ID -> shared PythSource ID.
    pyth_source_ids: Table<u64, ID>,
    /// MarketOracleCap ID -> vector of market oracle IDs created by that cap.
    market_oracle_ids: Table<ID, vector<ID>>,
}

/// DF marker on `Registry.id` enforcing one protocol config object.
public struct ProtocolConfigMarker() has copy, drop, store;

/// DF marker on `Registry.id` enforcing one pool vault object.
public struct PoolVaultMarker() has copy, drop, store;

// === Public Functions ===

/// Create the protocol config shared object.
public fun create_protocol_config(
    registry: &mut Registry,
    _admin_cap: &AdminCap,
    ctx: &mut TxContext,
): ID {
    assert!(!registry.id.exists_(ProtocolConfigMarker()), EProtocolConfigAlreadyCreated);
    let protocol_config_id = protocol_config::create_and_share(ctx);
    registry.id.add(ProtocolConfigMarker(), protocol_config_id);
    protocol_config_id
}

/// Create the pool vault shared object.
public fun create_pool_vault(
    registry: &mut Registry,
    _admin_cap: &AdminCap,
    treasury_cap: TreasuryCap<PLP>,
    ctx: &mut TxContext,
): ID {
    assert!(!registry.id.exists_(PoolVaultMarker()), EPoolVaultAlreadyCreated);
    let pool_vault_id = pool_vault::create_and_share(treasury_cap, ctx);
    registry.id.add(PoolVaultMarker(), pool_vault_id);
    pool_vault_id
}

/// Create a shared Pyth source for one underlying/feed.
///
/// This is permissionless because the object only stores verified Pyth Lazer
/// payloads. Market creation still requires the feed to match admin config.
public fun create_pyth_source(
    registry: &mut Registry,
    pyth_lazer_feed_id: u64,
    ctx: &mut TxContext,
): ID {
    assert!(pyth_lazer_feed_id <= 0xFFFF_FFFF, EFeedIdOverflow);
    assert!(!registry.pyth_source_ids.contains(pyth_lazer_feed_id), EPythSourceAlreadyCreated);
    let pyth_source_id = pyth_source::create(pyth_lazer_feed_id as u32, ctx);
    registry.pyth_source_ids.add(pyth_lazer_feed_id, pyth_source_id);
    event::emit(PythSourceCreated { pyth_source_id, pyth_lazer_feed_id });
    pyth_source_id
}

/// Admin-only creation of a new MarketOracleCap.
public fun create_market_oracle_cap(_admin_cap: &AdminCap, ctx: &mut TxContext): MarketOracleCap {
    market_oracle::create_cap(ctx)
}

/// Register an additional MarketOracleCap as authorized to update a market oracle.
public fun register_market_oracle_cap(
    market: &mut MarketOracle,
    _admin_cap: &AdminCap,
    cap: &MarketOracleCap,
) {
    market_oracle::register_cap(market, cap);
    event::emit(MarketOracleCapRegistered {
        market_oracle_id: market.id(),
        cap_id: object::id(cap),
    });
}

/// Revoke a MarketOracleCap's authorization on a market oracle.
public fun unregister_market_oracle_cap(
    market: &mut MarketOracle,
    _admin_cap: &AdminCap,
    cap_id: ID,
) {
    market_oracle::unregister_cap(market, cap_id);
    event::emit(MarketOracleCapUnregistered { market_oracle_id: market.id(), cap_id });
}

/// Cap holder voluntarily removes its own cap from a market oracle.
public fun self_unregister_market_oracle_cap(market: &mut MarketOracle, cap: &MarketOracleCap) {
    let cap_id = object::id(cap);
    market_oracle::self_unregister_cap(market, cap);
    event::emit(MarketOracleCapUnregistered { market_oracle_id: market.id(), cap_id });
}

/// Destroy a MarketOracleCap the holder no longer needs.
public fun destroy_market_oracle_cap(cap: MarketOracleCap) {
    market_oracle::destroy_cap(cap);
}

/// Create a new expiry market for the parallel pool path.
public fun create_expiry_market(
    registry: &mut Registry,
    pool_vault: &mut PoolVault,
    pyth: &PythSource,
    cap: &MarketOracleCap,
    expiry: u64,
    min_strike: u64,
    tick_size: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (ID, ID) {
    assert_valid_strike_grid(min_strike, tick_size);
    assert!(expiry > clock.timestamp_ms(), EInvalidExpiry);
    let pyth_lazer_feed_id = pyth.feed_id() as u64;
    let market_oracle_id = create_market_oracle_for_source(
        registry,
        pyth,
        cap,
        pyth_lazer_feed_id,
        expiry,
        ctx,
    );
    let max_strike = default_max_strike(min_strike, tick_size);
    let expiry_market_id = expiry_market::create_and_share(
        market_oracle_id,
        pyth_lazer_feed_id,
        expiry,
        min_strike,
        max_strike,
        tick_size,
        ctx,
    );
    pool_vault.register_expiry_market(expiry_market_id);
    event::emit(ExpiryMarketCreated {
        expiry_market_id,
        market_oracle_id,
        market_oracle_cap_id: object::id(cap),
        pyth_source_id: pyth.id(),
        pyth_lazer_feed_id,
        expiry,
        min_strike,
        max_strike,
        tick_size,
    });

    (expiry_market_id, market_oracle_id)
}

/// Create a new PredictManager for the caller, allowing composability.
public fun create_manager(registry: &mut Registry, ctx: &mut TxContext): PredictManager {
    predict_manager::new(&mut registry.id, ctx)
}

/// Create and share a new PredictManager for the caller.
entry fun create_and_share_manager(registry: &mut Registry, ctx: &mut TxContext) {
    create_manager(registry, ctx).share();
}

/// Get market_oracle IDs created by a given MarketOracleCap.
public fun market_oracle_ids(registry: &Registry, cap_id: ID): vector<ID> {
    if (registry.market_oracle_ids.contains(cap_id)) {
        registry.market_oracle_ids[cap_id]
    } else {
        vector[]
    }
}

/// Return the shared PythSource ID for a feed, if it has been created.
public fun pyth_source_id(registry: &Registry, pyth_lazer_feed_id: u64): Option<ID> {
    if (registry.pyth_source_ids.contains(pyth_lazer_feed_id)) {
        option::some(registry.pyth_source_ids[pyth_lazer_feed_id])
    } else {
        option::none()
    }
}

// === Private Functions ===

/// Package initializer - creates Registry and AdminCap.
fun init(ctx: &mut TxContext) {
    let (registry, admin_cap) = new_registry_and_admin_cap(ctx);
    transfer::share_object(registry);
    transfer::transfer(admin_cap, ctx.sender());
}

/// Validate the initial market_oracle strike grid supplied by the operator.
fun assert_valid_strike_grid(min_strike: u64, tick_size: u64) {
    assert!(tick_size > 0, EInvalidTickSize);
    assert!(tick_size % constants::oracle_tick_size_unit!() == 0, EInvalidTickSize);
    assert!(min_strike > 0, EInvalidStrikeGrid);
    assert!(min_strike % tick_size == 0, EInvalidStrikeGrid);
}

/// Create a market oracle after validating its registry-bound Pyth source.
fun create_market_oracle_for_source(
    registry: &mut Registry,
    pyth: &PythSource,
    cap: &MarketOracleCap,
    pyth_lazer_feed_id: u64,
    expiry: u64,
    ctx: &mut TxContext,
): ID {
    // Narrow to `u32` for the Lazer-binding leaf.
    assert!(pyth_lazer_feed_id <= 0xFFFF_FFFF, EFeedIdOverflow);
    assert!(pyth.feed_id() == pyth_lazer_feed_id as u32, EFeedIdMismatch);
    assert!(registry.pyth_source_ids.contains(pyth_lazer_feed_id), EFeedIdMismatch);
    assert!(registry.pyth_source_ids[pyth_lazer_feed_id] == pyth.id(), EFeedIdMismatch);

    let bounds = market_oracle::new_bounds(
        tuning_constants::default_settlement_freshness_ms!(),
        tuning_constants::default_max_spot_deviation!(),
        tuning_constants::default_max_basis_deviation!(),
        tuning_constants::default_min_basis!(),
        tuning_constants::default_max_basis!(),
    );
    let market_oracle_id = market_oracle::create(
        pyth.id(),
        expiry,
        bounds,
        cap,
        ctx,
    );
    let cap_id = object::id(cap);
    if (!registry.market_oracle_ids.contains(cap_id)) {
        registry.market_oracle_ids.add(cap_id, vector[]);
    };
    registry.market_oracle_ids[cap_id].push_back(market_oracle_id);

    market_oracle_id
}

/// Return the fixed strike-grid upper bound.
fun default_max_strike(min_strike: u64, tick_size: u64): u64 {
    min_strike + tick_size * constants::oracle_strike_grid_ticks!()
}

/// Construct registry and admin cap during package init or tests.
fun new_registry_and_admin_cap(ctx: &mut TxContext): (Registry, AdminCap) {
    (
        Registry {
            id: object::new(ctx),
            pyth_source_ids: table::new(ctx),
            market_oracle_ids: table::new(ctx),
        },
        AdminCap {
            id: object::new(ctx),
        },
    )
}

// === Test-Only Functions ===

#[test_only]
/// Initialize registry and admin cap for tests, returning the registry ID.
public fun init_for_testing(ctx: &mut TxContext): ID {
    let (registry, admin_cap) = new_registry_and_admin_cap(ctx);
    let registry_id = object::id(&registry);
    transfer::share_object(registry);
    transfer::transfer(admin_cap, ctx.sender());

    registry_id
}

#[test_only]
/// Create an admin cap for tests.
public fun create_admin_cap_for_testing(ctx: &mut TxContext): AdminCap {
    AdminCap { id: object::new(ctx) }
}
