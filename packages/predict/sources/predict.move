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

use deepbook_predict::market_manager::{Self, Markets};
use deepbook_predict::oracle::Oracle;
use deepbook_predict::position_key::PositionKey;
use deepbook_predict::predict_manager::PredictManager;
use deepbook_predict::pricing::{Self, Pricing};
use deepbook_predict::vault::{Self, Vault};
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
    /// Pricing configuration
    pricing: Pricing,
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
    key: PositionKey,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(key.oracle_id() == oracle.id(), EOracleMismatch);
    assert!(key.expiry() == oracle.expiry(), EExpiryMismatch);
    oracle.assert_not_stale(clock);
    predict.markets.assert_enabled(oracle.id(), key.strike());

    // Get vault exposure for pricing
    let (up_short, down_short) = predict.vault.pair_position(key);

    // Calculate cost
    let cost = predict.pricing.get_mint_cost(oracle, &key, quantity, up_short, down_short, clock);

    // Withdraw cost from manager
    let payment = manager.withdraw<Quote>(cost, ctx);

    // Vault receives payment and goes short
    predict.vault.increase_exposure(key, quantity, payment);

    // Manager records long position
    manager.increase_position(key, quantity);
}

/// Sell a position. Payout is deposited into the PredictManager's balance.
/// Position quantity is removed from the PredictManager's positions.
public fun redeem<Underlying, Quote>(
    predict: &mut Predict<Quote>,
    manager: &mut PredictManager,
    oracle: &Oracle<Underlying>,
    key: PositionKey,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(key.oracle_id() == oracle.id(), EOracleMismatch);
    assert!(key.expiry() == oracle.expiry(), EExpiryMismatch);

    // Get vault exposure for pricing
    let (up_short, down_short) = predict.vault.pair_position(key);

    // Calculate payout
    let payout = predict
        .pricing
        .get_redeem_payout(oracle, &key, quantity, up_short, down_short, clock);

    // Manager reduces long position
    manager.decrease_position(key, quantity);

    // Vault reduces short and pays out
    let payout_balance = predict.vault.decrease_exposure(key, quantity, payout);

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
        pricing: pricing::new(),
    };
    let predict_id = object::id(&predict);
    transfer::share_object(predict);

    predict_id
}

/// Enable a market for trading.
public(package) fun enable_market<Underlying, Quote>(
    predict: &mut Predict<Quote>,
    oracle: &Oracle<Underlying>,
    strike: u64,
) {
    predict.markets.enable_market(oracle, strike);
}
