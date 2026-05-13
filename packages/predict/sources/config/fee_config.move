// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Stored fee split config snapshotted into each expiry fee reserve.
module deepbook_predict::fee_config;

use deepbook_predict::{config_constants, constants};

const EInvalidFeeSplit: u64 = 0;

/// Fee distribution shares. Shares must sum to 100%.
public struct FeeConfig has store {
    lp_fee_share: u64,
    protocol_fee_share: u64,
    insurance_fee_share: u64,
}

// === Public-Package Functions ===

/// Return the LP fee share.
public(package) fun lp_fee_share(config: &FeeConfig): u64 {
    config.lp_fee_share
}

/// Return the protocol fee share.
public(package) fun protocol_fee_share(config: &FeeConfig): u64 {
    config.protocol_fee_share
}

/// Return the insurance fee share.
public(package) fun insurance_fee_share(config: &FeeConfig): u64 {
    config.insurance_fee_share
}

/// Create fee config seeded from protocol defaults.
public(package) fun new(): FeeConfig {
    FeeConfig {
        lp_fee_share: config_constants::default_lp_fee_share!(),
        protocol_fee_share: config_constants::default_protocol_fee_share!(),
        insurance_fee_share: config_constants::default_insurance_fee_share!(),
    }
}

/// Set the fee distribution shares.
public(package) fun set_fee_shares(
    config: &mut FeeConfig,
    lp_fee_share: u64,
    protocol_fee_share: u64,
    insurance_fee_share: u64,
) {
    config_constants::assert_lp_fee_share(lp_fee_share);
    config_constants::assert_protocol_fee_share(protocol_fee_share);
    config_constants::assert_insurance_fee_share(insurance_fee_share);
    let total_share = lp_fee_share + protocol_fee_share + insurance_fee_share;
    assert!(total_share == constants::float_scaling!(), EInvalidFeeSplit);
    config.lp_fee_share = lp_fee_share;
    config.protocol_fee_share = protocol_fee_share;
    config.insurance_fee_share = insurance_fee_share;
}

// === Test-Only Functions ===

#[test_only]
public fun destroy_for_testing(config: FeeConfig) {
    let FeeConfig {
        lp_fee_share: _,
        protocol_fee_share: _,
        insurance_fee_share: _,
    } = config;
}
