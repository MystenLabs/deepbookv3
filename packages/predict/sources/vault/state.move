// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Vault state module - tracks exposure and liability.
///
/// Core struct:
/// - `State` stored inside Vault, containing:
///   - Net position per market (Table<MarketId, i64>)
///   - Total exposure value (sum of |position| * price)
///   - Total max liability (sum of |position| * $1)
///
/// Key responsibilities:
/// - Update exposure when positions are minted/redeemed
/// - Calculate available capital (balance - reserved for settlements)
/// - Track positions expiring within 24h for settlement reserve
///
/// Invariant: vault_balance >= total_max_liability
/// This ensures the vault can always pay out winning positions.
module deepbook_predict::state;



// === Imports ===

// === Errors ===

// === Structs ===

// === Public-Package Functions ===

// === Private Functions ===
