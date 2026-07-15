// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Admin-tunable DEEP staking parameters and the benefit curve they drive.
///
/// Benefits scale with active stake along a two-segment curve: the benefit ratio
/// rises linearly from 0 to half of max over `0..lower_benefit_power`, then from
/// half to full over `lower_benefit_power..upper_benefit_power`, capped at full
/// above. That ratio scales the fixed `constants::max_fee_discount` for fees.
/// The same benefit ratio scales settled trading-loss rebates.
module deepbook_predict::stake_config;

use deepbook_predict::{config_constants, constants};
use fixed_math::math;

const EInvalidBenefitPowers: u64 = 0;

/// Admin-tunable DEEP-stake benefit curve thresholds; see the module doc for
/// the curve shape.
public struct StakeConfig has store {
    /// Active stake at the curve kink (half of max benefits), in raw DEEP units.
    lower_benefit_power: u64,
    /// Active stake for full (max) benefits, in raw DEEP units.
    upper_benefit_power: u64,
}

// === Public-Package Functions ===

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

/// Trading-loss rebate amount paid for an active stake.
public(package) fun rebate_amount(
    config: &StakeConfig,
    eligible_rebate: u64,
    active_stake: u64,
): u64 {
    math::mul(eligible_rebate, config.benefit_ratio(active_stake))
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
    config_constants::assert_lower_benefit_power(lower);
    config_constants::assert_upper_benefit_power(upper);
    // The upper segment must require strictly more stake than the lower one:
    // `upper - lower > lower`, i.e. `upper > 2 * lower` (which also guarantees
    // `upper > lower`, so `benefit_ratio`'s `upper - lower` denominator is positive).
    assert!(upper > 2 * lower, EInvalidBenefitPowers);
    config.lower_benefit_power = lower;
    config.upper_benefit_power = upper;
}

// === Private Functions ===

/// Fraction of the maximum benefit earned at an active stake, in FLOAT_SCALING
/// (0..1): linear 0 -> 0.5 over `0..lower`, linear 0.5 -> 1 over `lower..upper`,
/// capped at 1 above `upper`. Relies on `lower >= min_lower_benefit_power!() > 0`
/// (config bound) and the `upper > 2 * lower` pair invariant (so `upper - lower > 0`).
fun benefit_ratio(config: &StakeConfig, active_stake: u64): u64 {
    let full = math::float_scaling!();
    if (active_stake >= config.upper_benefit_power) return full;
    let half = full / 2;
    // Each segment is half * progress / span, round down; the earned benefit
    // never exceeds the true line.
    if (active_stake <= config.lower_benefit_power) {
        math::mul_div_down(half, active_stake, config.lower_benefit_power)
    } else {
        half + math::mul_div_down(
            half,
            active_stake - config.lower_benefit_power,
            config.upper_benefit_power - config.lower_benefit_power,
        )
    }
}
