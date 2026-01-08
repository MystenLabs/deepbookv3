// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Market module - defines binary options markets.
///
/// Core structs:
/// - `MarketId` unique identifier for each market:
///   - underlying (TypeName, e.g., BTC)
///   - strike (u64, e.g., 90000 * PRICE_SCALING)
///   - expiry (u64, timestamp in ms)
///   - direction (u8, 0 = UP, 1 = DOWN)
///
/// - `Market` metadata stored in Registry:
///   - market_id
///   - created_at timestamp
///   - status (active, expired, settled)
///   - settlement_price (set after expiry)
///
/// Market lifecycle:
/// 1. Admin creates market (status = active)
/// 2. Trading occurs until expiry
/// 3. After expiry, first redeem sets settlement_price (status = settled)
/// 4. Users redeem winning positions ($1) or losing positions ($0)
/// 5. After 7-day grace period, unclaimed funds go to vault
///
/// UP and DOWN are inverses: UP_price + DOWN_price = $1
module deepbook_predict::market;



// === Imports ===

// === Errors ===

// === Constants ===

// === Structs ===

// === Public Functions ===

// === Public-Package Functions ===

// === Private Functions ===
