// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// DEEP staking policy for Predict.
///
/// Pure functions mapping a manager's active staked DEEP to trading benefits.
/// Benefits scale linearly with active stake, reaching their maximum (50% fee
/// discount, 100% loss rebate) at the admin-configured `max_benefit_power` and
/// staying capped above it (more stake earns no extra benefit). Active stake is
/// the epoch-activated portion tracked on the manager; this module is unaware of
/// the epoch lifecycle. All policy lives here so callers stay free of staking math.
module deepbook_predict::staking;

use deepbook::math;
use deepbook_predict::constants;

// === Public-Package Functions ===

/// Trading-fee discount for an active stake, in FLOAT_SCALING (0..50%). Scales
/// linearly up to the admin-configured `max_benefit_power`, capped above it.
public(package) fun fee_discount_fraction(active_stake: u64, max_benefit_power: u64): u64 {
    math::mul(benefit_ratio(active_stake, max_benefit_power), constants::max_fee_discount!())
}

/// Share of a manager's eligible trading-loss rebate that is paid out for an
/// active stake, in FLOAT_SCALING (0..100%). Scales linearly up to the
/// admin-configured `max_benefit_power`; the complement compounds to LPs.
public(package) fun rebate_fraction(active_stake: u64, max_benefit_power: u64): u64 {
    math::mul(benefit_ratio(active_stake, max_benefit_power), constants::max_rebate_fraction!())
}

// === Private Functions ===

/// Fraction of the maximum benefit earned at an active stake, in FLOAT_SCALING
/// (0..1), linear in stake and capped at full benefit.
fun benefit_ratio(active_stake: u64, max_benefit_power: u64): u64 {
    math::div(active_stake, max_benefit_power).min(constants::float_scaling!())
}
