// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Stored leverage template for future expiry markets.
///
/// Protocol config stores admin-tunable leverage policy for future expiry
/// markets. Each market snapshots these values at creation so later admin
/// updates do not reprice active markets.
module deepbook_predict::leverage_config;

use deepbook_predict::config_constants;

/// Leverage parameters expressed in Predict's 1e9 fixed-point price scaling.
public struct LeverageConfig has store {
    /// Maximum terminal increase in the contract floor index over one expiry.
    /// `200_000_000` means the floor index rises from 1.00 to 1.20.
    max_expiry_floor_premium: u64,
    /// 1e9-scaled floor-to-live-value threshold for liquidation.
    /// `850_000_000` means liquidate at 85% LTV.
    liquidation_ltv: u64,
}

// === Public-Package Functions ===

public(package) fun max_expiry_floor_premium(config: &LeverageConfig): u64 {
    config.max_expiry_floor_premium
}

public(package) fun liquidation_ltv(config: &LeverageConfig): u64 {
    config.liquidation_ltv
}

public(package) fun new(): LeverageConfig {
    LeverageConfig {
        max_expiry_floor_premium: config_constants::default_max_expiry_floor_premium!(),
        liquidation_ltv: config_constants::default_liquidation_ltv!(),
    }
}

public(package) fun set_template_max_expiry_floor_premium(config: &mut LeverageConfig, value: u64) {
    config_constants::assert_max_expiry_floor_premium(value);
    config.max_expiry_floor_premium = value;
}

public(package) fun set_template_liquidation_ltv(config: &mut LeverageConfig, value: u64) {
    config_constants::assert_liquidation_ltv(value);
    config.liquidation_ltv = value;
}
