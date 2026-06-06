// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Scratch strike-exposure config shape for enumerating floor, LTV, and fee policy.
module deepbook_predict::strike_exposure_cofig_rewrite;

use deepbook::math;
use deepbook_predict::{constants, math as predict_math};

const EAskPriceOutOfBounds: u64 = 2;
const EInvalidFeeProbability: u64 = 4;

/// Expiry-local exposure and fee policy in Predict's 1e9 fixed-point scale.
#[allow(unused_field)]
public struct StrikeExposureConfig has store {
    /// Maximum terminal increase in the contract floor index over one expiry.
    /// `200_000_000` means the floor index rises from 1.00 to 1.20.
    max_expiry_floor_premium: u64,
    /// 1e9-scaled floor-to-live-value threshold for liquidation.
    /// `850_000_000` means liquidate at 85% LTV.
    liquidation_ltv: u64,
    /// Base fee multiplier for Bernoulli scaling.
    base_fee: u64,
    /// Minimum per-unit fee floor.
    min_fee: u64,
    /// Minimum allowed all-in mint price after adding the fee.
    min_ask_price: u64,
    /// Maximum allowed all-in mint price after adding the fee.
    max_ask_price: u64,
    /// Window before expiry over which trade fees ramp up.
    expiry_fee_window_ms: u64,
    /// Fee multiplier reached at expiry, in FLOAT_SCALING; 1x disables the ramp.
    expiry_fee_max_multiplier: u64,
}

public(package) fun max_expiry_floor_premium(config: &StrikeExposureConfig): u64 {
    config.max_expiry_floor_premium
}

public(package) fun liquidation_ltv(config: &StrikeExposureConfig): u64 {
    config.liquidation_ltv
}

public(package) fun expiry_fee_window_ms(config: &StrikeExposureConfig): u64 {
    config.expiry_fee_window_ms
}

public(package) fun expiry_fee_max_multiplier(config: &StrikeExposureConfig): u64 {
    config.expiry_fee_max_multiplier
}

public(package) fun floor_index_at_ms(
    config: &StrikeExposureConfig,
    expiry_ms: u64,
    timestamp_ms: u64,
): u64 {
    let window = constants::leverage_floor_window_ms!();
    let remaining = if (timestamp_ms >= expiry_ms) {
        0
    } else {
        expiry_ms - timestamp_ms
    };
    let elapsed = if (remaining >= window) {
        0
    } else {
        window - remaining
    };
    let phase = predict_math::mul_div_round_down(elapsed, constants::float_scaling!(), window);
    let phase_squared = predict_math::mul_div_round_down(
        phase,
        phase,
        constants::float_scaling!(),
    );
    let floor_premium = predict_math::mul_div_round_down(
        config.max_expiry_floor_premium,
        phase_squared,
        constants::float_scaling!(),
    );
    constants::float_scaling!() + floor_premium
}

public(package) fun trading_fee(
    config: &StrikeExposureConfig,
    expiry_ms: u64,
    probability: u64,
    quantity: u64,
    timestamp_ms: u64,
): u64 {
    math::mul(config.fee_rate(expiry_ms, probability, timestamp_ms), quantity)
}

public(package) fun mint_trading_fee(
    config: &StrikeExposureConfig,
    expiry_ms: u64,
    probability: u64,
    quantity: u64,
    timestamp_ms: u64,
): u64 {
    let fee_rate = config.fee_rate(expiry_ms, probability, timestamp_ms);
    let ask_price = probability + fee_rate;
    assert!(
        ask_price >= config.min_ask_price && ask_price <= config.max_ask_price,
        EAskPriceOutOfBounds,
    );
    math::mul(fee_rate, quantity)
}

fun fee_rate(
    config: &StrikeExposureConfig,
    expiry_ms: u64,
    probability: u64,
    timestamp_ms: u64,
): u64 {
    let raw_fee = config.raw_bernoulli_fee_rate(probability);
    let base = if (raw_fee > config.min_fee) raw_fee else config.min_fee;
    let multiplier = config.expiry_fee_multiplier(expiry_ms - timestamp_ms);
    math::mul(base, multiplier)
}

fun raw_bernoulli_fee_rate(config: &StrikeExposureConfig, probability: u64): u64 {
    assert!(probability <= constants::float_scaling!(), EInvalidFeeProbability);
    if (probability == 0 || probability == constants::float_scaling!()) return 0;

    let complement = constants::float_scaling!() - probability;
    let variance = math::mul(probability, complement);
    let bernoulli_factor = predict_math::sqrt(variance, constants::float_scaling!());
    math::mul(config.base_fee, bernoulli_factor)
}

fun expiry_fee_multiplier(config: &StrikeExposureConfig, time_to_expiry_ms: u64): u64 {
    if (time_to_expiry_ms >= config.expiry_fee_window_ms) return constants::float_scaling!();

    let ramp = predict_math::mul_div_round_down(
        config.expiry_fee_max_multiplier - constants::float_scaling!(),
        config.expiry_fee_window_ms - time_to_expiry_ms,
        config.expiry_fee_window_ms,
    );
    constants::float_scaling!() + ramp
}
