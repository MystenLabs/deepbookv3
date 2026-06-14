// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Stored strike-exposure policy config.
///
/// ProtocolConfig owns the current global template. Each StrikeExposure stores a
/// snapshot initialized from that template, so later admin updates do not reprice
/// active markets. Fee policy lives here because fees consume prices but are not
/// themselves contract probability.
module deepbook_predict::strike_exposure_config;

use deepbook_predict::{config_constants, constants};
use fixed_math::math;

const ETerminalFloorExceedsLiquidationLtv: u64 = 0;
const EOrderBelowLiquidationThreshold: u64 = 1;
const EAskPriceOutOfBounds: u64 = 2;
const EInvalidAskBound: u64 = 3;
const EInvalidFeeProbability: u64 = 4;
const ENetPremiumBelowMinimum: u64 = 5;
const EInvalidLeverageTier: u64 = 6;
const EInvalidLeverage: u64 = 7;

const LEVERAGE_ONE_X: u64 = 1_000_000_000;
const LEVERAGE_ONE_AND_HALF_X: u64 = 1_500_000_000;
const LEVERAGE_TWO_X: u64 = 2_000_000_000;
const LEVERAGE_TWO_AND_HALF_X: u64 = 2_500_000_000;
const LEVERAGE_THREE_X: u64 = 3_000_000_000;

/// Expiry-local exposure and fee policy expressed in Predict's 1e9 fixed-point scale.
public struct StrikeExposureConfig has store {
    /// Terminal floor index reached at expiry.
    /// `1_200_000_000` means the floor index rises from 1.00 to 1.20.
    terminal_floor_index: u64,
    /// 1e9-scaled floor-to-live-value threshold for liquidation.
    /// `850_000_000` means liquidate at 85% LTV.
    liquidation_ltv: u64,
    /// Fraction of the disjoint-book backing gap reserved for early exits.
    /// 1.0 fully reserves early exits, matching the pre-buffer summed reserve.
    backing_buffer_lambda: u64,
    /// Base fee multiplier for Bernoulli scaling.
    /// Effective base fee = base_fee * sqrt(price * (1 - price)).
    base_fee: u64,
    /// Minimum per-unit fee floor; live trade fees never go below this value.
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

// === Public-Package Functions ===

public(package) fun terminal_floor_index(config: &StrikeExposureConfig): u64 {
    config.terminal_floor_index
}

public(package) fun liquidation_ltv(config: &StrikeExposureConfig): u64 {
    config.liquidation_ltv
}

public(package) fun backing_buffer_lambda(config: &StrikeExposureConfig): u64 {
    config.backing_buffer_lambda
}

public(package) fun base_fee(config: &StrikeExposureConfig): u64 {
    config.base_fee
}

public(package) fun min_fee(config: &StrikeExposureConfig): u64 {
    config.min_fee
}

public(package) fun min_ask_price(config: &StrikeExposureConfig): u64 {
    config.min_ask_price
}

public(package) fun max_ask_price(config: &StrikeExposureConfig): u64 {
    config.max_ask_price
}

public(package) fun expiry_fee_window_ms(config: &StrikeExposureConfig): u64 {
    config.expiry_fee_window_ms
}

public(package) fun expiry_fee_max_multiplier(config: &StrikeExposureConfig): u64 {
    config.expiry_fee_max_multiplier
}

/// Return the deterministic floor index at a timestamp for an expiry.
public(package) fun floor_index_at_ms(
    config: &StrikeExposureConfig,
    expiry_ms: u64,
    timestamp_ms: u64,
): u64 {
    let base = math::float_scaling!();
    if (timestamp_ms >= expiry_ms) return config.terminal_floor_index;

    let window = constants::leverage_floor_window_ms!();
    let remaining = expiry_ms - timestamp_ms;
    if (remaining >= window) return base;

    let elapsed = window - remaining;
    let phase = math::div(elapsed, window);
    let phase_squared = math::mul(phase, phase);

    let max_floor_premium = config.terminal_floor_index - base;
    let floor_premium = math::mul(max_floor_premium, phase_squared);
    base + floor_premium
}

/// Terminal payout for an order's atoms: `quantity - floor(floor_shares * terminal_floor_index)`.
/// The exact subtraction is deliberate: mint asserts the terminal-floor LTV bound
/// before any term evaluation, so an abort here means the order's atoms did not
/// survive their round-trip.
public(package) fun terminal_payout(
    config: &StrikeExposureConfig,
    quantity: u64,
    floor_shares: u64,
): u64 {
    quantity - config.terminal_floor(floor_shares)
}

/// Canonical payout-index term evaluation from an order's atoms.
///
/// Returns `(terminal_payout, live_backing_payout)`: terminal payout nets the
/// terminal floor; live backing nets the open-index floor, a conservative upper
/// bound on future live payout. Mint insert, close-side remove/reinsert, and the
/// settled payout recompute all price through this function (or its
/// `terminal_payout` primitive) — no other module may express these formulas, so
/// the payout tree's inserted, removed, and settlement-recomputed terms stay
/// bit-equal by construction.
public(package) fun index_terms(
    config: &StrikeExposureConfig,
    expiry_ms: u64,
    opened_at_ms: u64,
    quantity: u64,
    floor_shares: u64,
): (u64, u64) {
    let terminal_payout = config.terminal_payout(quantity, floor_shares);
    let open_floor_index = config.floor_index_at_ms(expiry_ms, opened_at_ms);
    let live_backing_payout = quantity - math::mul(floor_shares, open_floor_index);
    (terminal_payout, live_backing_payout)
}

/// Return the raw trade fee for a live probability and quantity.
public(package) fun trading_fee(
    config: &StrikeExposureConfig,
    expiry_ms: u64,
    probability: u64,
    quantity: u64,
    timestamp_ms: u64,
): u64 {
    math::mul(config.fee_rate(expiry_ms, probability, timestamp_ms), quantity)
}

/// Assert mint price, leverage, and net-premium policy and return derived mint economics.
///
/// Returns `(net_premium, financed_amount)`.
public(package) fun assert_mint_admission_policy(
    config: &StrikeExposureConfig,
    expiry_ms: u64,
    opened_at_ms: u64,
    entry_probability: u64,
    quantity: u64,
    leverage: u64,
): (u64, u64) {
    let fee_rate = config.fee_rate(expiry_ms, entry_probability, opened_at_ms);
    let execution_price = entry_probability + fee_rate;
    assert!(
        execution_price >= config.min_ask_price && execution_price <= config.max_ask_price,
        EAskPriceOutOfBounds,
    );

    assert!(
        leverage == LEVERAGE_ONE_X
            || leverage == LEVERAGE_ONE_AND_HALF_X
            || leverage == LEVERAGE_TWO_X
            || leverage == LEVERAGE_TWO_AND_HALF_X
            || leverage == LEVERAGE_THREE_X,
        EInvalidLeverage,
    );
    if (entry_probability < constants::leverage_one_x_only_price_threshold!()) {
        assert!(leverage == LEVERAGE_ONE_X, EInvalidLeverageTier);
    } else if (entry_probability < constants::leverage_two_x_max_price_threshold!()) {
        assert!(leverage <= LEVERAGE_TWO_X, EInvalidLeverageTier);
    };

    let entry_value = math::mul(entry_probability, quantity);
    let net_premium = math::div(entry_value, leverage);
    assert!(net_premium >= constants::min_net_premium!(), ENetPremiumBelowMinimum);
    let financed_amount = entry_value - net_premium;

    if (financed_amount > 0) {
        let liquidation_threshold_at_open = math::div(financed_amount, config.liquidation_ltv);
        assert!(entry_value > liquidation_threshold_at_open, EOrderBelowLiquidationThreshold);
    };

    (net_premium, financed_amount)
}

/// Assert mint floor policy and return `(floor_shares, terminal_payout, live_backing_payout)`.
///
/// Quantizes the floor seed into durable floor shares (mint-only rounding),
/// asserts the terminal-floor LTV admission bound, then prices the index terms
/// through the canonical `index_terms` evaluation. Validating before evaluating
/// keeps every invalid mint on the named abort and keeps the evaluator's
/// underflow meaning a broken atom round-trip; re-calling the canonical
/// `terminal_floor` for the assert costs one redundant `mul` but never
/// re-expresses the formula.
public(package) fun assert_mint_floor_terms(
    config: &StrikeExposureConfig,
    expiry_ms: u64,
    opened_at_ms: u64,
    financed_amount: u64,
    quantity: u64,
): (u64, u64, u64) {
    let open_floor_index = config.floor_index_at_ms(expiry_ms, opened_at_ms);
    let floor_shares = math::div(financed_amount, open_floor_index);
    let max_terminal_floor = math::mul(quantity, config.liquidation_ltv);
    assert!(
        config.terminal_floor(floor_shares) < max_terminal_floor,
        ETerminalFloorExceedsLiquidationLtv,
    );
    let (terminal_payout, live_backing_payout) = config.index_terms(
        expiry_ms,
        opened_at_ms,
        quantity,
        floor_shares,
    );
    (floor_shares, terminal_payout, live_backing_payout)
}

public(package) fun new(): StrikeExposureConfig {
    StrikeExposureConfig {
        terminal_floor_index: config_constants::default_terminal_floor_index!(),
        liquidation_ltv: config_constants::default_liquidation_ltv!(),
        backing_buffer_lambda: config_constants::default_backing_buffer_lambda!(),
        base_fee: config_constants::default_base_fee!(),
        min_fee: config_constants::default_min_fee!(),
        min_ask_price: config_constants::default_min_ask_price!(),
        max_ask_price: config_constants::default_max_ask_price!(),
        expiry_fee_window_ms: config_constants::default_expiry_fee_window_ms!(),
        expiry_fee_max_multiplier: config_constants::default_expiry_fee_max_multiplier!(),
    }
}

/// Snapshot a strike-exposure config into an independent live copy.
public(package) fun snapshot(config: &StrikeExposureConfig): StrikeExposureConfig {
    StrikeExposureConfig {
        terminal_floor_index: config.terminal_floor_index,
        liquidation_ltv: config.liquidation_ltv,
        backing_buffer_lambda: config.backing_buffer_lambda,
        base_fee: config.base_fee,
        min_fee: config.min_fee,
        min_ask_price: config.min_ask_price,
        max_ask_price: config.max_ask_price,
        expiry_fee_window_ms: config.expiry_fee_window_ms,
        expiry_fee_max_multiplier: config.expiry_fee_max_multiplier,
    }
}

public(package) fun set_terminal_floor_index(config: &mut StrikeExposureConfig, value: u64) {
    config_constants::assert_terminal_floor_index(value);
    config.terminal_floor_index = value;
}

public(package) fun set_liquidation_ltv(config: &mut StrikeExposureConfig, value: u64) {
    config_constants::assert_liquidation_ltv(value);
    config.liquidation_ltv = value;
}

public(package) fun set_backing_buffer_lambda(config: &mut StrikeExposureConfig, value: u64) {
    config_constants::assert_backing_buffer_lambda(value);
    config.backing_buffer_lambda = value;
}

public(package) fun set_base_fee(config: &mut StrikeExposureConfig, value: u64) {
    config_constants::assert_base_fee(value);
    config.base_fee = value;
}

public(package) fun set_min_fee(config: &mut StrikeExposureConfig, value: u64) {
    config_constants::assert_min_fee(value);
    config.min_fee = value;
}

public(package) fun set_min_ask_price(config: &mut StrikeExposureConfig, value: u64) {
    config_constants::assert_min_ask_price(value);
    assert!(value < config.max_ask_price, EInvalidAskBound);
    config.min_ask_price = value;
}

public(package) fun set_max_ask_price(config: &mut StrikeExposureConfig, value: u64) {
    config_constants::assert_max_ask_price(value);
    assert!(value > config.min_ask_price, EInvalidAskBound);
    config.max_ask_price = value;
}

public(package) fun set_expiry_fee_window_ms(config: &mut StrikeExposureConfig, value: u64) {
    config_constants::assert_expiry_fee_window_ms(value);
    config.expiry_fee_window_ms = value;
}

public(package) fun set_expiry_fee_max_multiplier(config: &mut StrikeExposureConfig, value: u64) {
    config_constants::assert_expiry_fee_max_multiplier(value);
    config.expiry_fee_max_multiplier = value;
}

/// Terminal floor for quantized floor shares: `floor(floor_shares * terminal_floor_index)`.
fun terminal_floor(config: &StrikeExposureConfig, floor_shares: u64): u64 {
    math::mul(floor_shares, config.terminal_floor_index)
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
    assert!(probability <= math::float_scaling!(), EInvalidFeeProbability);
    if (probability == 0 || probability == math::float_scaling!()) return 0;

    let complement = math::float_scaling!() - probability;
    let variance = math::mul(probability, complement);
    let bernoulli_factor = math::sqrt(variance, math::float_scaling!());
    math::mul(config.base_fee, bernoulli_factor)
}

/// Linear ramp that scales the trade fee up as expiry approaches.
fun expiry_fee_multiplier(config: &StrikeExposureConfig, time_to_expiry_ms: u64): u64 {
    if (time_to_expiry_ms >= config.expiry_fee_window_ms) return math::float_scaling!();

    let phase = math::div(
        config.expiry_fee_window_ms - time_to_expiry_ms,
        config.expiry_fee_window_ms,
    );
    let ramp = math::mul(config.expiry_fee_max_multiplier - math::float_scaling!(), phase);
    math::float_scaling!() + ramp
}
