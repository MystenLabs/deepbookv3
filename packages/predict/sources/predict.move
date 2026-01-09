// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Main entry point for the DeepBook Predict protocol.
///
/// This module exposes all public functions for interacting with the binary options protocol:
///
/// LP Actions:
/// - `deposit()` - LP deposits USDC into vault, receives VaultShare
/// - `withdraw()` - LP burns VaultShare, receives USDC (after 24h lockup)
///
/// Trading Actions:
/// - `get_quote()` - Returns current (bid, ask) for a market
/// - `mint()` - Trader pays ask price in USDC, receives Position token
/// - `redeem()` - Trader returns Position, receives bid (pre-expiry) or settlement value (post-expiry)
///
/// Collateral Actions (for spreads):
/// - `mint_with_collateral()` - Lock a position as collateral to mint another position
/// - `unlock_collateral()` - Return minted position (or nothing if worthless) to unlock collateral
///
/// Admin Actions (require AdminCap):
/// - `create_market()` - Create a new binary options market
/// - `pause_trading()` / `unpause_trading()` - Emergency trading controls
/// - `pause_withdrawals()` / `unpause_withdrawals()` - Emergency withdrawal controls
/// - `update_*()` - Update risk parameters
///
/// Oracle Actions:
/// - `update_oracle()` - Oracle provider pushes new price/volatility data
///
/// All events are emitted from this module.
module deepbook_predict::predict;

use deepbook_predict::{
    market_manager::{Self, Markets, PositionCoin},
    oracle::Oracle,
    pricing::{Self, Pricing},
    vault::{Self, Vault}
};
use sui::{clock::Clock, coin::Coin};

// === Structs ===

/// Main shared object for the DeepBook Predict protocol.
/// Quote is the collateral asset (e.g., USDC).
public struct Predict<phantom Quote> has key {
    id: UID,
    /// All binary option markets
    markets: Markets<Quote>,
    /// Vault holding USDC and tracking exposure
    vault: Vault<Quote>,
    /// Pricing configuration
    pricing: Pricing,
}

// === Errors ===
const EInsufficientPayment: u64 = 0;
const EPositionMismatch: u64 = 1;

// === Public Functions ===

/// Mint position coins by paying USDC.
/// Takes both UP and DOWN PositionCoins to query net exposure.
/// Returns position coins and any change from overpayment.
public fun mint<Underlying, Quote>(
    predict: &mut Predict<Quote>,
    oracle: &Oracle<Underlying>,
    position_up: &PositionCoin<Quote>,
    position_down: &PositionCoin<Quote>,
    buying_up: bool,
    quantity: u64,
    mut payment: Coin<Quote>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<PositionCoin<Quote>>, Coin<Quote>) {
    // Validate positions match the oracle
    assert!(position_up.oracle_id() == oracle.id(), EPositionMismatch);
    assert!(position_down.oracle_id() == oracle.id(), EPositionMismatch);
    assert!(position_up.strike() == position_down.strike(), EPositionMismatch);

    oracle.assert_not_stale(clock);
    position_up.assert_is_up();
    position_down.assert_is_down();

    // Query net exposure for dynamic pricing
    let up_short = predict.vault.position(position_up);
    let down_short = predict.vault.position(position_down);

    // Get cost from pricing
    let strike = position_up.strike();
    let cost = predict
        .pricing
        .get_mint_cost(
            oracle,
            strike,
            buying_up,
            quantity,
            up_short,
            down_short,
            clock,
        );
    assert!(payment.value() >= cost, EInsufficientPayment);

    // Split exact cost, keep change
    let cost_coin = payment.split(cost, ctx);
    let change = payment;

    // Determine which position we're minting
    let position = if (buying_up) {
        position_up
    } else {
        position_down
    }; 

    // Deposit payment into vault and record short
    predict.vault.increase_exposure(position, quantity, cost_coin);

    // Mint position coins
    let position_coins = predict.markets.mint_position(position, quantity, ctx);

    (position_coins, change)
}

// === Public-Package Functions ===

/// Create and share the Predict object. Returns its ID.
public(package) fun create<Quote>(ctx: &mut TxContext): ID {
    let predict = Predict<Quote> {
        id: object::new(ctx),
        markets: market_manager::new<Quote>(ctx),
        vault: vault::new<Quote>(ctx),
        pricing: pricing::new(),
    };
    let predict_id = object::id(&predict);
    transfer::share_object(predict);

    predict_id
}

// === Private Functions ===
