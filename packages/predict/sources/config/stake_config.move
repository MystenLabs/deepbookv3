// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Admin-tunable DEEP staking parameters.
///
/// Benefits scale with active stake along a two-segment curve: linearly from 0
/// to half of max over `0..lower_benefit_power`, then linearly from half to full
/// over `lower_benefit_power..upper_benefit_power`, capped at full above. "Full"
/// means `max_fee_discount` off trading fees and `max_rebate_fraction` of the
/// eligible loss rebate.
module deepbook_predict::stake_config;

use deepbook_predict::config_constants;

public struct StakeConfig has store {
    /// Active stake at the curve kink (half of max benefits), in raw DEEP units.
    lower_benefit_power: u64,
    /// Active stake for full (max) benefits, in raw DEEP units.
    upper_benefit_power: u64,
    /// Fee discount at full active stake, in FLOAT_SCALING (0..50%).
    max_fee_discount: u64,
    /// Loss-rebate share at full active stake, in FLOAT_SCALING (0..100%).
    max_rebate_fraction: u64,
}

// === Public-Package Functions ===

public(package) fun lower_benefit_power(config: &StakeConfig): u64 {
    config.lower_benefit_power
}

public(package) fun upper_benefit_power(config: &StakeConfig): u64 {
    config.upper_benefit_power
}

public(package) fun max_fee_discount(config: &StakeConfig): u64 {
    config.max_fee_discount
}

public(package) fun max_rebate_fraction(config: &StakeConfig): u64 {
    config.max_rebate_fraction
}

public(package) fun new(): StakeConfig {
    StakeConfig {
        lower_benefit_power: config_constants::default_lower_benefit_power!(),
        upper_benefit_power: config_constants::default_upper_benefit_power!(),
        max_fee_discount: config_constants::default_max_fee_discount!(),
        max_rebate_fraction: config_constants::default_max_rebate_fraction!(),
    }
}

/// Set both benefit thresholds together (validated as a pair: each in range and
/// `upper > 2 * lower`).
public(package) fun set_benefit_powers(config: &mut StakeConfig, lower: u64, upper: u64) {
    config_constants::assert_benefit_powers(lower, upper);
    config.lower_benefit_power = lower;
    config.upper_benefit_power = upper;
}

public(package) fun set_max_fee_discount(config: &mut StakeConfig, value: u64) {
    config_constants::assert_max_fee_discount(value);
    config.max_fee_discount = value;
}

public(package) fun set_max_rebate_fraction(config: &mut StakeConfig, value: u64) {
    config_constants::assert_max_rebate_fraction(value);
    config.max_rebate_fraction = value;
}
