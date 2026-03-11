// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Registry module for the Predict protocol.
///
/// Manages:
/// - `Registry` shared object that tracks oracles and the Predict ID
/// - `AdminCap` capability for admin operations
/// - Global pause flags for trading
///
/// The Registry is created once during package initialization.
/// AdminCap is transferred to the deployer (expected to be a multisig).
module deepbook_predict::registry;

use deepbook_predict::{oracle::{Self, OracleCapSVI, OracleSVI}, predict};
use std::string::String;
use sui::{coin::Coin, event, table::{Self, Table}};

// === Errors ===
const EPredictAlreadyCreated: u64 = 0;

// === Events ===

public struct PredictCreated has copy, drop, store {
    predict_id: ID,
}

public struct OracleCreated has copy, drop, store {
    oracle_id: ID,
    oracle_cap_id: ID,
    underlying_asset: String,
    expiry: u64,
}

public struct AdminVaultBalanceChanged has copy, drop, store {
    predict_id: ID,
    amount: u64,
    deposit: bool,
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
    /// OracleCap ID -> vector of oracle IDs created by that cap
    oracle_ids: Table<ID, vector<ID>>,
}

// === Public Functions ===

/// Get oracle IDs created by a given OracleCap.
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
    ctx: &mut TxContext,
): ID {
    assert!(registry.predict_id.is_none(), EPredictAlreadyCreated);

    let predict_id = predict::create<Quote>(ctx);
    registry.predict_id = option::some(predict_id);

    event::emit(PredictCreated { predict_id });

    predict_id
}

/// Register an additional OracleCapSVI as authorized to update an oracle.
public fun register_oracle_cap(oracle: &mut OracleSVI, _admin_cap: &AdminCap, cap: &OracleCapSVI) {
    oracle::register_cap(oracle, cap);
}

/// Create a new OracleCap. Transferred to Block Scholes operator.
public fun create_oracle_cap(_admin_cap: &AdminCap, ctx: &mut TxContext): OracleCapSVI {
    oracle::create_oracle_cap(ctx)
}

/// Create a new Oracle. Returns the oracle ID.
public fun create_oracle(
    registry: &mut Registry,
    _admin_cap: &AdminCap,
    cap: &OracleCapSVI,
    underlying_asset: String,
    expiry: u64,
    ctx: &mut TxContext,
): ID {
    let oracle_id = oracle::create_oracle(underlying_asset, expiry, ctx);
    let cap_id = object::id(cap);

    if (!registry.oracle_ids.contains(cap_id)) {
        registry.oracle_ids.add(cap_id, vector[]);
    };
    registry.oracle_ids[cap_id].push_back(oracle_id);

    event::emit(OracleCreated {
        oracle_id,
        oracle_cap_id: cap_id,
        underlying_asset,
        expiry,
    });

    oracle_id
}

/// Admin deposits USDC into the vault.
public fun admin_deposit<Quote>(
    predict: &mut predict::Predict<Quote>,
    _admin_cap: &AdminCap,
    coin: Coin<Quote>,
) {
    let amount = coin.value();
    predict.deposit(coin);
    event::emit(AdminVaultBalanceChanged {
        predict_id: object::id(predict),
        amount,
        deposit: true,
    });
}

/// Admin withdraws USDC from the vault.
public fun admin_withdraw<Quote>(
    predict: &mut predict::Predict<Quote>,
    _admin_cap: &AdminCap,
    amount: u64,
    ctx: &mut TxContext,
): Coin<Quote> {
    let coin = predict.withdraw(amount, ctx);
    event::emit(AdminVaultBalanceChanged {
        predict_id: object::id(predict),
        amount,
        deposit: false,
    });
    coin
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

/// Set max skew multiplier.
public fun set_max_skew_multiplier<Quote>(
    predict: &mut predict::Predict<Quote>,
    _admin_cap: &AdminCap,
    multiplier: u64,
) {
    predict.set_max_skew_multiplier(multiplier);
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
