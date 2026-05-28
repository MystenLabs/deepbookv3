// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// DEEP staking policy for Predict.
///
/// Pure functions that turn a manager's locked DEEP into staking power and map
/// that power to trading benefits. Power is computed live from the current
/// stake, the lock end, and now: `staked_DEEP * weight^2` where
/// `weight = min(remaining_lock / 2y, 1)`. It decays to 0 as the lock runs
/// out, and the period weight saturates at 1 for locks longer than two years.
/// Benefits scale linearly with power, reaching their maximum (50% fee
/// discount, 100% loss rebate) at the admin-configured `max_benefit_power` and
/// staying capped above it. All policy lives here so callers stay free of
/// staking math.
module deepbook_predict::staking;

use deepbook::math;
use deepbook_predict::constants;

// === Public-Package Functions ===

/// Live staking power for a stake of `staked_deep_raw` (raw DEEP units, 6
/// decimals) locked until `stake_end_ms`, evaluated at `now_ms`. Zero once the
/// lock has expired. The remaining-lock weight is squared, so longer locks earn
/// disproportionately more power, and saturates at 1 beyond a full year.
public(package) fun power(staked_deep_raw: u64, stake_end_ms: u64, now_ms: u64): u64 {
    if (now_ms >= stake_end_ms) return 0;
    let remaining_ms = stake_end_ms - now_ms;
    let weight = math::div(remaining_ms, constants::max_stake_period_ms!()).min(
        constants::float_scaling!(),
    );
    let weight_squared = math::mul(weight, weight);
    math::mul(staked_deep_raw, weight_squared)
}

/// Trading-fee discount for a power level, in FLOAT_SCALING (0..50%). Scales
/// linearly with power up to the admin-configured `max_benefit_power`.
public(package) fun fee_discount_fraction(power: u64, max_benefit_power: u64): u64 {
    math::mul(benefit_ratio(power, max_benefit_power), constants::max_fee_discount!())
}

/// Share of a manager's eligible trading-loss rebate that is paid out for a
/// power level, in FLOAT_SCALING (0..100%). Scales linearly with power up to the
/// admin-configured `max_benefit_power`; the complement compounds to LPs.
public(package) fun rebate_fraction(power: u64, max_benefit_power: u64): u64 {
    math::mul(benefit_ratio(power, max_benefit_power), constants::max_rebate_fraction!())
}

// === Private Functions ===

/// Fraction of the maximum benefit earned at a power level, in FLOAT_SCALING
/// (0..1), linear in power and capped at full benefit.
fun benefit_ratio(power: u64, max_benefit_power: u64): u64 {
    math::div(power, max_benefit_power).min(constants::float_scaling!())
}
