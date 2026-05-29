// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Admin-tunable DEEP staking parameters and the benefit curve they drive.
///
/// Benefits scale with active stake along a two-segment curve: the benefit ratio
/// rises linearly from 0 to half of max over `0..lower_benefit_power`, then from
/// half to full over `lower_benefit_power..upper_benefit_power`, capped at full
/// above. That ratio scales `max_fee_discount` (fee discount) and
/// `max_rebate_fraction` (loss-rebate share).
module deepbook_predict::stake_config;

use deepbook::math;
use deepbook_predict::{config_constants, constants};

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

/// Trading-fee discount for an active stake, in FLOAT_SCALING: the two-segment
/// benefit ratio scaled by `max_fee_discount`.
public(package) fun fee_discount_fraction(config: &StakeConfig, active_stake: u64): u64 {
    math::mul(config.benefit_ratio(active_stake), config.max_fee_discount)
}

/// Share of a manager's eligible trading-loss rebate for an active stake, in
/// FLOAT_SCALING: the two-segment benefit ratio scaled by `max_rebate_fraction`;
/// the complement compounds to LPs.
public(package) fun rebate_fraction(config: &StakeConfig, active_stake: u64): u64 {
    math::mul(config.benefit_ratio(active_stake), config.max_rebate_fraction)
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

// === Private Functions ===

/// Fraction of the maximum benefit earned at an active stake, in FLOAT_SCALING
/// (0..1): linear 0 -> 0.5 over `0..lower`, linear 0.5 -> 1 over `lower..upper`,
/// capped at 1 above `upper`. Relies on the `upper > 2 * lower` invariant (so
/// `lower > 0` and `upper - lower > 0`).
fun benefit_ratio(config: &StakeConfig, active_stake: u64): u64 {
    let full = constants::float_scaling!();
    if (active_stake >= config.upper_benefit_power) return full;
    let half = full / 2;
    if (active_stake <= config.lower_benefit_power) {
        math::mul(half, math::div(active_stake, config.lower_benefit_power))
    } else {
        half + math::mul(
            half,
            math::div(
                active_stake - config.lower_benefit_power,
                config.upper_benefit_power - config.lower_benefit_power,
            ),
        )
    }
}
