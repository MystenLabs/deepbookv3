// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Stored oracle policy config for market oracles.
///
/// ProtocolConfig owns the current global template. Each MarketOracle stores a
/// live copy initialized from that template, which admins can tune without
/// changing future-oracle defaults.
module deepbook_predict::market_oracle_config;

use deepbook::math;
use deepbook_predict::config_constants;

const EInvalidBasisBounds: u64 = 0;

/// Oracle bounds config stored as both a global template and live oracle copy.
public struct MarketOracleConfig has store {
    /// Maximum age for a source update to be usable for settlement.
    settlement_freshness_ms: u64,
    /// Maximum spot deviation allowed between consecutive Block Scholes pushes.
    max_spot_deviation: u64,
    /// Maximum basis deviation allowed between consecutive Block Scholes pushes.
    max_basis_deviation: u64,
    /// Minimum allowed forward / spot basis in FLOAT_SCALING.
    min_basis: u64,
    /// Maximum allowed forward / spot basis in FLOAT_SCALING.
    max_basis: u64,
}

// === Public-Package Functions ===

public(package) fun settlement_freshness_ms(config: &MarketOracleConfig): u64 {
    config.settlement_freshness_ms
}

public(package) fun max_spot_deviation(config: &MarketOracleConfig): u64 {
    config.max_spot_deviation
}

public(package) fun max_basis_deviation(config: &MarketOracleConfig): u64 {
    config.max_basis_deviation
}

public(package) fun min_basis(config: &MarketOracleConfig): u64 {
    config.min_basis
}

public(package) fun max_basis(config: &MarketOracleConfig): u64 {
    config.max_basis
}

public(package) fun settlement_source_fresh(
    config: &MarketOracleConfig,
    now: u64,
    timestamp: u64,
): bool {
    timestamp > 0 && timestamp <= now && now - timestamp <= config.settlement_freshness_ms
}

public(package) fun basis_in_range(config: &MarketOracleConfig, basis: u64): bool {
    basis >= config.min_basis && basis <= config.max_basis
}

public(package) fun spot_deviation_allowed(
    config: &MarketOracleConfig,
    prev_spot: u64,
    new_spot: u64,
): bool {
    within_deviation(prev_spot, new_spot, config.max_spot_deviation)
}

public(package) fun basis_deviation_allowed(
    config: &MarketOracleConfig,
    prev_basis: u64,
    new_basis: u64,
): bool {
    within_deviation(prev_basis, new_basis, config.max_basis_deviation)
}

public(package) fun new(): MarketOracleConfig {
    MarketOracleConfig {
        settlement_freshness_ms: config_constants::default_settlement_freshness_ms!(),
        max_spot_deviation: config_constants::default_max_spot_deviation!(),
        max_basis_deviation: config_constants::default_max_basis_deviation!(),
        min_basis: config_constants::default_min_basis!(),
        max_basis: config_constants::default_max_basis!(),
    }
}

/// Snapshot an existing oracle config into an independent live copy.
public(package) fun snapshot(config: &MarketOracleConfig): MarketOracleConfig {
    MarketOracleConfig {
        settlement_freshness_ms: config.settlement_freshness_ms,
        max_spot_deviation: config.max_spot_deviation,
        max_basis_deviation: config.max_basis_deviation,
        min_basis: config.min_basis,
        max_basis: config.max_basis,
    }
}

/// Set the settlement freshness threshold.
public(package) fun set_settlement_freshness_ms(config: &mut MarketOracleConfig, value: u64) {
    config_constants::assert_settlement_freshness_ms(value);
    config.settlement_freshness_ms = value;
}

/// Set basis guard bounds.
public(package) fun set_basis_bounds(
    config: &mut MarketOracleConfig,
    max_spot_deviation: u64,
    max_basis_deviation: u64,
    min_basis: u64,
    max_basis: u64,
) {
    assert_basis_bounds_inputs(max_spot_deviation, max_basis_deviation, min_basis, max_basis);
    config.max_spot_deviation = max_spot_deviation;
    config.max_basis_deviation = max_basis_deviation;
    config.min_basis = min_basis;
    config.max_basis = max_basis;
}

// === Private Functions ===

fun assert_basis_bounds_inputs(
    max_spot_deviation: u64,
    max_basis_deviation: u64,
    min_basis: u64,
    max_basis: u64,
) {
    config_constants::assert_max_spot_deviation(max_spot_deviation);
    config_constants::assert_max_basis_deviation(max_basis_deviation);
    config_constants::assert_min_basis(min_basis);
    config_constants::assert_max_basis(max_basis);
    assert!(min_basis < max_basis, EInvalidBasisBounds);
}

fun within_deviation(prev: u64, next: u64, max_deviation: u64): bool {
    let diff = if (next >= prev) { next - prev } else { prev - next };
    let max_allowed = math::mul(prev, max_deviation);
    diff <= max_allowed
}
