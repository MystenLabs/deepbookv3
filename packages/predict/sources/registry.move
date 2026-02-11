// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Registry module for the Predict protocol.
///
/// Manages:
/// - `Registry` shared object that tracks all markets
/// - `AdminCap` capability for admin operations
/// - Market registration and lookup
/// - Global pause flags for trading and withdrawals
///
/// The Registry is created once during package initialization.
/// AdminCap is transferred to the deployer (expected to be a multisig).
module deepbook_predict::registry;

use deepbook_predict::{
    market_key::MarketKey,
    oracle_block_scholes::{Self, OracleCapSVI, OracleSVI},
    predict
};
use sui::table::{Self, Table};

// === Errors ===
const EPredictAlreadyCreated: u64 = 0;

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
    /// OracleCap ID -> vector of oracle IDs created by that cap
    oracle_ids: Table<ID, vector<ID>>,
}

// === Public Functions ===

/// Create the Predict shared object. Can only be called once.
/// Quote is the collateral asset (e.g., USDC).
public fun create_predict<Quote>(
    registry: &mut Registry,
    _admin_cap: &AdminCap,
    ctx: &mut TxContext,
): ID {
    assert!(registry.predict_id.is_none(), EPredictAlreadyCreated);

    let predict_id = predict::create<Quote>(ctx);
    registry.predict_id = option::some(predict_id);

    predict_id
}

/// Create a new OracleCap. Transferred to Block Scholes operator.
public fun create_oracle_cap(_admin_cap: &AdminCap, ctx: &mut TxContext): OracleCapSVI {
    oracle_block_scholes::create_oracle_cap(ctx)
}

/// Create a new Oracle. Returns the oracle ID.
/// Underlying is the asset being tracked (e.g., BTC, ETH).
public fun create_oracle<Underlying>(
    registry: &mut Registry,
    _admin_cap: &AdminCap,
    cap: &OracleCapSVI,
    expiry: u64,
    ctx: &mut TxContext,
): ID {
    let oracle_id = oracle_block_scholes::create_oracle<Underlying>(cap, expiry, ctx);
    let cap_id = object::id(cap);

    if (!registry.oracle_ids.contains(cap_id)) {
        registry.oracle_ids.add(cap_id, vector[]);
    };
    registry.oracle_ids[cap_id].push_back(oracle_id);

    oracle_id
}

/// Set trading pause state.
public fun set_trading_paused<Quote>(
    predict: &mut predict::Predict<Quote>,
    _admin_cap: &AdminCap,
    paused: bool,
) {
    predict.set_trading_paused(paused);
}

/// Set withdrawals pause state.
public fun set_withdrawals_paused<Quote>(
    predict: &mut predict::Predict<Quote>,
    _admin_cap: &AdminCap,
    paused: bool,
) {
    predict.set_withdrawals_paused(paused);
}

/// Enable a market for trading.
public fun enable_market<Underlying, Quote>(
    predict: &mut predict::Predict<Quote>,
    _admin_cap: &AdminCap,
    oracle: &OracleSVI<Underlying>,
    key: MarketKey,
) {
    predict.enable_market(oracle, key);
}

/// Set LP lockup period.
public fun set_lockup_period<Quote>(
    predict: &mut predict::Predict<Quote>,
    _admin_cap: &AdminCap,
    period_ms: u64,
) {
    predict.set_lockup_period(period_ms);
}

/// Set base spread.
public fun set_base_spread<Quote>(
    predict: &mut predict::Predict<Quote>,
    _admin_cap: &AdminCap,
    spread: u64,
) {
    predict.set_base_spread(spread);
}

/// Set max skew multiplier.
public fun set_max_skew_multiplier<Quote>(
    predict: &mut predict::Predict<Quote>,
    _admin_cap: &AdminCap,
    multiplier: u64,
) {
    predict.set_max_skew_multiplier(multiplier);
}

/// Set max total exposure percentage.
public fun set_max_total_exposure_pct<Quote>(
    predict: &mut predict::Predict<Quote>,
    _admin_cap: &AdminCap,
    pct: u64,
) {
    predict.set_max_total_exposure_pct(pct);
}

/// Set max per-market exposure percentage.
public fun set_max_per_market_exposure_pct<Quote>(
    predict: &mut predict::Predict<Quote>,
    _admin_cap: &AdminCap,
    pct: u64,
) {
    predict.set_max_per_market_exposure_pct(pct);
}

// === Private Functions ===

/// Package initializer - creates Registry and AdminCap.
fun init(ctx: &mut TxContext) {
    let registry = Registry {
        id: object::new(ctx),
        predict_id: option::none(),
        oracle_ids: table::new(ctx),
    };
    transfer::share_object(registry);

    let admin_cap = AdminCap {
        id: object::new(ctx),
    };
    transfer::transfer(admin_cap, ctx.sender());
}

// === Test Functions ===
#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun create_admin_cap_for_testing(ctx: &mut TxContext): AdminCap {
    AdminCap { id: object::new(ctx) }
}
