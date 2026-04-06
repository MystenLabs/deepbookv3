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
use sui::{coin::TreasuryCap, event, table::{Self, Table}};

// === Errors ===
const EPredictAlreadyCreated: u64 = 0;
const EInvalidTickSize: u64 = 1;
const EInvalidStrikeGrid: u64 = 2;

// === Events ===

public struct PredictCreated has copy, drop, store {
    predict_id: ID,
}

public struct OracleCreated has copy, drop, store {
    oracle_id: ID,
    oracle_cap_id: ID,
    underlying_asset: String,
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
    treasury_cap: TreasuryCap<PLP>,
    ctx: &mut TxContext,
): ID {
    assert!(registry.predict_id.is_none(), EPredictAlreadyCreated);

    let predict_id = predict::create<Quote>(treasury_cap, ctx);
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
public fun create_oracle<Quote>(
    registry: &mut Registry,
    predict: &mut Predict<Quote>,
    _admin_cap: &AdminCap,
    cap: &OracleSVICap,
    underlying_asset: String,
    expiry: u64,
    min_strike: u64,
    tick_size: u64,
    ctx: &mut TxContext,
): ID {
    assert_valid_strike_grid(min_strike, tick_size);
    let oracle_id = oracle::create_oracle(underlying_asset, expiry, ctx);
    let cap_id = object::id(cap);

    if (!registry.oracle_ids.contains(cap_id)) {
        registry.oracle_ids.add(cap_id, vector[]);
    };
    registry.oracle_ids[cap_id].push_back(oracle_id);
    predict.add_oracle_grid(oracle_id, min_strike, tick_size);
    event::emit(OracleCreated {
        oracle_id,
        oracle_cap_id: cap_id,
        underlying_asset,
        expiry,
        min_strike,
        tick_size,
    });

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

/// Set base spread.
public fun set_base_spread<Quote>(
    predict: &mut predict::Predict<Quote>,
    _admin_cap: &AdminCap,
    spread: u64,
) {
    predict.set_base_spread(spread);
}

/// Set min spread.
public fun set_min_spread<Quote>(
    predict: &mut predict::Predict<Quote>,
    _admin_cap: &AdminCap,
    spread: u64,
) {
    predict.set_min_spread(spread);
}

/// Set utilization multiplier.
public fun set_utilization_multiplier<Quote>(
    predict: &mut predict::Predict<Quote>,
    _admin_cap: &AdminCap,
    multiplier: u64,
) {
    predict.set_utilization_multiplier(multiplier);
}

/// Set max total exposure percentage.
public fun set_max_total_exposure_pct<Quote>(
    predict: &mut predict::Predict<Quote>,
    _admin_cap: &AdminCap,
    pct: u64,
) {
    predict.set_max_total_exposure_pct(pct);
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
