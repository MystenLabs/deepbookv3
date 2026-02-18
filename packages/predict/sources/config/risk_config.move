// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Risk configuration - exposure limits for the vault.
module deepbook_predict::risk_config;

use deepbook_predict::constants;

// === Structs ===

public struct RiskConfig has store {
    /// Max total liability as % of balance (e.g., 800_000_000 = 80%)
    max_total_exposure_pct: u64,
}

// === Public Functions ===

public fun max_total_exposure_pct(config: &RiskConfig): u64 {
    config.max_total_exposure_pct
}

// === Public-Package Functions ===

public(package) fun new(): RiskConfig {
    RiskConfig {
        max_total_exposure_pct: constants::default_max_total_exposure_pct!(),
    }
}

public(package) fun set_max_total_exposure_pct(config: &mut RiskConfig, pct: u64) {
    config.max_total_exposure_pct = pct;
}
