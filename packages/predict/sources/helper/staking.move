// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// DEEP staking policy for Predict.
///
/// Pure functions mapping a manager's active staked DEEP to trading benefits
/// along a two-segment curve: the benefit ratio rises linearly from 0 to 50% of
/// max as active stake goes 0 -> `lower_benefit_power`, then linearly from 50%
/// to 100% as it goes `lower_benefit_power` -> `upper_benefit_power`, and is
/// capped at 100% above. The ratio then scales the admin-configured maxima
/// (`max_fee_discount`, `max_rebate_fraction`). Active stake is the
/// epoch-activated portion tracked on the manager; this module is unaware of the
/// epoch lifecycle. All policy lives here so callers stay free of staking math.
module deepbook_predict::staking;

use deepbook::math;
use deepbook_predict::constants;

// === Public-Package Functions ===

/// Trading-fee discount for an active stake, in FLOAT_SCALING. The two-segment
/// benefit ratio scaled by `max_fee_discount`.
public(package) fun fee_discount_fraction(
    active_stake: u64,
    lower_benefit_power: u64,
    upper_benefit_power: u64,
    max_fee_discount: u64,
): u64 {
    math::mul(
        benefit_ratio(active_stake, lower_benefit_power, upper_benefit_power),
        max_fee_discount,
    )
}

/// Share of a manager's eligible trading-loss rebate for an active stake, in
/// FLOAT_SCALING. The two-segment benefit ratio scaled by `max_rebate_fraction`;
/// the complement compounds to LPs.
public(package) fun rebate_fraction(
    active_stake: u64,
    lower_benefit_power: u64,
    upper_benefit_power: u64,
    max_rebate_fraction: u64,
): u64 {
    math::mul(
        benefit_ratio(active_stake, lower_benefit_power, upper_benefit_power),
        max_rebate_fraction,
    )
}

// === Private Functions ===

/// Fraction of the maximum benefit earned at an active stake, in FLOAT_SCALING
/// (0..1): linear 0 -> 0.5 over `0..lower`, linear 0.5 -> 1 over `lower..upper`,
/// capped at 1 above `upper`. Relies on the config invariant `upper > 2 * lower`
/// (so `lower > 0` and `upper - lower > 0`).
fun benefit_ratio(active_stake: u64, lower: u64, upper: u64): u64 {
    let full = constants::float_scaling!();
    if (active_stake >= upper) return full;
    let half = full / 2;
    if (active_stake <= lower) {
        math::mul(half, math::div(active_stake, lower))
    } else {
        half + math::mul(half, math::div(active_stake - lower, upper - lower))
    }
}
