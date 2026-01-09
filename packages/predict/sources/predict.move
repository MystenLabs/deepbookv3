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

use deepbook_predict::{market_manager::{Self, Markets}, pricing::{Self, Pricing}};

// === Structs ===

/// Main shared object for the DeepBook Predict protocol.
/// Quote is the collateral asset (e.g., USDC).
public struct Predict<phantom Quote> has key {
    id: UID,
    /// All binary option markets
    markets: Markets<Quote>,
    /// Pricing configuration
    pricing: Pricing,
}

// === Public Functions ===

// === Public-Package Functions ===

/// Create and share the Predict object. Returns its ID.
public(package) fun create<Quote>(ctx: &mut TxContext): ID {
    let predict = Predict<Quote> {
        id: object::new(ctx),
        markets: market_manager::new<Quote>(ctx),
        pricing: pricing::new(),
    };
    let predict_id = object::id(&predict);
    transfer::share_object(predict);

    predict_id
}

// === Private Functions ===
