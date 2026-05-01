// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Predict-owned market setup configuration.
///
/// This module stores feed bindings and the admin-tuned oracle freshness
/// thresholds used to seed new per-expiry market oracles.
module deepbook_predict::market_config;

use deepbook_predict::{market_oracle::{Self, MarketOracleBounds}, tuning_constants};
use std::string::String;
use sui::table::{Self, Table};

const EInvalidFreshnessThreshold: u64 = 0;
const EFeedIdNotConfigured: u64 = 1;

/// Predict-owned market setup configuration.
public struct MarketConfig has store {
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
public(package) fun pyth_spot_freshness_ms(market_config: &MarketConfig): u64 {
    market_config.pyth_spot_freshness_ms
}

/// Admin-tuned Block Scholes spot/forward freshness threshold (ms) used to seed new oracles.
public(package) fun block_scholes_prices_freshness_ms(market_config: &MarketConfig): u64 {
    market_config.block_scholes_prices_freshness_ms
}

/// Admin-tuned Block Scholes SVI freshness threshold (ms) used to seed new oracles.
public(package) fun block_scholes_svi_freshness_ms(market_config: &MarketConfig): u64 {
    market_config.block_scholes_svi_freshness_ms
}

/// Resolve the Pyth Lazer feed id registered for `asset`, or abort if none
/// has been set.
public(package) fun resolve_feed_id(market_config: &MarketConfig, asset: String): u64 {
    assert!(market_config.asset_feed_ids.contains(asset), EFeedIdNotConfigured);
    market_config.asset_feed_ids[asset]
}

/// Create a new market-config registry seeded with the default freshness thresholds.
public(package) fun new(ctx: &mut TxContext): MarketConfig {
    MarketConfig {
        asset_feed_ids: table::new(ctx),
        pyth_spot_freshness_ms: tuning_constants::default_pyth_spot_freshness_ms!(),
        block_scholes_prices_freshness_ms: tuning_constants::default_block_scholes_prices_freshness_ms!(),
        block_scholes_svi_freshness_ms: tuning_constants::default_block_scholes_svi_freshness_ms!(),
    }
}

/// Build a `MarketOracleBounds` snapshot for a new market oracle.
public(package) fun build_market_oracle_bounds(market_config: &MarketConfig): MarketOracleBounds {
    market_oracle::new_bounds(
        market_config.pyth_spot_freshness_ms,
        market_config.block_scholes_prices_freshness_ms,
        market_config.block_scholes_svi_freshness_ms,
        tuning_constants::default_max_spot_deviation!(),
        tuning_constants::default_max_basis_deviation!(),
        tuning_constants::default_min_basis!(),
        tuning_constants::default_max_basis!(),
    )
}

/// Admin setter: update the global Pyth spot freshness seed used by
/// subsequent `create_market_oracle` calls.
public(package) fun set_pyth_spot_freshness_ms(market_config: &mut MarketConfig, value: u64) {
    validate_freshness_ms(value);
    market_config.pyth_spot_freshness_ms = value;
}

/// Admin setter: update the global Block Scholes spot/forward freshness seed.
public(package) fun set_block_scholes_prices_freshness_ms(
    market_config: &mut MarketConfig,
    value: u64,
) {
    validate_freshness_ms(value);
    market_config.block_scholes_prices_freshness_ms = value;
}

/// Admin setter: update the global Block Scholes SVI freshness seed.
public(package) fun set_block_scholes_svi_freshness_ms(
    market_config: &mut MarketConfig,
    value: u64,
) {
    validate_freshness_ms(value);
    market_config.block_scholes_svi_freshness_ms = value;
}

/// Admin setter: bind `asset -> feed_id` so subsequent `create_market_oracle`
/// calls for that underlying resolve the Pyth Lazer feed id from config.
public(package) fun set_asset_feed_id(
    market_config: &mut MarketConfig,
    asset: String,
    feed_id: u64,
) {
    if (market_config.asset_feed_ids.contains(asset)) {
        let row = &mut market_config.asset_feed_ids[asset];
        *row = feed_id;
    } else {
        market_config.asset_feed_ids.add(asset, feed_id);
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
