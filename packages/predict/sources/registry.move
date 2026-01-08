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

use deepbook_predict::{oracle::{Self, OracleCap}, predict};
use sui::{clock::Clock, table::{Self, Table}};

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
    /// Whether trading is globally paused
    trading_paused: bool,
    /// Whether LP withdrawals are globally paused
    withdrawals_paused: bool,
}

// === Public Functions ===

/// Create the Predict shared object. Can only be called once.
public fun create_predict<Asset>(
    registry: &mut Registry,
    _admin_cap: &AdminCap,
    ctx: &mut TxContext,
): ID {
    assert!(registry.predict_id.is_none(), EPredictAlreadyCreated);

    let predict_id = predict::create<Asset>(ctx);
    registry.predict_id = option::some(predict_id);

    predict_id
}

/// Create a new OracleCap. Transferred to Block Scholes operator.
public fun create_oracle_cap(_admin_cap: &AdminCap, ctx: &mut TxContext): OracleCap {
    oracle::create_oracle_cap(ctx)
}

/// Create a new Oracle. Returns the oracle ID.
public fun create_oracle<Asset>(
    registry: &mut Registry,
    _admin_cap: &AdminCap,
    cap: &OracleCap,
    expiry: u64,
    strikes: vector<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    let oracle_id = oracle::create_oracle<Asset>(cap, expiry, strikes, clock, ctx);
    let cap_id = object::id(cap);

    if (!registry.oracle_ids.contains(cap_id)) {
        registry.oracle_ids.add(cap_id, vector[]);
    };
    registry.oracle_ids[cap_id].push_back(oracle_id);

    oracle_id
}

// === Public-Package Functions ===

/// Check if trading is paused.
public(package) fun is_trading_paused(registry: &Registry): bool {
    registry.trading_paused
}

/// Check if withdrawals are paused.
public(package) fun is_withdrawals_paused(registry: &Registry): bool {
    registry.withdrawals_paused
}

// === Private Functions ===

/// Package initializer - creates Registry and AdminCap.
fun init(ctx: &mut TxContext) {
    let registry = Registry {
        id: object::new(ctx),
        predict_id: option::none(),
        oracle_ids: table::new(ctx),
        trading_paused: false,
        withdrawals_paused: false,
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
