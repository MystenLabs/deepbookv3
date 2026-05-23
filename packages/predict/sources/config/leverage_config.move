// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Stored leverage template for future expiry markets.
///
/// Protocol config stores the admin-tunable terminal borrow fee used by future
/// expiry markets. Each market snapshots that value at creation so later admin
/// updates do not reprice active markets.
module deepbook_predict::leverage_config;

use deepbook_predict::config_constants;

/// Leverage parameters expressed in Predict's 1e9 fixed-point price scaling.
public struct LeverageConfig has store {
    /// Maximum total time-only borrow premium over one expiry.
    /// `200_000_000` means the borrow index rises from 1.00 to 1.20.
    max_expiry_borrow_fee: u64,
}

// === Public-Package Functions ===

public(package) fun max_expiry_borrow_fee(config: &LeverageConfig): u64 {
    config.max_expiry_borrow_fee
}

public(package) fun new(): LeverageConfig {
    LeverageConfig {
        max_expiry_borrow_fee: config_constants::default_max_expiry_borrow_fee!(),
    }
}

public(package) fun set_template_max_expiry_borrow_fee(config: &mut LeverageConfig, value: u64) {
    config_constants::assert_max_expiry_borrow_fee(value);
    config.max_expiry_borrow_fee = value;
}
