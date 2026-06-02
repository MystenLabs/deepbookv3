// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Stored oracle policy values for market oracle settlement and push guards.
///
/// `ProtocolConfig` owns a global template for future expiries and stamps a
/// mutable per-expiry copy when an expiry market is created. `MarketOracle`
/// cap-authorized setters mutate that stamped copy through `ProtocolConfig`.
module deepbook_predict::market_oracle_config;

use deepbook_predict::config_constants;

const EInvalidBasisBounds: u64 = 0;

/// Oracle bounds/freshness policy used as both template and per-expiry copy.
public struct MarketOracleConfig has copy, drop, store {
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

public(package) fun new(): MarketOracleConfig {
    MarketOracleConfig {
        settlement_freshness_ms: config_constants::default_settlement_freshness_ms!(),
        max_spot_deviation: config_constants::default_max_spot_deviation!(),
        max_basis_deviation: config_constants::default_max_basis_deviation!(),
        min_basis: config_constants::default_min_basis!(),
        max_basis: config_constants::default_max_basis!(),
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
