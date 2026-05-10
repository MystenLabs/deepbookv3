// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Predict-owned oracle setup configuration.
///
/// This module stores feed bindings used when creating per-expiry market
/// oracles.
module deepbook_predict::oracle_config;

use std::string::String;
use sui::table::{Self, Table};

const EFeedIdNotConfigured: u64 = 1;
const EFeedIdOverflow: u64 = 2;

/// Predict-owned oracle setup configuration.
public struct OracleConfig has store {
    /// Per-underlying-asset Pyth Lazer feed ids. Admin must register an entry
    /// before `create_market_oracle` can be called for that asset.
    asset_feed_ids: Table<String, u64>,
}

// === Public-Package Functions ===

/// Resolve the Pyth Lazer feed id registered for `asset`, or abort if none
/// has been set.
public(package) fun resolve_feed_id(oracle_config: &OracleConfig, asset: String): u64 {
    assert!(oracle_config.asset_feed_ids.contains(asset), EFeedIdNotConfigured);
    oracle_config.asset_feed_ids[asset]
}

/// Create a new oracle-config registry.
public(package) fun new(ctx: &mut TxContext): OracleConfig {
    OracleConfig {
        asset_feed_ids: table::new(ctx),
    }
}

/// Admin setter: bind `asset -> feed_id` so subsequent `create_market_oracle`
/// calls for that underlying resolve the Pyth Lazer feed id from config.
public(package) fun set_asset_feed_id(
    oracle_config: &mut OracleConfig,
    asset: String,
    feed_id: u64,
) {
    assert!(feed_id <= 0xFFFF_FFFF, EFeedIdOverflow);
    if (oracle_config.asset_feed_ids.contains(asset)) {
        let row = &mut oracle_config.asset_feed_ids[asset];
        *row = feed_id;
    } else {
        oracle_config.asset_feed_ids.add(asset, feed_id);
    }
}
