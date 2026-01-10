// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Main entry point for the DeepBook Predict protocol.
///
/// This module exposes all public functions for interacting with the binary options protocol:
///
/// Trading Actions:
/// - `mint()` - Buy a position: pays USDC from PredictManager, receives position in manager
/// - `redeem()` - Sell a position: returns position, receives USDC into manager
///
/// Admin Actions (require AdminCap):
/// - `enable_market()` - Enable trading for an oracle + strike pair
///
/// All events are emitted from this module.
module deepbook_predict::predict;

use deepbook_predict::{
    market_key::MarketKey,
    market_manager::{Self, Markets},
    oracle::Oracle,
    predict_manager::PredictManager,
    vault::{Self, Vault}
};
use sui::clock::Clock;

// === Structs ===

/// Main shared object for the DeepBook Predict protocol.
/// Quote is the collateral asset (e.g., USDC).
public struct Predict<phantom Quote> has key {
    id: UID,
    /// Enabled markets tracker
    markets: Markets,
    /// Vault holding USDC and tracking exposure
    vault: Vault<Quote>,
}

// === Errors ===
const EOracleMismatch: u64 = 0;
const EExpiryMismatch: u64 = 1;

// === Public Functions ===

/// Buy a position. Cost is withdrawn from the PredictManager's balance.
/// Position quantity is added to the PredictManager's positions.
public fun mint<Underlying, Quote>(
    predict: &mut Predict<Quote>,
    manager: &mut PredictManager,
    oracle: &Oracle<Underlying>,
    key: MarketKey,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(key.oracle_id() == oracle.id(), EOracleMismatch);
    assert!(key.expiry() == oracle.expiry(), EExpiryMismatch);
    oracle.assert_not_stale(clock);
    predict.markets.assert_enabled(&key);

    // Calculate cost and withdraw from manager
    let cost = predict.vault.estimate_mint_cost(oracle, &key, quantity, clock);
    let payment = manager.withdraw<Quote>(cost, ctx);

    // Vault executes trade and marks to market
    predict.vault.mint(oracle, key, quantity, payment, clock);

    // Manager records long position
    manager.increase_position(key, quantity);
}

/// Sell a position. Payout is deposited into the PredictManager's balance.
/// Position quantity is removed from the PredictManager's positions.
public fun redeem<Underlying, Quote>(
    predict: &mut Predict<Quote>,
    manager: &mut PredictManager,
    oracle: &Oracle<Underlying>,
    key: MarketKey,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(key.oracle_id() == oracle.id(), EOracleMismatch);
    assert!(key.expiry() == oracle.expiry(), EExpiryMismatch);

    // Manager reduces long position first
    manager.decrease_position(key, quantity);

    // Vault executes trade, marks to market, returns payout
    let payout_balance = predict.vault.redeem(oracle, key, quantity, clock);

    // Deposit payout into manager
    let payout_coin = payout_balance.into_coin(ctx);
    manager.deposit(payout_coin, ctx);
}

// === Public-Package Functions ===

/// Create and share the Predict object. Returns its ID.
public(package) fun create<Quote>(ctx: &mut TxContext): ID {
    let predict = Predict<Quote> {
        id: object::new(ctx),
        markets: market_manager::new(),
        vault: vault::new<Quote>(ctx),
    };
    let predict_id = object::id(&predict);
    transfer::share_object(predict);

    predict_id
}

/// Enable a market for trading.
public(package) fun enable_market<Underlying, Quote>(
    predict: &mut Predict<Quote>,
    oracle: &Oracle<Underlying>,
    key: MarketKey,
) {
    predict.markets.enable_market(oracle, key);
}
