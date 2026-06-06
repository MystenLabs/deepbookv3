// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Scratch strike-exposure config shape for enumerating floor and LTV policy.
module deepbook_predict::strike_exposure_cofig_rewrite;

use deepbook_predict::{constants, math as predict_math};

/// Leverage parameters expressed in Predict's 1e9 fixed-point price scaling.
#[allow(unused_field)]
public struct StrikeExposureConfig has store {
    /// Maximum terminal increase in the contract floor index over one expiry.
    /// `200_000_000` means the floor index rises from 1.00 to 1.20.
    max_expiry_floor_premium: u64,
    /// 1e9-scaled floor-to-live-value threshold for liquidation.
    /// `850_000_000` means liquidate at 85% LTV.
    liquidation_ltv: u64,
}

public(package) fun max_expiry_floor_premium(config: &StrikeExposureConfig): u64 {
    config.max_expiry_floor_premium
}

public(package) fun liquidation_ltv(config: &StrikeExposureConfig): u64 {
    config.liquidation_ltv
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
