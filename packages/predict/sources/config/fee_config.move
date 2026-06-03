// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Stored pool profit-share fee config.
///
/// PoolVault reads the current reserve share when materializing aggregate expiry profit.
module deepbook_predict::fee_config;

use deepbook_predict::config_constants;

/// Profit split policy.
public struct FeeConfig has store {
    /// Merged protocol and insurance reserve share in FLOAT_SCALING.
    protocol_reserve_profit_share: u64,
}

// === Public-Package Functions ===

public(package) fun protocol_reserve_profit_share(config: &FeeConfig): u64 {
    config.protocol_reserve_profit_share
}

public(package) fun new(): FeeConfig {
    FeeConfig {
        protocol_reserve_profit_share: config_constants::default_protocol_reserve_profit_share!(),
    }
}

public(package) fun set_protocol_reserve_profit_share(
    config: &mut FeeConfig,
    protocol_reserve_profit_share: u64,
) {
    config_constants::assert_protocol_reserve_profit_share(protocol_reserve_profit_share);
    config.protocol_reserve_profit_share = protocol_reserve_profit_share;
}
