// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Collateral record module - tracks individual collateral deposits.
///
/// Core struct:
/// - `CollateralRecord` stored in CollateralManager:
///   - id: unique identifier for this record
///   - owner: address that created the record
///   - collateral_market_id: the position locked as collateral (e.g., 90k UP)
///   - minted_market_id: the position minted against collateral (e.g., 91k UP)
///   - amount: number of contracts
///   - created_at: timestamp for tracking
///
/// Lifecycle:
/// 1. Created when user calls mint_with_collateral()
/// 2. Collateral position is locked (held by CollateralManager)
/// 3. User receives minted position + record ID
/// 4. At unlock():
///    - If minted position is worthless (post-expiry, lost): no return required
///    - If minted position has value: user must return it
///    - Collateral position is returned to user
/// 5. Record is deleted
module deepbook_predict::record;



// === Imports ===

// === Errors ===

// === Structs ===

// === Public-Package Functions ===

// === Private Functions ===
