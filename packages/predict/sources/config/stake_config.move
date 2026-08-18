// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// DEEP staking benefit policy: the stake curve and how much of it pays out.
///
/// The settled trading-loss rebate scales with active stake along a two-segment
/// curve: the curve rises linearly from 0 to half of max over
/// `0..lower_benefit_power`, then from half to full over
/// `lower_benefit_power..upper_benefit_power`, capped at full above.
/// `max_benefit_ratio` then scales that curve, so it sets how much of the
/// programme runs — `0` pays nothing at any stake, `float_scaling` runs it at full
/// strength. The resulting benefit ratio applies directly to the rebate.
///
/// Each `ExpiryMarket` snapshots this whole config at creation and prices the
/// rebate against its own copy; the one on `ProtocolConfig` is only the template
/// future markets will snapshot. Nothing here is read live, because the rebate
/// resolves after the trade that earned it — at a post-settlement claim — so a
/// live value would let an admin shrink a rebate already earned.
module deepbook_predict::stake_config;

use deepbook_predict::config_constants;
use fixed_math::math;

const EInvalidBenefitPowers: u64 = 0;

/// Admin-tunable DEEP-stake benefit policy; see the module doc for the curve.
public struct StakeConfig has store {
    /// Active stake at the curve kink (half of max benefits), in raw DEEP units.
    lower_benefit_power: u64,
    /// Active stake for full (max) benefits, in raw DEEP units.
    upper_benefit_power: u64,
    /// Ceiling on the benefit ratio, in FLOAT_SCALING. Scales the whole curve, so
    /// `0` pays no rebate at any stake and `float_scaling` runs the programme at
    /// full strength. Ships at 0.
    max_benefit_ratio: u64,
}

// === Public-Package Functions ===

/// Trading-loss rebate earned for an active stake, rounded down.
public(package) fun rebate_amount(
    config: &StakeConfig,
    eligible_rebate: u64,
    active_stake: u64,
): u64 {
    math::mul_down(eligible_rebate, config.benefit_ratio(active_stake))
}

/// Copy the template into a new market's own immutable benefit policy.
public(package) fun snapshot(config: &StakeConfig): StakeConfig {
    StakeConfig {
        lower_benefit_power: config.lower_benefit_power,
        upper_benefit_power: config.upper_benefit_power,
        max_benefit_ratio: config.max_benefit_ratio,
    }
}

public(package) fun max_benefit_ratio(config: &StakeConfig): u64 {
    config.max_benefit_ratio
}

public(package) fun lower_benefit_power(config: &StakeConfig): u64 {
    config.lower_benefit_power
}

public(package) fun upper_benefit_power(config: &StakeConfig): u64 {
    config.upper_benefit_power
}

public(package) fun new(): StakeConfig {
    StakeConfig {
        lower_benefit_power: config_constants::default_lower_benefit_power!(),
        upper_benefit_power: config_constants::default_upper_benefit_power!(),
        max_benefit_ratio: config_constants::default_max_benefit_ratio!(),
    }
}

/// Set how much of the benefit programme pays out, from `0` (nothing) to
/// `float_scaling` (full strength).
public(package) fun set_max_benefit_ratio(config: &mut StakeConfig, value: u64) {
    config_constants::assert_max_benefit_ratio(value);
    config.max_benefit_ratio = value;
}

/// Set both benefit thresholds together (validated as a pair: each in range and
/// `upper > 2 * lower`).
public(package) fun set_benefit_powers(config: &mut StakeConfig, lower: u64, upper: u64) {
    config_constants::assert_lower_benefit_power(lower);
    config_constants::assert_upper_benefit_power(upper);
    // The pair invariant also keeps the upper-segment denominator positive.
    assert!(upper > 2 * lower, EInvalidBenefitPowers);
    config.lower_benefit_power = lower;
    config.upper_benefit_power = upper;
}

// === Private Functions ===

/// Fraction of the maximum benefit earned at an active stake, in FLOAT_SCALING:
/// the two-segment stake curve scaled by `max_benefit_ratio`. Zero at any stake
/// while that ratio is zero. Each step rounds down, so the returned benefit never
/// exceeds the curve.
fun benefit_ratio(config: &StakeConfig, active_stake: u64): u64 {
    math::mul_down(config.stake_curve(active_stake), config.max_benefit_ratio)
}

/// Position on the two-segment stake curve, in FLOAT_SCALING, before the
/// `max_benefit_ratio` scaling is applied.
fun stake_curve(config: &StakeConfig, active_stake: u64): u64 {
    let full = math::float_scaling!();
    if (active_stake >= config.upper_benefit_power) return full;
    let half = full / 2;
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
