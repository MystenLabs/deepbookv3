// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Admin-tunable DEEP staking parameters and the benefit curve they drive.
///
/// Benefits scale with active stake along a two-segment curve: the benefit ratio
/// rises linearly from 0 to half of max over `0..lower_benefit_power`, then from
/// half to full over `lower_benefit_power..upper_benefit_power`, capped at full
/// above. That ratio scales the fixed `constants::max_fee_discount` for fees.
module deepbook_predict::stake_config;

use deepbook_predict::{config_constants, constants};
use fixed_math::math;

public struct StakeConfig has store {
    /// Active stake at the curve kink (half of max benefits), in raw DEEP units.
    lower_benefit_power: u64,
    /// Active stake for full (max) benefits, in raw DEEP units.
    upper_benefit_power: u64,
}

// === Public-Package Functions ===

public(package) fun lower_benefit_power(config: &StakeConfig): u64 {
    config.lower_benefit_power
}

public(package) fun upper_benefit_power(config: &StakeConfig): u64 {
    config.upper_benefit_power
}

/// Fee amount remaining after the active stake discount is applied.
public(package) fun fee_amount_after_discount(
    config: &StakeConfig,
    amount: u64,
    active_stake: u64,
): u64 {
    let discount_fraction = math::mul(
        config.benefit_ratio(active_stake),
        constants::max_fee_discount!(),
    );
    amount - math::mul(amount, discount_fraction)
}

public(package) fun new(): StakeConfig {
    StakeConfig {
        lower_benefit_power: config_constants::default_lower_benefit_power!(),
        upper_benefit_power: config_constants::default_upper_benefit_power!(),
    }
}

/// Set both benefit thresholds together (validated as a pair: each in range and
/// `upper > 2 * lower`).
public(package) fun set_benefit_powers(config: &mut StakeConfig, lower: u64, upper: u64) {
    config_constants::assert_benefit_powers(lower, upper);
    config.lower_benefit_power = lower;
    config.upper_benefit_power = upper;
}

// === Private Functions ===

/// Fraction of the maximum benefit earned at an active stake, in FLOAT_SCALING
/// (0..1): linear 0 -> 0.5 over `0..lower`, linear 0.5 -> 1 over `lower..upper`,
/// capped at 1 above `upper`. Relies on the `upper > 2 * lower` invariant (so
/// `lower > 0` and `upper - lower > 0`).
fun benefit_ratio(config: &StakeConfig, active_stake: u64): u64 {
    let full = math::float_scaling!();
    if (active_stake >= config.upper_benefit_power) return full;
    let half = full / 2;
    if (active_stake <= config.lower_benefit_power) {
        let lower_fraction = math::div(active_stake, config.lower_benefit_power);
        math::mul(half, lower_fraction)
    } else {
        let upper_fraction = math::div(
            active_stake - config.lower_benefit_power,
            config.upper_benefit_power - config.lower_benefit_power,
        );
        half + math::mul(half, upper_fraction)
    }
}
