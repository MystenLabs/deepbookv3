// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Admin-tunable DEEP staking parameters.
///
/// Benefits scale linearly with active stake up to `max_benefit_power` (stake
/// above it earns no extra), reaching `max_fee_discount` off trading fees and
/// `max_rebate_fraction` of the eligible loss rebate.
module deepbook_predict::stake_config;

use deepbook_predict::config_constants;

public struct StakeConfig has store {
    /// Active stake for full trading benefits, in raw DEEP units.
    max_benefit_power: u64,
    /// Fee discount at full active stake, in FLOAT_SCALING (0..50%).
    max_fee_discount: u64,
    /// Loss-rebate share at full active stake, in FLOAT_SCALING (0..100%).
    max_rebate_fraction: u64,
}

// === Public-Package Functions ===

public(package) fun max_benefit_power(config: &StakeConfig): u64 {
    config.max_benefit_power
}

public(package) fun max_fee_discount(config: &StakeConfig): u64 {
    config.max_fee_discount
}

public(package) fun max_rebate_fraction(config: &StakeConfig): u64 {
    config.max_rebate_fraction
}

public(package) fun new(): StakeConfig {
    StakeConfig {
        max_benefit_power: config_constants::default_max_benefit_power!(),
        max_fee_discount: config_constants::default_max_fee_discount!(),
        max_rebate_fraction: config_constants::default_max_rebate_fraction!(),
    }
}

public(package) fun set_max_benefit_power(config: &mut StakeConfig, value: u64) {
    config_constants::assert_max_benefit_power(value);
    config.max_benefit_power = value;
}

public(package) fun set_max_fee_discount(config: &mut StakeConfig, value: u64) {
    config_constants::assert_max_fee_discount(value);
    config.max_fee_discount = value;
}

public(package) fun set_max_rebate_fraction(config: &mut StakeConfig, value: u64) {
    config_constants::assert_max_rebate_fraction(value);
    config.max_rebate_fraction = value;
}
