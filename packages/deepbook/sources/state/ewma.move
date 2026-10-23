// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The Exponentially Weighted Moving Average (EWMA) state for DeepBook
/// This state is used to calculate the smoothed mean and variance of gas prices
/// and apply a penalty to taker fees based on the Z-score of the current gas price
/// relative to the smoothed mean and variance.
/// The state is disabled by default and can be configured with different parameters.
/// Gas prices above `constants::max_ewma_gas_price` are treated as that value.
module deepbook::ewma;

use deepbook::{constants, math};
use sui::{clock::Clock, event};

/// The EWMA state structure
/// It contains the smoothed mean, variance, alpha, Z-score threshold,
/// additional taker fee, and whether the state is enabled.
public struct EWMAState has copy, drop, store {
    mean: u64,
    variance: u64,
    alpha: u64,
    z_score_threshold: u64,
    additional_taker_fee: u64,
    last_updated_timestamp: u64,
    enabled: bool,
}

public struct EWMAUpdate has copy, drop, store {
    pool_id: ID,
    gas_price: u64,
    mean: u64,
    variance: u64,
    timestamp: u64,
}

public(package) fun init_ewma_state(ctx: &TxContext): EWMAState {
    let gas_price = capped_gas_price(ctx);

    EWMAState {
        mean: gas_price,
        variance: 0,
        alpha: constants::default_ewma_alpha(),
        z_score_threshold: constants::default_z_score_threshold(),
        additional_taker_fee: constants::default_additional_taker_fee(),
        last_updated_timestamp: 0,
        enabled: false,
    }
}

/// Updates the EWMA state with the current gas price
/// It calculates the new mean and variance based on the current gas price
/// and the previous mean and variance using the EWMA formula.
/// The alpha parameter controls the weight of the current gas price in the calculation.
/// The mean and variance are updated in the state.
public(package) fun update(self: &mut EWMAState, pool_id: ID, clock: &Clock, ctx: &TxContext) {
    let current_timestamp = clock.timestamp_ms();
    if (current_timestamp == self.last_updated_timestamp) {
        return
    };
    self.last_updated_timestamp = current_timestamp;

    let alpha = self.alpha;
    let one_minute_alpha = constants::float_scaling() - alpha;
    let gas_price = capped_gas_price(ctx);
    let mean = self.capped_mean();

    let mean_new = math::mul(alpha, gas_price) + math::mul(one_minute_alpha, mean);

    let diff = if (gas_price > mean) {
        gas_price - mean
    } else {
        mean - gas_price
    };
    let diff_squared = math::mul(diff, diff);

    let variance_new = if (self.variance == 0) {
        diff_squared
    } else {
        math::mul(self.variance, one_minute_alpha) + math::mul(alpha, diff_squared)
    };

    self.mean = mean_new;
    self.variance = variance_new;

    event::emit(EWMAUpdate {
        pool_id,
        gas_price,
        mean: self.mean,
        variance: self.variance,
        timestamp: current_timestamp,
    });
}

/// Returns the Z-score of the current gas price relative to the smoothed mean and variance.
/// The Z-score is calculated as the difference between the current gas price and the mean,
/// divided by the standard deviation (square root of variance).
public(package) fun z_score(self: &EWMAState, ctx: &TxContext): u64 {
    if (self.variance == 0) {
        return 0
    };

    let gas_price = capped_gas_price(ctx);
    let mean = self.capped_mean();
    let diff = if (gas_price > mean) {
        gas_price - mean
    } else {
        mean - gas_price
    };

    let std_dev = math::sqrt(self.variance, constants::float_scaling());
    let z = math::div(diff, std_dev);

    z
}

/// Sets the alpha value for the EWMA state. Admin only.
public(package) fun set_alpha(self: &mut EWMAState, alpha: u64) {
    self.alpha = alpha;
}

/// Sets the Z-score threshold for the EWMA state. Admin only.
public(package) fun set_z_score_threshold(self: &mut EWMAState, threshold: u64) {
    self.z_score_threshold = threshold;
}

/// Sets the additional taker fee for the EWMA state. Admin only.
public(package) fun set_additional_taker_fee(self: &mut EWMAState, fee: u64) {
    self.additional_taker_fee = fee;
}

/// Enables the EWMA state. Admin only.
public(package) fun enable(self: &mut EWMAState) {
    self.enabled = true;
}

/// Disables the EWMA state. Admin only.
public(package) fun disable(self: &mut EWMAState) {
    self.enabled = false;
}

/// Applies the taker penalty based on the Z-score of the current gas price.
/// If the gas price is below the mean, the taker fee is not applied.
public(package) fun apply_taker_penalty(self: &EWMAState, taker_fee: u64, ctx: &TxContext): u64 {
    let gas_price = capped_gas_price(ctx);
    if (!self.enabled || gas_price < self.capped_mean()) {
        return taker_fee
    };

    let z_score = self.z_score(ctx);
    if (z_score > self.z_score_threshold) {
        taker_fee + self.additional_taker_fee
    } else {
        taker_fee
    }
}

public(package) fun mean(self: &EWMAState): u64 {
    self.mean
}

public(package) fun variance(self: &EWMAState): u64 {
    self.variance
}

public(package) fun alpha(self: &EWMAState): u64 {
    self.alpha
}

public(package) fun z_score_threshold(self: &EWMAState): u64 {
    self.z_score_threshold
}

public(package) fun additional_taker_fee(self: &EWMAState): u64 {
    self.additional_taker_fee
}

public(package) fun enabled(self: &EWMAState): bool {
    self.enabled
}

public(package) fun last_updated_timestamp(self: &EWMAState): u64 {
    self.last_updated_timestamp
}

/// The transaction's gas price, capped at `max_ewma_gas_price` and scaled by `float_scaling`.
/// With the gas price and the `capped_mean` both at most 1e14 once scaled, `math::mul(diff, diff)` in
/// `update` stays at most 1e19, inside u64 (an uncapped distance overflows above ~135_818
/// MIST), and the scaled gas price itself cannot overflow.
fun capped_gas_price(ctx: &TxContext): u64 {
    ctx.gas_price().min(constants::max_ewma_gas_price()) * constants::float_scaling()
}

/// The stored mean, capped like the gas price. A mean recorded before the cap existed
/// can sit above it.
fun capped_mean(self: &EWMAState): u64 {
    self.mean.min(constants::max_ewma_gas_price() * constants::float_scaling())
}

#[test_only]
public fun set_mean_for_testing(self: &mut EWMAState, mean: u64) {
    self.mean = mean;
}

#[test_only]
public fun set_variance_for_testing(self: &mut EWMAState, variance: u64) {
    self.variance = variance;
}
