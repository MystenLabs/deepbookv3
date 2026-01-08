// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Position module - represents user holdings in binary options markets.
///
/// Core struct:
/// - `Position` owned object representing a user's position:
///   - market_id (which market this position is for)
///   - amount (number of contracts, each pays $1 if winning)
///
/// Positions are fungible within the same market - two positions with the same
/// market_id can be merged. This enables secondary market trading.
///
/// Position lifecycle:
/// 1. Created via mint() - user pays ask price
/// 2. Can be transferred, split, merged
/// 3. Redeemed via redeem() - user receives bid (pre-expiry) or settlement value (post-expiry)
/// 4. Destroyed when redeemed
///
/// For collateral operations, positions can be locked in CollateralManager
/// to mint positions at different strikes.
module deepbook_predict::position;



// === Imports ===

// === Errors ===

// === Structs ===

// === Public Functions ===

// === Public-Package Functions ===

// === Private Functions ===
