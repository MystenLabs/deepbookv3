// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Vault configuration module - risk parameters.
///
/// Core struct:
/// - `Config` stored inside Vault, containing all tunable parameters:
///   - max_single_trade_pct (default: 5%) - max size of single trade vs available capital
///   - max_exposure_per_market_pct (default: 20%) - max exposure in any single market
///   - max_total_exposure_pct (default: 80%) - max total exposure across all markets
///   - base_spread_bps (default: 100 = 1%) - base bid/ask spread
///   - max_spread_adjustment_bps (default: 200 = 2%) - max spread widening from inventory
///   - oracle_staleness_threshold_ms (default: 30000 = 30s) - when oracle is stale
///   - min_lockup_ms (default: 86400000 = 24h) - LP withdrawal lockup
///
/// All parameters can be updated by admin via update_*() functions.
/// Changes take effect immediately (no timelock).
module deepbook_predict::config;



// === Imports ===

// === Errors ===

// === Structs ===

// === Public Functions ===

// === Public-Package Functions ===

// === Private Functions ===
