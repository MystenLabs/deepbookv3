// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Oracle module for the Predict protocol.
///
/// Manages external price data from Block Scholes:
/// - `Oracle` shared object (one per expiry)
/// - `OracleCap` capability for authorized oracle updates
/// - `OracleData` struct containing spot price, volatility surface, risk-free rate
///
/// Key responsibilities:
/// - Receive and store volatility surface updates (~1 update/second)
/// - Provide spot price and implied volatility for pricing calculations
/// - Staleness checks (data older than 30s is considered stale)
/// - When stale: trading paused, only redemptions allowed
///
/// The volatility surface allows pricing multiple strikes from a single oracle per expiry.
module deepbook_predict::oracle;



// === Imports ===

// === Errors ===

// === Structs ===

// === Public Functions ===

// === Public-Package Functions ===

// === Private Functions ===
