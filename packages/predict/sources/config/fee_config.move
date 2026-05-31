// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Stored fee policy config.
///
/// PoolVault reads the current reserve share when materializing aggregate expiry profit.
/// Expiry markets snapshot the trading loss rebate rate at creation.
module deepbook_predict::fee_config;

use deepbook_predict::config_constants;

/// Profit split and trading loss rebate policy.
public struct FeeConfig has store {
    /// Merged protocol and insurance reserve share in FLOAT_SCALING.
    protocol_reserve_profit_share: u64,
    /// Fraction of aggregate expiry trading fees reserved for loss rebates.
    trading_loss_rebate_rate: u64,
}

// === Public-Package Functions ===

public(package) fun protocol_reserve_profit_share(config: &FeeConfig): u64 {
    config.protocol_reserve_profit_share
}

public(package) fun trading_loss_rebate_rate(config: &FeeConfig): u64 {
    config.trading_loss_rebate_rate
}

public(package) fun new(): FeeConfig {
    FeeConfig {
        protocol_reserve_profit_share: config_constants::default_protocol_reserve_profit_share!(),
        trading_loss_rebate_rate: config_constants::default_trading_loss_rebate_rate!(),
    }
}

public(package) fun set_protocol_reserve_profit_share(
    config: &mut FeeConfig,
    protocol_reserve_profit_share: u64,
) {
    config_constants::assert_protocol_reserve_profit_share(protocol_reserve_profit_share);
    config.protocol_reserve_profit_share = protocol_reserve_profit_share;
}

public(package) fun set_trading_loss_rebate_rate(config: &mut FeeConfig, value: u64) {
    config_constants::assert_trading_loss_rebate_rate(value);
    config.trading_loss_rebate_rate = value;
}
