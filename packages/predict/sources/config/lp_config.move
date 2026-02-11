// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// LP configuration - settings for liquidity providers.
module deepbook_predict::lp_config;

use deepbook_predict::constants;

// === Structs ===

public struct LPConfig has store {
    lockup_period_ms: u64,
}

// === Public Functions ===

public fun lockup_period_ms(config: &LPConfig): u64 {
    config.lockup_period_ms
}

// === Public-Package Functions ===

public(package) fun new(): LPConfig {
    LPConfig {
        lockup_period_ms: constants::default_min_lockup_ms!(),
    }
}

public(package) fun set_lockup_period(config: &mut LPConfig, period_ms: u64) {
    config.lockup_period_ms = period_ms;
}
