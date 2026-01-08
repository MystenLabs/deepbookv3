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



// === Imports ===

// === Errors ===

// === Events ===

// === Public Functions * LP * ===

// === Public Functions * TRADING * ===

// === Public Functions * COLLATERAL * ===

// === Public Functions * ADMIN * ===

// === Public Functions * ORACLE * ===

// === Private Functions ===
