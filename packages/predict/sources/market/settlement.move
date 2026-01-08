// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Settlement module - determines outcomes after market expiry.
///
/// Key responsibilities:
/// - Determine settlement price from oracle at expiry timestamp
/// - Compare settlement price vs strike to determine winner (UP or DOWN)
/// - Calculate payout: $1 for winning side, $0 for losing side
///
/// Settlement flow:
/// 1. Market expires (current_time >= expiry)
/// 2. First redeem() call triggers settlement:
///    - Fetch settlement price from oracle (price at expiry timestamp)
///    - Compare vs strike: if price > strike, UP wins; else DOWN wins
///    - Store settlement result in Market
/// 3. Subsequent redeems use stored settlement result
///
/// Grace period:
/// - Users have 7 days after expiry to claim positions
/// - After grace period, admin can sweep unclaimed funds to vault
///
/// Edge cases:
/// - If oracle price exactly equals strike: DOWN wins (price must be strictly above)
/// - If oracle is stale at settlement time: use last known price
module deepbook_predict::settlement;



// === Imports ===

// === Errors ===

// === Structs ===

// === Public-Package Functions ===

// === Private Functions ===
