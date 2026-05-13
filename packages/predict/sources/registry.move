// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Registry and admin entrypoints for the Predict protocol.
///
/// This module creates shared setup objects and exposes admin-only wiring
/// functions used during setup and governance.
module deepbook_predict::registry;

use deepbook_predict::{
    constants,
    expiry_market,
    market_oracle::{Self, MarketOracle, MarketOracleCap},
    plp::PoolVault,
    predict_manager::{Self, PredictManager},
    protocol_config::{Self, ProtocolConfig},
    pyth_source::{Self, PythSource}
};
use sui::{clock::Clock, table::{Self, Table}};

const EInvalidTickSize: u64 = 0;
const EInvalidStrikeGrid: u64 = 1;
const EFeedIdMismatch: u64 = 2;
const EPythSourceAlreadyCreated: u64 = 3;
const EInvalidExpiry: u64 = 4;

/// Capability for admin operations.
/// Created during package init, transferred to deployer (multisig).
public struct AdminCap has key, store {
    id: UID,
}

/// Shared object tracking global state.
public struct Registry has key {
    id: UID,
    /// Pyth Lazer feed ID -> shared PythSource ID.
    pyth_source_ids: Table<u32, ID>,
}

// === Public Functions ===

/// Set the base fee multiplier.
public fun set_base_fee(config: &mut ProtocolConfig, _admin_cap: &AdminCap, fee: u64) {
    config.set_base_fee(fee);
}

/// Set the minimum fee floor.
public fun set_min_fee(config: &mut ProtocolConfig, _admin_cap: &AdminCap, fee: u64) {
    config.set_min_fee(fee);
}

/// Set the utilization multiplier.
public fun set_utilization_multiplier(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    multiplier: u64,
) {
    config.set_utilization_multiplier(multiplier);
}

/// Set the global minimum allowed mint price.
public fun set_min_ask_price(config: &mut ProtocolConfig, _admin_cap: &AdminCap, value: u64) {
    config.set_min_ask_price(value);
}

/// Set the global maximum allowed mint price.
public fun set_max_ask_price(config: &mut ProtocolConfig, _admin_cap: &AdminCap, value: u64) {
    config.set_max_ask_price(value);
}

/// Set the live Pyth spot freshness threshold.
public fun set_pyth_spot_freshness_ms(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.set_pyth_spot_freshness_ms(value);
}

/// Set the live Block Scholes spot/forward freshness threshold.
public fun set_block_scholes_prices_freshness_ms(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.set_block_scholes_prices_freshness_ms(value);
}

/// Set the live Block Scholes SVI freshness threshold.
public fun set_block_scholes_svi_freshness_ms(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.set_block_scholes_svi_freshness_ms(value);
}

/// Set the fee distribution shares.
public fun set_fee_shares(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    lp_fee_share: u64,
    protocol_fee_share: u64,
    insurance_fee_share: u64,
) {
    config.set_fee_shares(lp_fee_share, protocol_fee_share, insurance_fee_share);
}

/// Set the maximum total exposure percentage.
public fun set_max_total_exposure_pct(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    pct: u64,
) {
    config.set_max_total_exposure_pct(pct);
}

/// Set the current DUSDC allocation for new expiry markets.
public fun set_expiry_allocation(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    allocation: u64,
) {
    config.set_expiry_allocation(allocation);
}

/// Set the settlement freshness threshold template used by future market oracles.
public fun set_market_oracle_template_settlement_freshness_ms(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.set_market_oracle_template_settlement_freshness_ms(value);
}

/// Set basis guard bounds template used by future market oracles.
public fun set_market_oracle_template_basis_bounds(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    max_spot_deviation: u64,
    max_basis_deviation: u64,
    min_basis: u64,
    max_basis: u64,
) {
    config.set_market_oracle_template_basis_bounds(
        max_spot_deviation,
        max_basis_deviation,
        min_basis,
        max_basis,
    );
}

/// Set whether trading is paused.
public fun set_trading_paused(config: &mut ProtocolConfig, _admin_cap: &AdminCap, paused: bool) {
    config.set_trading_paused(paused);
}

/// Create a shared Pyth source for one underlying/feed.
///
/// This is permissionless because the object only stores verified Pyth Lazer
/// payloads. Market creation still requires the feed to match admin config.
public fun create_pyth_source(
    registry: &mut Registry,
    pyth_lazer_feed_id: u32,
    ctx: &mut TxContext,
): ID {
    assert!(!registry.pyth_source_ids.contains(pyth_lazer_feed_id), EPythSourceAlreadyCreated);
    let pyth_source_id = pyth_source::create_and_share(pyth_lazer_feed_id, ctx);
    registry.pyth_source_ids.add(pyth_lazer_feed_id, pyth_source_id);
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
    market.register_cap(cap);
}

/// Revoke a MarketOracleCap's authorization on a market oracle.
public fun unregister_market_oracle_cap(
    market: &mut MarketOracle,
    _admin_cap: &AdminCap,
    cap_id: ID,
) {
    market.unregister_cap(cap_id);
}

/// Cap holder voluntarily removes its own cap from a market oracle.
public fun self_unregister_market_oracle_cap(market: &mut MarketOracle, cap: &MarketOracleCap) {
    market.self_unregister_cap(cap);
}

/// Destroy a MarketOracleCap the holder no longer needs.
public fun destroy_market_oracle_cap(cap: MarketOracleCap) {
    cap.destroy_cap();
}

/// Create a new expiry market for the parallel pool path.
public fun create_expiry_market(
    registry: &Registry,
    pool_vault: &mut PoolVault,
    config: &ProtocolConfig,
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
    let pyth_lazer_feed_id = pyth.feed_id();
    assert!(registry.pyth_source_ids.contains(pyth_lazer_feed_id), EFeedIdMismatch);
    assert!(registry.pyth_source_ids[pyth_lazer_feed_id] == pyth.id(), EFeedIdMismatch);
    let market_oracle_id = market_oracle::create_and_share(
        pyth,
        config.market_oracle_config(),
        cap,
        expiry,
        ctx,
    );
    let max_strike = max_strike_for_grid(min_strike, tick_size);
    let allocation = pool_vault.allocate_to_new_expiry(config.risk_config());
    let expiry_market_id = expiry_market::create_and_share(
        market_oracle_id,
        pyth,
        config,
        allocation,
        expiry,
        min_strike,
        max_strike,
        tick_size,
        ctx,
    );
    pool_vault.register_expiry_market(expiry_market_id);

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

/// Return the shared PythSource ID for a feed, if it has been created.
public fun pyth_source_id(registry: &Registry, pyth_lazer_feed_id: u32): Option<ID> {
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
    protocol_config::create_and_share(ctx);
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

/// Return the fixed strike-grid upper bound.
fun max_strike_for_grid(min_strike: u64, tick_size: u64): u64 {
    min_strike + tick_size * constants::oracle_strike_grid_ticks!()
}

/// Construct registry and admin cap during package init or tests.
fun new_registry_and_admin_cap(ctx: &mut TxContext): (Registry, AdminCap) {
    (
        Registry {
            id: object::new(ctx),
            pyth_source_ids: table::new(ctx),
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
    protocol_config::create_and_share(ctx);
    transfer::share_object(registry);
    transfer::transfer(admin_cap, ctx.sender());

    registry_id
}

#[test_only]
/// Create an admin cap for tests.
public fun create_admin_cap_for_testing(ctx: &mut TxContext): AdminCap {
    AdminCap { id: object::new(ctx) }
}
