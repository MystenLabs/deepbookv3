// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// DEEP staking policy for Predict.
///
/// Pure functions that turn a manager's locked DEEP into staking power and map
/// that power to trading benefits. Power is computed live from the current
/// stake, the lock end, and now: `staked_DEEP * weight^2` where
/// `weight = min(remaining_lock / 365d, 1)`. It decays to 0 as the lock runs
/// out, and the period weight saturates at 1 for locks longer than a year.
/// Power is bucketed into 10k-DEEP tiers (`stake_tier_step`); each tier grants
/// +5% off trading fees (capped at 50% / 10 tiers) and +10% of the eligible
/// trading-loss rebate (capped at 100%). Power above the top tier is allowed
/// but earns no extra benefit. All policy lives here so callers stay free of
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
    let weight = math::div(remaining_ms, constants::ms_per_year!()).min(
        constants::float_scaling!(),
    );
    let weight_squared = math::mul(weight, weight);
    math::mul(staked_deep_raw, weight_squared)
}

/// Trading-fee discount for a power level, in FLOAT_SCALING (0..50%).
public(package) fun fee_discount_fraction(power: u64): u64 {
    tier(power) * constants::fee_discount_per_tier!()
}

/// Share of a manager's eligible trading-loss rebate that is paid out for a
/// power level, in FLOAT_SCALING (0..100%). The complement compounds to LPs.
public(package) fun rebate_fraction(power: u64): u64 {
    tier(power) * constants::rebate_per_tier!()
}

// === Private Functions ===

/// Whole staking tiers for a power level, capped at `max_stake_tiers`.
fun tier(power: u64): u64 {
    (power / constants::stake_tier_step!()).min(constants::max_stake_tiers!())
}
