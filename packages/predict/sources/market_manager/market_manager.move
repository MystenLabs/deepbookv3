// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Market manager module - tracks enabled markets for binary options.
///
/// A market is defined by an oracle (which has an underlying + expiry) and a strike.
/// When a market is enabled, both UP and DOWN positions can be traded at that strike.
module deepbook_predict::market_manager;

use deepbook_predict::{oracle::Oracle, position_key::PositionKey};
use sui::vec_set::{Self, VecSet};

// === Errors ===
const EMarketAlreadyEnabled: u64 = 0;
const EMarketNotEnabled: u64 = 1;
const EOracleNotActive: u64 = 2;
const EStrikeNotFound: u64 = 3;

// === Structs ===

/// Tracks which markets are enabled for trading.
/// Stored in the main Predict object.
public struct Markets has store {
    /// Set of enabled market keys
    enabled: VecSet<PositionKey>,
}

// === Public Functions ===

/// Check if a market is enabled.
public fun is_enabled(markets: &Markets, key: &PositionKey): bool {
    markets.enabled.contains(key)
}

// === Public-Package Functions ===

/// Create a new Markets tracker.
public(package) fun new(): Markets {
    Markets { enabled: vec_set::empty() }
}

/// Enable a market for a given oracle and strike.
/// Validates that the oracle is active and the strike exists.
public(package) fun enable_market<Underlying>(
    markets: &mut Markets,
    oracle: &Oracle<Underlying>,
    key: PositionKey,
) {
    assert!(oracle.is_active(), EOracleNotActive);
    assert!(oracle.has_strike(key.strike()), EStrikeNotFound);

    assert!(!markets.enabled.contains(&key), EMarketAlreadyEnabled);

    markets.enabled.insert(key);
}

/// Disable a market.
public(package) fun disable_market(markets: &mut Markets, key: &PositionKey) {
    assert!(markets.enabled.contains(key), EMarketNotEnabled);

    markets.enabled.remove(key);
}

/// Assert that a market is enabled.
public(package) fun assert_enabled(markets: &Markets, key: &PositionKey) {
    assert!(is_enabled(markets, key), EMarketNotEnabled);
}
