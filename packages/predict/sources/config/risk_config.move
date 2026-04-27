// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Risk configuration - exposure limits for the vault.
module deepbook_predict::risk_config;

use deepbook_predict::constants;

const EExceedsMaxPct: u64 = 0;
const EInvalidMtmFreshnessMs: u64 = 1;

/// Vault risk limits enforced by the Predict orchestrator.
public struct RiskConfig has store {
    /// Max total liability as % of balance (e.g., 800_000_000 = 80%)
    max_total_exposure_pct: u64,
    /// Max MTM age allowed for LP supply/withdraw gating.
    mtm_freshness_ms: u64,
}

// === Public Functions ===

/// Return the maximum total exposure percentage.
public fun max_total_exposure_pct(config: &RiskConfig): u64 {
    config.max_total_exposure_pct
}

/// Return the maximum allowed cached MTM age in milliseconds.
public fun mtm_freshness_ms(config: &RiskConfig): u64 {
    config.mtm_freshness_ms
}

// === Public-Package Functions ===

/// Create risk config seeded from protocol defaults.
public(package) fun new(): RiskConfig {
    RiskConfig {
        max_total_exposure_pct: constants::default_max_total_exposure_pct!(),
        mtm_freshness_ms: constants::default_mtm_freshness_ms!(),
    }
}

/// Set the maximum total exposure percentage.
public(package) fun set_max_total_exposure_pct(config: &mut RiskConfig, pct: u64) {
    assert!(pct > 0 && pct <= constants::float_scaling!(), EExceedsMaxPct);
    config.max_total_exposure_pct = pct;
}

/// Set the maximum allowed cached MTM age in milliseconds.
public(package) fun set_mtm_freshness_ms(config: &mut RiskConfig, value: u64) {
    assert!(value > 0, EInvalidMtmFreshnessMs);
    config.mtm_freshness_ms = value;
}
