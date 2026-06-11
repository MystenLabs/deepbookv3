// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Stored oracle settlement policy config for market oracles.
///
/// ProtocolConfig owns the current global template. Each MarketOracle stores a
/// live copy initialized from that template, which admins can tune without
/// changing future-oracle defaults.
module deepbook_predict::market_oracle_config;

use deepbook_predict::config_constants;

/// Oracle settlement-freshness config stored as both a global template and live oracle copy.
public struct MarketOracleConfig has store {
    /// Maximum age for a source update to be usable for settlement.
    settlement_freshness_ms: u64,
}

// === Public-Package Functions ===

public(package) fun settlement_freshness_ms(config: &MarketOracleConfig): u64 {
    config.settlement_freshness_ms
}

public(package) fun settlement_source_fresh(
    config: &MarketOracleConfig,
    now: u64,
    timestamp: u64,
): bool {
    timestamp > 0 && timestamp <= now && now - timestamp <= config.settlement_freshness_ms
}

public(package) fun new(): MarketOracleConfig {
    MarketOracleConfig {
        settlement_freshness_ms: config_constants::default_settlement_freshness_ms!(),
    }
}

/// Snapshot an existing oracle config into an independent live copy.
public(package) fun snapshot(config: &MarketOracleConfig): MarketOracleConfig {
    MarketOracleConfig {
        settlement_freshness_ms: config.settlement_freshness_ms,
    }
}

/// Set the settlement freshness threshold.
public(package) fun set_settlement_freshness_ms(config: &mut MarketOracleConfig, value: u64) {
    config_constants::assert_settlement_freshness_ms(value);
    config.settlement_freshness_ms = value;
}
