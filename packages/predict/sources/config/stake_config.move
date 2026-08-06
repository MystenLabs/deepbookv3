// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Admin-tunable DEEP staking parameters and the benefit curve they drive.
///
/// Benefits scale with active stake along a two-segment curve: the benefit ratio
/// rises linearly from 0 to half of max over `0..lower_benefit_power`, then from
/// half to full over `lower_benefit_power..upper_benefit_power`, capped at full
/// above. That ratio scales the fixed `constants::max_fee_discount` for fees.
/// The same benefit ratio scales settled trading-loss rebates.
///
/// Whether the programme applies at all is NOT decided here: every entry takes a
/// `benefits_enabled` flag that each `ExpiryMarket` snapshots at creation from
/// `template_benefits_enabled`. This module owns the curve; the market owns
/// whether its contracts were written under the programme. The thresholds stay
/// live, so retuning the curve still reaches markets already trading.
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
    /// Seed for the per-market benefit switch, snapshotted by each new
    /// `ExpiryMarket`. Ships false. Changing it never reaches an existing market:
    /// a market's contracts keep the programme state they were written under, so
    /// no toggle can retroactively zero a rebate already earned.
    template_benefits_enabled: bool,
}

// === Public-Package Functions ===

/// Fee remaining after the active-stake discount, with the discount rounded down.
/// `benefits_enabled` is the trading market's snapshot, not the current template.
public(package) fun fee_amount_after_discount(
    config: &StakeConfig,
    amount: u64,
    active_stake: u64,
    benefits_enabled: bool,
): u64 {
    let discount_fraction = math::mul_down(
        config.benefit_ratio(active_stake, benefits_enabled),
        constants::max_fee_discount!(),
    );
    amount - math::mul_down(amount, discount_fraction)
}

/// Trading-loss rebate earned for an active stake, rounded down.
/// `benefits_enabled` is the settling market's snapshot, not the current template.
public(package) fun rebate_amount(
    config: &StakeConfig,
    eligible_rebate: u64,
    active_stake: u64,
    benefits_enabled: bool,
): u64 {
    math::mul_down(eligible_rebate, config.benefit_ratio(active_stake, benefits_enabled))
}

public(package) fun template_benefits_enabled(config: &StakeConfig): bool {
    config.template_benefits_enabled
}

public(package) fun new(): StakeConfig {
    StakeConfig {
        lower_benefit_power: config_constants::default_lower_benefit_power!(),
        upper_benefit_power: config_constants::default_upper_benefit_power!(),
        template_benefits_enabled: config_constants::default_stake_benefits_enabled!(),
    }
}

/// Set the benefit-switch seed for markets created from here on. Existing markets
/// keep the value they snapshotted.
public(package) fun set_template_benefits_enabled(config: &mut StakeConfig, enabled: bool) {
    config.template_benefits_enabled = enabled;
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

/// Fraction of the maximum benefit earned at an active stake, in FLOAT_SCALING.
/// Zero for a market that did not snapshot the programme, whatever the stake. Each
/// segment rounds down, so the returned benefit never exceeds the curve.
fun benefit_ratio(config: &StakeConfig, active_stake: u64, benefits_enabled: bool): u64 {
    if (!benefits_enabled) return 0;
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
