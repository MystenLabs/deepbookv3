// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Risk configuration for pool and expiry allocation limits.
module deepbook_predict::risk_config;

use deepbook_predict::config_constants;

/// Pool risk limits enforced by the parallel pool path.
public struct RiskConfig has store {
    /// Max total allocated exposure as % of pool value (e.g., 800_000_000 = 80%).
    max_total_exposure_pct: u64,
}

// === Public-Package Functions ===

/// Return the maximum total exposure percentage.
public(package) fun max_total_exposure_pct(config: &RiskConfig): u64 {
    config.max_total_exposure_pct
}

/// Create risk config seeded from protocol defaults.
public(package) fun new(): RiskConfig {
    RiskConfig {
        max_total_exposure_pct: config_constants::default_max_total_exposure_pct!(),
    }
}

/// Set the maximum total exposure percentage.
public(package) fun set_max_total_exposure_pct(config: &mut RiskConfig, pct: u64) {
    config_constants::assert_max_total_exposure_pct(pct);
    config.max_total_exposure_pct = pct;
}
