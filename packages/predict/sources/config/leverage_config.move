// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Stored leverage template for future expiry markets.
///
/// Protocol config stores the admin-tunable maximum terminal increase in the
/// contract floor index for future expiry markets. Each market snapshots that
/// value at creation so later admin updates do not reprice active markets.
module deepbook_predict::leverage_config;

use deepbook_predict::config_constants;

/// Leverage parameters expressed in Predict's 1e9 fixed-point price scaling.
public struct LeverageConfig has store {
    /// Maximum terminal increase in the contract floor index over one expiry.
    /// `200_000_000` means the floor index rises from 1.00 to 1.20.
    max_expiry_floor_premium: u64,
}

// === Public-Package Functions ===

public(package) fun max_expiry_floor_premium(config: &LeverageConfig): u64 {
    config.max_expiry_floor_premium
}

public(package) fun new(): LeverageConfig {
    LeverageConfig {
        max_expiry_floor_premium: config_constants::default_max_expiry_floor_premium!(),
    }
}

public(package) fun set_template_max_expiry_floor_premium(config: &mut LeverageConfig, value: u64) {
    config_constants::assert_max_expiry_floor_premium(value);
    config.max_expiry_floor_premium = value;
}
