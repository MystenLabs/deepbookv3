// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Per-market exponentially-weighted gas-price statistics used to surcharge
/// trades placed during abnormal network congestion, mirroring DeepBook core's
/// gas-price EWMA penalty.
///
/// This module owns only the evolving `(mean, variance)` estimate and the
/// gas-price observation and penalty math. The tunable knobs (`alpha`,
/// `z_score_threshold`, `penalty_rate`, `enabled`) live in `EwmaConfig`;
/// `ExpiryMarket` owns the stored state and decides when to fold observations in.
module deepbook_predict::ewma;

use deepbook_predict::ewma_config::EwmaConfig;
use fixed_math::math;
use sui::clock::Clock;

/// Smoothed gas-price estimate for one expiry market. `mean` and `variance` are
/// scaled by `float_scaling`.
public struct EwmaState has copy, drop, store {
    mean: u64,
    variance: u64,
    /// On-chain time of the last fold; guards against more than one update per ms.
    last_updated_timestamp_ms: u64,
}

// === Public-Package Functions ===

/// Seed the estimate from the creating transaction's gas price, matching
/// DeepBook's per-pool initialization. Variance starts at zero, so no penalty
/// can fire until observations accumulate.
public(package) fun new(ctx: &TxContext): EwmaState {
    EwmaState {
        // Gas price must exceed 18_446_744_073 MIST to overflow scaling; realistic Sui gas is far lower, and the VM abort is the backstop.
        mean: ctx.gas_price() * math::float_scaling!(),
        variance: 0,
        last_updated_timestamp_ms: 0,
    }
}

/// Congestion penalty, in trade base units for `quantity`, to add on top of the
/// trading fee. Zero unless the penalty is enabled, variance has accumulated, and
/// the current gas price sits above the mean by more than `z_score_threshold`
/// standard deviations.
public(package) fun penalty_fee(
    self: &EwmaState,
    config: &EwmaConfig,
    quantity: u64,
    ctx: &TxContext,
): u64 {
    if (!config.enabled() || self.variance == 0) return 0;
    // Gas price must exceed 18_446_744_073 MIST to overflow scaling; realistic Sui gas is far lower, and the VM abort is the backstop.
    let gas_price = ctx.gas_price() * math::float_scaling!();
    if (gas_price <= self.mean) return 0;

    let std_dev = math::sqrt(self.variance, math::float_scaling!());
    let z_score = math::div(gas_price - self.mean, std_dev);
    if (z_score <= config.z_score_threshold()) return 0;

    math::mul(config.penalty_rate(), quantity)
}

/// Fold the current transaction's gas price into the smoothed mean and variance.
/// No-op when called more than once in the same millisecond.
///
/// mean'     = alpha * gas + (1 - alpha) * mean
/// variance' = (1 - alpha) * variance + alpha * (gas - mean)^2
///
/// The squared deviation is taken against the pre-update mean, and seeds the
/// variance directly on the first observation, matching DeepBook core.
public(package) fun update(
    self: &mut EwmaState,
    config: &EwmaConfig,
    clock: &Clock,
    ctx: &TxContext,
) {
    let now = clock.timestamp_ms();
    if (now == self.last_updated_timestamp_ms) return;
    self.last_updated_timestamp_ms = now;

    let alpha = config.alpha();
    let one_minus_alpha = math::float_scaling!() - alpha;
    // Gas price must exceed 18_446_744_073 MIST to overflow scaling; realistic Sui gas is far lower, and the VM abort is the backstop.
    let gas_price = ctx.gas_price() * math::float_scaling!();

    let mean_new = math::mul(alpha, gas_price) + math::mul(one_minus_alpha, self.mean);

    let diff = if (gas_price > self.mean) gas_price - self.mean else self.mean - gas_price;
    let diff_squared = math::mul(diff, diff);
    let variance_new = if (self.variance == 0) {
        diff_squared
    } else {
        math::mul(one_minus_alpha, self.variance) + math::mul(alpha, diff_squared)
    };

    self.mean = mean_new;
    self.variance = variance_new;
}
