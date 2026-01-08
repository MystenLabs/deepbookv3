// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Collateral module - enables capital-efficient spread positions.
///
/// Core struct:
/// - `CollateralManager` shared object containing:
///   - records: Table<ID, CollateralRecord>
///
/// Purpose:
/// Allow users to mint positions using other positions as collateral instead of USDC.
/// This enables spreads (bull spreads, bear spreads) with reduced capital requirements.
///
/// Collateral rules:
/// - For UP positions: lower strike UP can collateralize higher strike UP
///   (e.g., 90k UP can back 91k UP, because 90k UP is always worth >= 91k UP)
/// - For DOWN positions: higher strike DOWN can collateralize lower strike DOWN
///   (e.g., 91k DOWN can back 90k DOWN)
/// - Same expiry required
///
/// Example (Bull Spread):
/// 1. User has 90k UP position (worth $0.65)
/// 2. deposit_and_mint(90k UP, 91k UP) → locks 90k UP, mints 91k UP
/// 3. User sells 91k UP for $0.55
/// 4. Net cost: $0.10, max profit: $0.90 (if 90k < price < 91k)
/// 5. At expiry: unlock() to retrieve 90k UP (may need to return 91k UP if it has value)
module deepbook_predict::collateral;



// === Imports ===

// === Errors ===

// === Structs ===

// === Public-Package Functions ===

// === Private Functions ===
