// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The Exponentially Weighted Moving Average (EWMA) state for Deepbook
/// This state is used to calculate the smoothed mean and variance of gas prices
/// and apply a penalty to taker fees based on the Z-score of the current gas price
/// relative to the smoothed mean and variance.
/// The state is enabled by default and can be configured with different parameters.
module deepbook::ewma;

use deepbook::{constants, math};

/// The EWMA state structure
/// It contains the smoothed mean, variance, alpha, Z-score threshold,
/// additional taker fee, and whether the state is enabled.
public struct EWMAState has copy, drop, store {
    mean: u64,
    variance: u64,
    alpha: u64,
    z_score_threshold: u64,
    additional_taker_fee: u64,
    enabled: bool,
}

public(package) fun init_ewma_state(ctx: &TxContext): EWMAState {
    let gas_price = ctx.gas_price();

    EWMAState {
        mean: gas_price,
        variance: 0,
        alpha: constants::default_ewma_alpha(),
        z_score_threshold: constants::default_z_score_threshold(),
        additional_taker_fee: constants::default_additional_taker_fee(),
        enabled: true,
    }
}

/// Updates the EWMA state with the current gas price
/// It calculates the new mean and variance based on the current gas price
/// and the previous mean and variance using the EWMA formula.
/// The alpha parameter controls the weight of the current gas price in the calculation.
/// The mean and variance are updated in the state.
public(package) fun update(self: &mut EWMAState, ctx: &TxContext) {
    let alpha = self.alpha;
    let one_minute_alpha = constants::float_scaling() - alpha;
    let gas_price = ctx.gas_price();

    let mean_new = math::div(
        alpha * gas_price + one_minute_alpha * self.mean,
        constants::float_scaling(),
    );
    let diff = if (gas_price > mean_new) {
        gas_price - mean_new
    } else {
        mean_new - gas_price
    };
    let diff_squared = math::mul(diff, diff);

    let variance_new = math::div(
        alpha * diff_squared + one_minute_alpha * self.variance,
        constants::float_scaling(),
    );
    self.mean = mean_new;
    self.variance = variance_new;
}

/// Returns the Z-score of the current gas price relative to the smoothed mean and variance.
/// The Z-score is calculated as the difference between the current gas price and the mean,
/// divided by the standard deviation (square root of variance).
public(package) fun z_score(self: &EWMAState, ctx: &TxContext): u64 {
    let gas_price = ctx.gas_price();
    let diff = if (gas_price > self.mean) {
        gas_price - self.mean
    } else {
        self.mean - gas_price
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
public(package) fun apply_taker_penalty(self: &EWMAState, taker_fee: u64, ctx: &TxContext): u64 {
    let z_score = self.z_score(ctx);
    if (!self.enabled) {
        return taker_fee
    };

    if (z_score > self.z_score_threshold) {
        taker_fee + self.additional_taker_fee
    } else {
        taker_fee
    }
}

/// Returns true if the EWMA state is enabled, false otherwise.
public(package) fun enabled(self: &EWMAState): bool {
    self.enabled
}
