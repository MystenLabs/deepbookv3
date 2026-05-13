// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Risk configuration for pool and expiry allocation limits.
module deepbook_predict::risk_config;

use deepbook_predict::config_constants;

const EInvalidResizeThresholds: u64 = 0;

/// Pool risk limits enforced by the parallel pool path.
public struct RiskConfig has store {
    /// Max total allocated exposure as % of pool value (e.g., 800_000_000 = 80%).
    max_total_exposure_pct: u64,
    /// DUSDC allocated to each newly created expiry market.
    expiry_allocation: u64,
    /// Expiry utilization at or above which permissionless growth is allowed.
    grow_utilization_threshold: u64,
    /// Expiry utilization at or below which permissionless shrink is allowed.
    shrink_utilization_threshold: u64,
    /// Multiplier used to target a larger allocation during growth.
    grow_factor: u64,
    /// Multiplier used to target a smaller allocation during shrink.
    shrink_factor: u64,
}

// === Public-Package Functions ===

/// Return the maximum total exposure percentage.
public(package) fun max_total_exposure_pct(config: &RiskConfig): u64 {
    config.max_total_exposure_pct
}

/// Return the current DUSDC allocation for a new expiry market.
public(package) fun expiry_allocation(config: &RiskConfig): u64 {
    config.expiry_allocation
}

/// Return the utilization threshold that enables allocation growth.
public(package) fun grow_utilization_threshold(config: &RiskConfig): u64 {
    config.grow_utilization_threshold
}

/// Return the utilization threshold that enables allocation shrink.
public(package) fun shrink_utilization_threshold(config: &RiskConfig): u64 {
    config.shrink_utilization_threshold
}

/// Return the growth target multiplier.
public(package) fun grow_factor(config: &RiskConfig): u64 {
    config.grow_factor
}

/// Return the shrink target multiplier.
public(package) fun shrink_factor(config: &RiskConfig): u64 {
    config.shrink_factor
}

/// Create risk config seeded from protocol defaults.
public(package) fun new(): RiskConfig {
    RiskConfig {
        max_total_exposure_pct: config_constants::default_max_total_exposure_pct!(),
        expiry_allocation: config_constants::default_allocation!(),
        grow_utilization_threshold: config_constants::default_grow_utilization_threshold!(),
        shrink_utilization_threshold: config_constants::default_shrink_utilization_threshold!(),
        grow_factor: config_constants::default_grow_factor!(),
        shrink_factor: config_constants::default_shrink_factor!(),
    }
}

/// Set the maximum total exposure percentage.
public(package) fun set_max_total_exposure_pct(config: &mut RiskConfig, pct: u64) {
    config_constants::assert_max_total_exposure_pct(pct);
    config.max_total_exposure_pct = pct;
}

/// Set the current DUSDC allocation for new expiry markets.
public(package) fun set_expiry_allocation(config: &mut RiskConfig, allocation: u64) {
    config_constants::assert_expiry_allocation(allocation);
    config.expiry_allocation = allocation;
}

/// Set the utilization threshold that enables allocation growth.
public(package) fun set_grow_utilization_threshold(config: &mut RiskConfig, threshold: u64) {
    config_constants::assert_grow_utilization_threshold(threshold);
    assert!(
        threshold >= config.shrink_utilization_threshold,
        EInvalidResizeThresholds,
    );
    config.grow_utilization_threshold = threshold;
}

/// Set the utilization threshold that enables allocation shrink.
public(package) fun set_shrink_utilization_threshold(config: &mut RiskConfig, threshold: u64) {
    config_constants::assert_shrink_utilization_threshold(threshold);
    assert!(
        threshold <= config.grow_utilization_threshold,
        EInvalidResizeThresholds,
    );
    config.shrink_utilization_threshold = threshold;
}

/// Set the growth target multiplier.
public(package) fun set_grow_factor(config: &mut RiskConfig, factor: u64) {
    config_constants::assert_grow_factor(factor);
    config.grow_factor = factor;
}

/// Set the shrink target multiplier.
public(package) fun set_shrink_factor(config: &mut RiskConfig, factor: u64) {
    config_constants::assert_shrink_factor(factor);
    config.shrink_factor = factor;
}

// === Test-Only Functions ===

#[test_only]
public fun destroy_for_testing(config: RiskConfig) {
    let RiskConfig {
        max_total_exposure_pct: _,
        expiry_allocation: _,
        grow_utilization_threshold: _,
        shrink_utilization_threshold: _,
        grow_factor: _,
        shrink_factor: _,
    } = config;
}
