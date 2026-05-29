// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// DEEP staking policy for Predict.
///
/// Pure functions mapping a manager's active staked DEEP to trading benefits.
/// Benefits scale linearly with active stake, reaching their admin-configured
/// maxima (`max_fee_discount`, `max_rebate_fraction`) at `max_benefit_power` and
/// staying capped above it (more stake earns no extra benefit). Active stake is
/// the epoch-activated portion tracked on the manager; this module is unaware of
/// the epoch lifecycle. All policy lives here so callers stay free of staking math.
module deepbook_predict::staking;

use deepbook::math;
use deepbook_predict::constants;

// === Public-Package Functions ===

/// Trading-fee discount for an active stake, in FLOAT_SCALING. Scales linearly
/// from 0 to `max_fee_discount` as active stake goes from 0 to
/// `max_benefit_power`, capped above it.
public(package) fun fee_discount_fraction(
    active_stake: u64,
    max_benefit_power: u64,
    max_fee_discount: u64,
): u64 {
    math::mul(benefit_ratio(active_stake, max_benefit_power), max_fee_discount)
}

/// Share of a manager's eligible trading-loss rebate paid out for an active
/// stake, in FLOAT_SCALING. Scales linearly from 0 to `max_rebate_fraction` as
/// active stake goes from 0 to `max_benefit_power`; the complement compounds to LPs.
public(package) fun rebate_fraction(
    active_stake: u64,
    max_benefit_power: u64,
    max_rebate_fraction: u64,
): u64 {
    math::mul(benefit_ratio(active_stake, max_benefit_power), max_rebate_fraction)
}

// === Private Functions ===

/// Fraction of the maximum benefit earned at an active stake, in FLOAT_SCALING
/// (0..1), linear in stake and capped at full benefit.
fun benefit_ratio(active_stake: u64, max_benefit_power: u64): u64 {
    math::div(active_stake, max_benefit_power).min(constants::float_scaling!())
}
