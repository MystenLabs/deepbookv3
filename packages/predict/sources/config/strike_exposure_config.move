// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Stored strike-exposure policy config.
///
/// ProtocolConfig owns the current global template. Each StrikeExposure stores a
/// snapshot initialized from that template, so later admin updates do not reprice
/// active markets.
module deepbook_predict::strike_exposure_config;

use deepbook::math;
use deepbook_predict::{config_constants, constants, math as predict_math};

const ETerminalFloorExceedsLiquidationLtv: u64 = 0;
const EOrderBelowLiquidationThreshold: u64 = 1;

/// Leverage parameters expressed in Predict's 1e9 fixed-point price scaling.
public struct StrikeExposureConfig has store {
    /// Maximum terminal increase in the contract floor index over one expiry.
    /// `200_000_000` means the floor index rises from 1.00 to 1.20.
    max_expiry_floor_premium: u64,
    /// 1e9-scaled floor-to-live-value threshold for liquidation.
    /// `850_000_000` means liquidate at 85% LTV.
    liquidation_ltv: u64,
}

// === Public-Package Functions ===

public(package) fun max_expiry_floor_premium(config: &StrikeExposureConfig): u64 {
    config.max_expiry_floor_premium
}

public(package) fun liquidation_ltv(config: &StrikeExposureConfig): u64 {
    config.liquidation_ltv
}

/// Return the deterministic floor index at a timestamp for an expiry.
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

/// Convert floor shares into a floor amount at one timestamp in an expiry.
public(package) fun floor_amount_at_ms(
    config: &StrikeExposureConfig,
    expiry_ms: u64,
    floor_shares: u64,
    timestamp_ms: u64,
): u64 {
    let floor_index = config.floor_index_at_ms(expiry_ms, timestamp_ms);
    predict_math::mul_div_round_up(floor_shares, floor_index, constants::float_scaling!())
}

/// Return index update terms for one mint order and assert mint-only LTV policy.
///
/// `floor_shares` updates NAV; `terminal_payout` and `live_backing_payout`
/// update payout backing.
public(package) fun mint_index_update_terms(
    config: &StrikeExposureConfig,
    expiry_ms: u64,
    is_leveraged: bool,
    floor_seed_amount: u64,
    opened_at_ms: u64,
    entry_probability: u64,
    quantity: u64,
): (u64, u64, u64) {
    let (floor_shares, terminal_payout, live_backing_payout) = config.order_index_update_terms(
        expiry_ms,
        is_leveraged,
        floor_seed_amount,
        opened_at_ms,
        quantity,
    );
    config.assert_mint_above_liquidation_threshold(
        expiry_ms,
        is_leveraged,
        floor_shares,
        opened_at_ms,
        entry_probability,
        quantity,
    );
    (floor_shares, terminal_payout, live_backing_payout)
}

/// Return index update terms for one order's immutable floor fields.
///
/// `floor_shares` updates NAV; `terminal_payout` and `live_backing_payout`
/// update payout backing.
public(package) fun order_index_update_terms(
    config: &StrikeExposureConfig,
    expiry_ms: u64,
    is_leveraged: bool,
    floor_seed_amount: u64,
    opened_at_ms: u64,
    quantity: u64,
): (u64, u64, u64) {
    let floor_shares = if (is_leveraged) {
        config.floor_shares_for_seed(expiry_ms, floor_seed_amount, opened_at_ms)
    } else {
        0
    };
    let terminal_floor = config.floor_amount_at_ms(expiry_ms, floor_shares, expiry_ms);
    let max_terminal_floor = predict_math::mul_div_round_down(
        quantity,
        config.liquidation_ltv,
        constants::float_scaling!(),
    );
    assert!(terminal_floor < max_terminal_floor, ETerminalFloorExceedsLiquidationLtv);
    let floor_at_open = config.floor_amount_at_ms(expiry_ms, floor_shares, opened_at_ms);
    (floor_shares, quantity - terminal_floor, quantity - floor_at_open)
}

/// Return `(should_liquidate, gross_value, current_floor_amount)` for one candidate.
public(package) fun liquidation_check_terms(
    config: &StrikeExposureConfig,
    expiry_ms: u64,
    is_leveraged: bool,
    floor_seed_amount: u64,
    opened_at_ms: u64,
    quantity: u64,
    range_probability: u64,
    timestamp_ms: u64,
): (bool, u64, u64) {
    let gross_value = math::mul(range_probability, quantity);
    let current_floor_amount = if (is_leveraged) {
        let current_floor_shares = config.floor_shares_for_seed(
            expiry_ms,
            floor_seed_amount,
            opened_at_ms,
        );
        config.floor_amount_at_ms(expiry_ms, current_floor_shares, timestamp_ms)
    } else {
        0
    };
    let should_liquidate =
        !config.above_liquidation_threshold(
            gross_value,
            current_floor_amount,
        );
    (should_liquidate, gross_value, current_floor_amount)
}

public(package) fun new(): StrikeExposureConfig {
    StrikeExposureConfig {
        max_expiry_floor_premium: config_constants::default_max_expiry_floor_premium!(),
        liquidation_ltv: config_constants::default_liquidation_ltv!(),
    }
}

/// Snapshot a strike-exposure config into an independent live copy.
public(package) fun snapshot(config: &StrikeExposureConfig): StrikeExposureConfig {
    StrikeExposureConfig {
        max_expiry_floor_premium: config.max_expiry_floor_premium,
        liquidation_ltv: config.liquidation_ltv,
    }
}

public(package) fun set_max_expiry_floor_premium(config: &mut StrikeExposureConfig, value: u64) {
    config_constants::assert_max_expiry_floor_premium(value);
    config.max_expiry_floor_premium = value;
}

public(package) fun set_liquidation_ltv(config: &mut StrikeExposureConfig, value: u64) {
    config_constants::assert_liquidation_ltv(value);
    config.liquidation_ltv = value;
}

/// Return floor-index-normalized shares for a floor seed opened at a timestamp.
fun floor_shares_for_seed(
    config: &StrikeExposureConfig,
    expiry_ms: u64,
    floor_seed_amount: u64,
    opened_at_ms: u64,
): u64 {
    let open_index = config.floor_index_at_ms(expiry_ms, opened_at_ms);
    predict_math::mul_div_round_up(
        floor_seed_amount,
        constants::float_scaling!(),
        open_index,
    )
}

/// Return whether gross value is safely above the liquidation threshold.
fun above_liquidation_threshold(
    config: &StrikeExposureConfig,
    gross_value: u64,
    floor_amount: u64,
): bool {
    let threshold = predict_math::mul_div_round_up(
        floor_amount,
        constants::float_scaling!(),
        config.liquidation_ltv,
    );
    gross_value > threshold
}

fun assert_mint_above_liquidation_threshold(
    config: &StrikeExposureConfig,
    expiry_ms: u64,
    is_leveraged: bool,
    floor_shares: u64,
    opened_at_ms: u64,
    entry_probability: u64,
    quantity: u64,
) {
    if (!is_leveraged) return;

    let floor_amount = config.floor_amount_at_ms(expiry_ms, floor_shares, opened_at_ms);
    let gross_value = math::mul(entry_probability, quantity);
    assert!(
        config.above_liquidation_threshold(gross_value, floor_amount),
        EOrderBelowLiquidationThreshold,
    );
}
