// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Risk configuration - exposure limits for the vault.
module deepbook_predict::risk_config;

use deepbook_predict::constants;

const EExceedsMaxPct: u64 = 0;

/// Pool risk limits enforced by the parallel pool path.
public struct RiskConfig has store {
    /// Max total allocated exposure as % of pool value (e.g., 800_000_000 = 80%).
    max_total_exposure_pct: u64,
}

// === Public Functions ===

/// Return the maximum total exposure percentage.
public fun max_total_exposure_pct(config: &RiskConfig): u64 {
    config.max_total_exposure_pct
}

// === Public-Package Functions ===

/// Create risk config seeded from protocol defaults.
public(package) fun new(): RiskConfig {
    RiskConfig {
        max_total_exposure_pct: constants::default_max_total_exposure_pct!(),
    }
}

/// Set the maximum total exposure percentage.
public(package) fun set_max_total_exposure_pct(config: &mut RiskConfig, pct: u64) {
    assert!(pct > 0 && pct <= constants::float_scaling!(), EExceedsMaxPct);
    config.max_total_exposure_pct = pct;
}
