// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Stored expiry-cash policy config.
///
/// ProtocolConfig owns the current global template. Each ExpiryCash stores a
/// snapshot initialized from that template, so later admin updates do not change
/// active expiry rebate-reserve accounting.
module deepbook_predict::expiry_cash_config;

use deepbook_predict::config_constants;
use fixed_math::math;

/// Rebate reserve policy expressed in Predict's 1e9 fixed-point scaling.
public struct ExpiryCashConfig has store {
    /// Fraction of aggregate expiry trading fees reserved for loss rebates.
    trading_loss_rebate_rate: u64,
}

// === Public-Package Functions ===

public(package) fun trading_loss_rebate_rate(config: &ExpiryCashConfig): u64 {
    config.trading_loss_rebate_rate
}

/// Return the 1e9-scaled trading-fee carve-out reserved for loss rebates.
public(package) fun rebate_reserve_for_fee_basis(
    config: &ExpiryCashConfig,
    trading_fees_paid: u64,
): u64 {
    math::mul(trading_fees_paid, config.trading_loss_rebate_rate)
}

public(package) fun new(): ExpiryCashConfig {
    ExpiryCashConfig {
        trading_loss_rebate_rate: config_constants::default_trading_loss_rebate_rate!(),
    }
}

/// Snapshot an expiry-cash config into an independent live copy.
public(package) fun snapshot(config: &ExpiryCashConfig): ExpiryCashConfig {
    ExpiryCashConfig {
        trading_loss_rebate_rate: config.trading_loss_rebate_rate,
    }
}

public(package) fun set_trading_loss_rebate_rate(config: &mut ExpiryCashConfig, value: u64) {
    config_constants::assert_trading_loss_rebate_rate(value);
    config.trading_loss_rebate_rate = value;
}
