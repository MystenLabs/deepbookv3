// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Stored fee policy config.
///
/// PoolVault reads the current fee-share policy when compacting fee surplus.
module deepbook_predict::fee_config;

use deepbook_predict::{config_constants, constants};

const EInvalidFeeSplit: u64 = 0;

/// Fee surplus distribution policy.
public struct FeeConfig has store {
    /// LP fee share in FLOAT_SCALING; returned into pool idle liquidity.
    lp_fee_share: u64,
    /// Protocol revenue share in FLOAT_SCALING.
    protocol_fee_share: u64,
    /// Insurance fund share in FLOAT_SCALING.
    insurance_fee_share: u64,
}

// === Public-Package Functions ===

public(package) fun lp_fee_share(config: &FeeConfig): u64 {
    config.lp_fee_share
}

public(package) fun protocol_fee_share(config: &FeeConfig): u64 {
    config.protocol_fee_share
}

public(package) fun insurance_fee_share(config: &FeeConfig): u64 {
    config.insurance_fee_share
}

public(package) fun new(): FeeConfig {
    FeeConfig {
        lp_fee_share: config_constants::default_lp_fee_share!(),
        protocol_fee_share: config_constants::default_protocol_fee_share!(),
        insurance_fee_share: config_constants::default_insurance_fee_share!(),
    }
}

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
