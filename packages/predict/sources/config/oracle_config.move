// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Predict-owned oracle setup configuration.
///
/// This module stores feed bindings and the admin-tuned oracle freshness
/// thresholds used to seed new per-expiry market oracles.
module deepbook_predict::oracle_config;

use deepbook_predict::tuning_constants;
use std::string::String;
use sui::table::{Self, Table};

const EInvalidFreshnessThreshold: u64 = 0;
const EFeedIdNotConfigured: u64 = 1;

/// Predict-owned oracle setup configuration.
public struct OracleConfig has store {
    /// Per-underlying-asset Pyth Lazer feed ids. Admin must register an entry
    /// before `create_market_oracle` can be called for that asset.
    asset_feed_ids: Table<String, u64>,
    /// Admin-tuned maximum age for Pyth spot to be considered canonical.
    pyth_spot_freshness_ms: u64,
    /// Admin-tuned maximum age of the Block Scholes spot/forward update.
    block_scholes_prices_freshness_ms: u64,
    /// Admin-tuned maximum age of the Block Scholes SVI update.
    block_scholes_svi_freshness_ms: u64,
}

// === Public-Package Functions ===

/// Admin-tuned Pyth spot freshness threshold (ms) used to seed new oracles.
public(package) fun pyth_spot_freshness_ms(oracle_config: &OracleConfig): u64 {
    oracle_config.pyth_spot_freshness_ms
}

/// Admin-tuned Block Scholes spot/forward freshness threshold (ms) used to seed new oracles.
public(package) fun block_scholes_prices_freshness_ms(oracle_config: &OracleConfig): u64 {
    oracle_config.block_scholes_prices_freshness_ms
}

/// Admin-tuned Block Scholes SVI freshness threshold (ms) used to seed new oracles.
public(package) fun block_scholes_svi_freshness_ms(oracle_config: &OracleConfig): u64 {
    oracle_config.block_scholes_svi_freshness_ms
}

/// Resolve the Pyth Lazer feed id registered for `asset`, or abort if none
/// has been set.
public(package) fun resolve_feed_id(oracle_config: &OracleConfig, asset: String): u64 {
    assert!(oracle_config.asset_feed_ids.contains(asset), EFeedIdNotConfigured);
    oracle_config.asset_feed_ids[asset]
}

/// Create a new oracle-config registry seeded with the default freshness thresholds.
public(package) fun new(ctx: &mut TxContext): OracleConfig {
    OracleConfig {
        asset_feed_ids: table::new(ctx),
        pyth_spot_freshness_ms: tuning_constants::default_pyth_spot_freshness_ms!(),
        block_scholes_prices_freshness_ms: tuning_constants::default_block_scholes_prices_freshness_ms!(),
        block_scholes_svi_freshness_ms: tuning_constants::default_block_scholes_svi_freshness_ms!(),
    }
}

/// Return the values used to seed a new market oracle's bounds.
public(package) fun market_oracle_bounds_values(
    oracle_config: &OracleConfig,
): (u64, u64, u64, u64, u64, u64, u64) {
    (
        oracle_config.pyth_spot_freshness_ms,
        oracle_config.block_scholes_prices_freshness_ms,
        oracle_config.block_scholes_svi_freshness_ms,
        tuning_constants::default_max_spot_deviation!(),
        tuning_constants::default_max_basis_deviation!(),
        tuning_constants::default_min_basis!(),
        tuning_constants::default_max_basis!(),
    )
}

/// Admin setter: update the global Pyth spot freshness seed used by
/// subsequent `create_market_oracle` calls.
public(package) fun set_pyth_spot_freshness_ms(oracle_config: &mut OracleConfig, value: u64) {
    validate_freshness_ms(value);
    oracle_config.pyth_spot_freshness_ms = value;
}

/// Admin setter: update the global Block Scholes spot/forward freshness seed.
public(package) fun set_block_scholes_prices_freshness_ms(
    oracle_config: &mut OracleConfig,
    value: u64,
) {
    validate_freshness_ms(value);
    oracle_config.block_scholes_prices_freshness_ms = value;
}

/// Admin setter: update the global Block Scholes SVI freshness seed.
public(package) fun set_block_scholes_svi_freshness_ms(
    oracle_config: &mut OracleConfig,
    value: u64,
) {
    validate_freshness_ms(value);
    oracle_config.block_scholes_svi_freshness_ms = value;
}

/// Admin setter: bind `asset -> feed_id` so subsequent `create_market_oracle`
/// calls for that underlying resolve the Pyth Lazer feed id from config.
public(package) fun set_asset_feed_id(
    oracle_config: &mut OracleConfig,
    asset: String,
    feed_id: u64,
) {
    if (oracle_config.asset_feed_ids.contains(asset)) {
        let row = &mut oracle_config.asset_feed_ids[asset];
        *row = feed_id;
    } else {
        oracle_config.asset_feed_ids.add(asset, feed_id);
    }
}

// === Private Functions ===

/// Validate an admin-tuned freshness threshold.
fun validate_freshness_ms(value: u64) {
    assert!(
        value > 0 && value <= tuning_constants::max_freshness_threshold_ms!(),
        EInvalidFreshnessThreshold,
    );
}
