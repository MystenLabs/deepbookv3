// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Registry and admin entrypoints for the Predict protocol.
///
/// This module creates the shared `Registry`, tracks market_oracle and Predict IDs,
/// and exposes the admin-only wiring/configuration functions used during setup
/// and protocol governance.
module deepbook_predict::registry;

use deepbook_predict::{
    constants,
    market_oracle::{Self, MarketOracleCap, MarketOracle},
    plp::PLP,
    predict::{Self, Predict},
    predict_manager::{Self, PredictManager},
    pyth_source::{Self, PythSource}
};
use std::{string::String, type_name};
use sui::{
    clock::Clock,
    coin::TreasuryCap,
    coin_registry::Currency,
    dynamic_field as df,
    event,
    table::{Self, Table}
};

use fun df::exists_ as UID.exists_;
use fun df::add as UID.add;

const EPredictAlreadyCreated: u64 = 0;
const EInvalidTickSize: u64 = 1;
const EInvalidStrikeGrid: u64 = 2;
const EFeedIdOverflow: u64 = 3;
const EFeedIdMismatch: u64 = 4;
const EPythSourceAlreadyCreated: u64 = 5;

/// Emitted when a Pyth source is created.
public struct PythSourceCreated has copy, drop, store {
    pyth_source_id: ID,
    pyth_lazer_feed_id: u64,
}

/// Emitted when a market oracle and its strike grid are registered.
public struct MarketOracleCreated has copy, drop, store {
    market_oracle_id: ID,
    market_oracle_cap_id: ID,
    pyth_source_id: ID,
    underlying_asset: String,
    pyth_lazer_feed_id: u64,
    expiry: u64,
    min_strike: u64,
    tick_size: u64,
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

/// DF marker on `Registry.id` enforcing the V1 single-Predict invariant.
/// Stored value is the chosen `Quote` `TypeName`.
public struct PredictCreated() has copy, drop, store;

// === Public Functions ===

/// Create the Predict shared object for `Quote`. V1 allows exactly one
/// Predict total via the `PredictCreated` marker; the per-`Quote` lock in
/// `predict::create` would take over if that guard is ever dropped.
entry fun create_predict<Quote>(
    registry: &mut Registry,
    _admin_cap: &AdminCap,
    currency: &Currency<Quote>,
    treasury_cap: TreasuryCap<PLP>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(!registry.id.exists_(PredictCreated()), EPredictAlreadyCreated);
    registry.id.add(PredictCreated(), type_name::with_defining_ids<Quote>());
    predict::create<Quote>(&mut registry.id, currency, treasury_cap, clock, ctx);
}

/// Create a shared Pyth source for one underlying/feed.
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

/// Create a new MarketOracleCap.
public fun create_market_oracle_cap(ctx: &mut TxContext): MarketOracleCap {
    market_oracle::create_cap(ctx)
}

/// Create a new market oracle. Returns the market oracle ID.
///
/// Authorized by the operator's `MarketOracleCap` alone — no `AdminCap` needed.
/// The cap is authorized on the new market_oracle automatically so the creator
/// can immediately push Block Scholes updates.
/// The Pyth Lazer feed id is inferred from `underlying_asset` via the admin-
/// registered `asset → feed_id` mapping; admin must call `set_asset_feed_id`
/// at least once per underlying before its first market_oracle can be created.
public fun create_market_oracle(
    registry: &mut Registry,
    predict: &mut Predict,
    pyth: &PythSource,
    cap: &MarketOracleCap,
    underlying_asset: String,
    expiry: u64,
    min_strike: u64,
    tick_size: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    assert_valid_strike_grid(min_strike, tick_size);
    let pyth_lazer_feed_id = predict.resolve_feed_id(underlying_asset);
    // Narrow to `u32` for the Lazer-binding leaf. Config stores `u64` for
    // cross-field consistency, but the Pyth Lazer feed-id width is `u32`.
    assert!(pyth_lazer_feed_id <= 0xFFFF_FFFF, EFeedIdOverflow);
    assert!(pyth.feed_id() == pyth_lazer_feed_id as u32, EFeedIdMismatch);
    let bounds = predict.build_market_oracle_bounds(underlying_asset);
    let market_oracle_id = market_oracle::create(
        underlying_asset,
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
    predict.add_market_grid(market_oracle_id, expiry, min_strike, tick_size, clock, ctx);
    event::emit(MarketOracleCreated {
        market_oracle_id,
        market_oracle_cap_id: cap_id,
        pyth_source_id: pyth.id(),
        underlying_asset,
        pyth_lazer_feed_id,
        expiry,
        min_strike,
        tick_size,
    });

    market_oracle_id
}

/// Enable a quote asset for new supply and mint inflows.
public fun enable_quote_asset<Quote>(
    predict: &mut Predict,
    _admin_cap: &AdminCap,
    currency: &Currency<Quote>,
) {
    predict.enable_quote_asset<Quote>(currency);
}

/// Disable a quote asset for new supply and mint inflows.
public fun disable_quote_asset<Quote>(predict: &mut Predict, _admin_cap: &AdminCap) {
    predict.disable_quote_asset<Quote>();
}

/// Set trading pause state.
public fun set_trading_paused(predict: &mut Predict, _admin_cap: &AdminCap, paused: bool) {
    predict.set_trading_paused(paused);
}

/// Set base fee.
public fun set_base_fee(predict: &mut Predict, _admin_cap: &AdminCap, fee: u64) {
    predict.set_base_fee(fee);
}

/// Set min fee.
public fun set_min_fee(predict: &mut Predict, _admin_cap: &AdminCap, fee: u64) {
    predict.set_min_fee(fee);
}

/// Set utilization multiplier.
public fun set_utilization_multiplier(
    predict: &mut Predict,
    _admin_cap: &AdminCap,
    multiplier: u64,
) {
    predict.set_utilization_multiplier(multiplier);
}

/// Set fee distribution shares.
public fun set_fee_shares(
    predict: &mut Predict,
    _admin_cap: &AdminCap,
    lp_fee_share: u64,
    protocol_fee_share: u64,
    insurance_fee_share: u64,
) {
    predict.set_fee_shares(lp_fee_share, protocol_fee_share, insurance_fee_share);
}

/// Set the global minimum allowed all-in mint price.
public fun set_min_ask_price(predict: &mut Predict, _admin_cap: &AdminCap, value: u64) {
    predict.set_min_ask_price(value);
}

/// Set the global maximum allowed all-in mint price.
public fun set_max_ask_price(predict: &mut Predict, _admin_cap: &AdminCap, value: u64) {
    predict.set_max_ask_price(value);
}

/// Set a per-market_oracle ask-bound override. Authorized by the market_oracle's own cap;
/// no `AdminCap` required. The override may only tighten the global bounds.
public fun set_market_ask_bounds(
    predict: &mut Predict,
    market_oracle: &MarketOracle,
    cap: &MarketOracleCap,
    min: u64,
    max: u64,
) {
    predict.set_market_ask_bounds(market_oracle, cap, min, max);
}

/// Clear a per-market_oracle ask-bound override so the market_oracle inherits the global
/// default again. Authorized by the market_oracle's own cap.
public fun clear_market_ask_bounds(
    predict: &mut Predict,
    market_oracle: &MarketOracle,
    cap: &MarketOracleCap,
) {
    predict.clear_market_ask_bounds(market_oracle, cap);
}

/// Set max total exposure percentage.
public fun set_max_total_exposure_pct(predict: &mut Predict, _admin_cap: &AdminCap, pct: u64) {
    predict.set_max_total_exposure_pct(pct);
}

/// Set the MTM freshness threshold (ms) used for LP supply/withdraw gating.
public fun set_mtm_freshness_ms(predict: &mut Predict, _admin_cap: &AdminCap, value: u64) {
    predict.set_mtm_freshness_ms(value);
}

/// Update withdrawal rate limiter capacity and refill rate.
public fun update_withdrawal_limiter(
    predict: &mut Predict,
    _admin_cap: &AdminCap,
    capacity: u64,
    refill_rate_per_ms: u64,
    clock: &Clock,
) {
    predict.update_withdrawal_limiter(capacity, refill_rate_per_ms, clock);
}

/// Enable the withdrawal rate limiter.
public fun enable_withdrawal_limiter(predict: &mut Predict, _admin_cap: &AdminCap, clock: &Clock) {
    predict.enable_withdrawal_limiter(clock);
}

/// Disable the withdrawal rate limiter.
public fun disable_withdrawal_limiter(predict: &mut Predict, _admin_cap: &AdminCap) {
    predict.disable_withdrawal_limiter();
}

/// Set the Pyth spot freshness threshold (ms).
public fun set_pyth_spot_freshness_ms(predict: &mut Predict, _admin_cap: &AdminCap, value: u64) {
    predict.set_pyth_spot_freshness_ms(value);
}

/// Set the Block Scholes spot/forward freshness threshold (ms).
public fun set_block_scholes_prices_freshness_ms(
    predict: &mut Predict,
    _admin_cap: &AdminCap,
    value: u64,
) {
    predict.set_block_scholes_prices_freshness_ms(value);
}

/// Set the Block Scholes SVI freshness threshold (ms).
public fun set_block_scholes_svi_freshness_ms(
    predict: &mut Predict,
    _admin_cap: &AdminCap,
    value: u64,
) {
    predict.set_block_scholes_svi_freshness_ms(value);
}

/// Update the circuit-breaker bounds seed used by
/// `market_config::build_market_oracle_bounds` at the next matching `create_market_oracle`
/// for `asset` (e.g. "BTC"). `max_spot_deviation` and `max_basis_deviation`
/// are per-push percent caps (1e9-scaled); `min_basis` / `max_basis` are
/// absolute bounds on `forward / spot`. Does NOT retroactively update
/// existing oracles — operators retune per-market_oracle via
/// `market_oracle::set_basis_bounds`.
public fun set_asset_basis_bounds(
    predict: &mut Predict,
    _admin_cap: &AdminCap,
    asset: String,
    max_spot_deviation: u64,
    max_basis_deviation: u64,
    min_basis: u64,
    max_basis: u64,
) {
    predict.set_asset_basis_bounds(
        asset,
        max_spot_deviation,
        max_basis_deviation,
        min_basis,
        max_basis,
    );
}

/// Bind `asset → pyth_lazer_feed_id` so subsequent `create_market_oracle` calls for
/// that underlying resolve the feed id from config instead of taking it as a
/// PTB arg. Admin must register an entry before the first market_oracle for a new
/// asset can be created; re-registering updates the mapping but does NOT
/// retroactively change existing oracles — they keep the feed id snapshotted
/// at their own creation time.
public fun set_asset_feed_id(
    predict: &mut Predict,
    _admin_cap: &AdminCap,
    asset: String,
    pyth_lazer_feed_id: u64,
) {
    predict.set_asset_feed_id(asset, pyth_lazer_feed_id);
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
