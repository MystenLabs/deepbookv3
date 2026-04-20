// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Registry and admin entrypoints for the Predict protocol.
///
/// This module creates the shared `Registry`, tracks oracle and Predict IDs,
/// and exposes the admin-only wiring/configuration functions used during setup
/// and protocol governance.
module deepbook_predict::registry;

use deepbook_predict::{
    constants,
    oracle::{Self, OracleSVICap, OracleSVI},
    plp::PLP,
    predict::{Self, Predict}
};
use std::string::String;
use sui::{clock::Clock, coin::TreasuryCap, coin_registry::Currency, event, table::{Self, Table}};

// === Errors ===
const EPredictAlreadyCreated: u64 = 0;
const EInvalidTickSize: u64 = 1;
const EInvalidStrikeGrid: u64 = 2;
const EFeedIdOverflow: u64 = 3;

// === Events ===

public struct PredictCreated has copy, drop, store {
    predict_id: ID,
}

public struct OracleCreated has copy, drop, store {
    oracle_id: ID,
    oracle_cap_id: ID,
    underlying_asset: String,
    pyth_lazer_feed_id: u64,
    expiry: u64,
    min_strike: u64,
    tick_size: u64,
}

// === Structs ===

/// Capability for admin operations.
/// Created during package init, transferred to deployer (multisig).
public struct AdminCap has key, store {
    id: UID,
}

/// Shared object tracking global state.
public struct Registry has key {
    id: UID,
    /// ID of the Predict object (None if not yet created)
    predict_id: Option<ID>,
    /// OracleSVICap ID -> vector of oracle IDs created by that cap
    oracle_ids: Table<ID, vector<ID>>,
}

// === Public Functions ===

/// Get the Predict ID (None if not yet created).
public fun predict_id(registry: &Registry): Option<ID> {
    registry.predict_id
}

/// Get oracle IDs created by a given OracleSVICap.
public fun oracle_ids(registry: &Registry, cap_id: ID): vector<ID> {
    if (registry.oracle_ids.contains(cap_id)) {
        registry.oracle_ids[cap_id]
    } else {
        vector[]
    }
}

/// Create the Predict shared object. Can only be called once.
/// Quote is the collateral asset (e.g., USDC).
public fun create_predict<Quote>(
    registry: &mut Registry,
    _admin_cap: &AdminCap,
    currency: &Currency<Quote>,
    treasury_cap: TreasuryCap<PLP>,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    assert!(registry.predict_id.is_none(), EPredictAlreadyCreated);

    let predict_id = predict::create<Quote>(currency, treasury_cap, clock, ctx);
    registry.predict_id = option::some(predict_id);

    event::emit(PredictCreated { predict_id });

    predict_id
}

/// Register an additional OracleSVICap as authorized to update an oracle.
public fun register_oracle_cap(oracle: &mut OracleSVI, _admin_cap: &AdminCap, cap: &OracleSVICap) {
    oracle::register_cap(oracle, cap);
}

/// Create a new OracleSVICap. Transferred to Block Scholes operator.
public fun create_oracle_cap(_admin_cap: &AdminCap, ctx: &mut TxContext): OracleSVICap {
    oracle::create_oracle_cap(ctx)
}

/// Create a new Oracle. Returns the oracle ID.
///
/// Authorized by the operator's `OracleSVICap` alone — no `AdminCap` needed.
/// The cap is minted by admin via `create_oracle_cap`, so admin still gates
/// who can create oracles. The cap is authorized on the new oracle
/// automatically so the creator can immediately activate and push updates.
/// The Pyth Lazer feed id is inferred from `underlying_asset` via the admin-
/// registered `asset → feed_id` mapping; admin must call `set_asset_feed_id`
/// at least once per underlying before its first oracle can be created.
public fun create_oracle(
    registry: &mut Registry,
    predict: &mut Predict,
    cap: &OracleSVICap,
    underlying_asset: String,
    expiry: u64,
    min_strike: u64,
    tick_size: u64,
    ctx: &mut TxContext,
): ID {
    assert_valid_strike_grid(min_strike, tick_size);
    let pyth_lazer_feed_id = predict.resolve_feed_id(underlying_asset);
    // Narrow to `u32` for the Lazer-binding leaf. Config stores `u64` for
    // cross-field consistency, but the Pyth Lazer feed-id width is `u32`.
    assert!(pyth_lazer_feed_id <= 0xFFFF_FFFF, EFeedIdOverflow);
    let bounds = predict.build_oracle_bounds(underlying_asset);
    let oracle_id = oracle::create_oracle(
        underlying_asset,
        pyth_lazer_feed_id as u32,
        expiry,
        bounds,
        cap,
        ctx,
    );
    let cap_id = object::id(cap);

    if (!registry.oracle_ids.contains(cap_id)) {
        registry.oracle_ids.add(cap_id, vector[]);
    };
    registry.oracle_ids[cap_id].push_back(oracle_id);
    predict.add_oracle_grid(oracle_id, min_strike, tick_size, ctx);
    event::emit(OracleCreated {
        oracle_id,
        oracle_cap_id: cap_id,
        underlying_asset,
        pyth_lazer_feed_id,
        expiry,
        min_strike,
        tick_size,
    });

    oracle_id
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

/// Set base spread.
public fun set_base_spread(predict: &mut Predict, _admin_cap: &AdminCap, spread: u64) {
    predict.set_base_spread(spread);
}

/// Set min spread.
public fun set_min_spread(predict: &mut Predict, _admin_cap: &AdminCap, spread: u64) {
    predict.set_min_spread(spread);
}

/// Set utilization multiplier.
public fun set_utilization_multiplier(
    predict: &mut Predict,
    _admin_cap: &AdminCap,
    multiplier: u64,
) {
    predict.set_utilization_multiplier(multiplier);
}

/// Set the global minimum allowed post-spread ask price at mint time.
public fun set_min_ask_price(predict: &mut Predict, _admin_cap: &AdminCap, value: u64) {
    predict.set_min_ask_price(value);
}

/// Set the global maximum allowed post-spread ask price at mint time.
public fun set_max_ask_price(predict: &mut Predict, _admin_cap: &AdminCap, value: u64) {
    predict.set_max_ask_price(value);
}

/// Set a per-oracle ask-bound override. Authorized by the oracle's own cap;
/// no `AdminCap` required. The override may only tighten the global bounds.
public fun set_oracle_ask_bounds(
    predict: &mut Predict,
    oracle: &OracleSVI,
    cap: &OracleSVICap,
    min: u64,
    max: u64,
) {
    predict.set_oracle_ask_bounds(oracle, cap, min, max);
}

/// Clear a per-oracle ask-bound override so the oracle inherits the global
/// default again. Authorized by the oracle's own cap.
public fun clear_oracle_ask_bounds(predict: &mut Predict, oracle: &OracleSVI, cap: &OracleSVICap) {
    predict.clear_oracle_ask_bounds(oracle, cap);
}

/// Set max total exposure percentage.
public fun set_max_total_exposure_pct(predict: &mut Predict, _admin_cap: &AdminCap, pct: u64) {
    predict.set_max_total_exposure_pct(pct);
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

/// Set the oracle staleness threshold (ms).
public fun set_staleness_threshold_ms(predict: &mut Predict, _admin_cap: &AdminCap, value: u64) {
    predict.set_staleness_threshold_ms(value);
}

/// Set the basis staleness threshold (ms).
public fun set_basis_staleness_threshold_ms(
    predict: &mut Predict,
    _admin_cap: &AdminCap,
    value: u64,
) {
    predict.set_basis_staleness_threshold_ms(value);
}

/// Set the Lazer-authoritative window (ms). While the last Pyth Lazer spot
/// push is within this window, operator `update_prices` calls refresh basis
/// and forward but leave `oracle.prices.spot` alone.
public fun set_lazer_authoritative_threshold_ms(
    predict: &mut Predict,
    _admin_cap: &AdminCap,
    value: u64,
) {
    predict.set_lazer_authoritative_threshold_ms(value);
}

/// Set the Lazer-settlement-authoritative window (ms). While Lazer has
/// pushed within this window, operator `update_prices` cannot race-freeze
/// the terminal settlement price — it aborts and defers to Lazer. Beyond
/// the window (or when Lazer has never pushed), operator settlement is the
/// fallback.
public fun set_lazer_settlement_authoritative_threshold_ms(
    predict: &mut Predict,
    _admin_cap: &AdminCap,
    value: u64,
) {
    predict.set_lazer_settlement_authoritative_threshold_ms(value);
}

/// Update the circuit-breaker bounds seed used by
/// `oracle_config::build_oracle_bounds` at the next matching `create_oracle`
/// for `asset` (e.g. "BTC"). `max_spot_deviation` and `max_basis_deviation`
/// are per-push percent caps (1e9-scaled); `min_basis` / `max_basis` are
/// absolute bounds on `forward / spot`. Does NOT retroactively update
/// existing oracles — operators retune per-oracle via
/// `oracle::set_basis_bounds`.
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

/// Bind `asset → pyth_lazer_feed_id` so subsequent `create_oracle` calls for
/// that underlying resolve the feed id from config instead of taking it as a
/// PTB arg. Admin must register an entry before the first oracle for a new
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

// === Private Functions ===

/// Package initializer - creates Registry and AdminCap.
fun init(ctx: &mut TxContext) {
    let (registry, admin_cap) = new_registry_and_admin_cap(ctx);
    transfer::share_object(registry);
    transfer::transfer(admin_cap, ctx.sender());
}

fun assert_valid_strike_grid(min_strike: u64, tick_size: u64) {
    assert!(tick_size > 0, EInvalidTickSize);
    assert!(tick_size % constants::oracle_tick_size_unit!() == 0, EInvalidTickSize);
    assert!(min_strike > 0, EInvalidStrikeGrid);
    assert!(min_strike % tick_size == 0, EInvalidStrikeGrid);
}

// === Test Functions ===
#[test_only]
public fun init_for_testing(ctx: &mut TxContext): ID {
    let (registry, admin_cap) = new_registry_and_admin_cap(ctx);
    let registry_id = object::id(&registry);
    transfer::share_object(registry);
    transfer::transfer(admin_cap, ctx.sender());

    registry_id
}

#[test_only]
public fun create_admin_cap_for_testing(ctx: &mut TxContext): AdminCap {
    AdminCap { id: object::new(ctx) }
}

fun new_registry_and_admin_cap(ctx: &mut TxContext): (Registry, AdminCap) {
    (
        Registry {
            id: object::new(ctx),
            predict_id: option::none(),
            oracle_ids: table::new(ctx),
        },
        AdminCap {
            id: object::new(ctx),
        },
    )
}
