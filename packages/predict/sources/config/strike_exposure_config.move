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

const EOrderBelowLiquidationThreshold: u64 = 0;
const EEntryProbabilityOutOfBounds: u64 = 1;
const EInvalidEntryProbabilityBound: u64 = 2;
const EInvalidFeeProbability: u64 = 3;
const ENetPremiumBelowMinimum: u64 = 4;
const EInvalidLeverage: u64 = 5;
const ELeverageAboveAdmissionCap: u64 = 6;
const EFeeCapBelowMinimum: u64 = 7;

/// Expiry-local exposure and fee policy expressed in Predict's 1e9 fixed-point scale.
public struct StrikeExposureConfig has store {
    /// 1e9-scaled floor-to-live-value threshold for liquidation. `850_000_000`
    /// means liquidate at 85% LTV. With a static floor the trigger is
    /// `qty·P <= floor_shares / liquidation_ltv`; the buffer is the anti-arbitrage
    /// enforcement margin (knock out a hair before zero equity), not a solvency
    /// margin — the reserve already backs the full `Q - F`.
    liquidation_ltv: u64,
    /// Global max leverage for mint admission, before the low-probability curve
    /// scales it down. Actual liquidation still uses `liquidation_ltv`.
    max_admission_leverage: u64,
    /// Fraction of the disjoint-book backing gap reserved for early exits.
    /// A value of 1.0 reserves the full gap.
    backing_buffer_lambda: u64,
    /// Base fee multiplier for Bernoulli scaling.
    /// Effective base fee = base_fee * sqrt(price * (1 - price)).
    base_fee: u64,
    /// Minimum per-unit fee floor; live trade fees never go below this value.
    min_fee: u64,
    /// Confidence-fee increase per unit of normalized digital sensitivity.
    fee_slope: u64,
    /// Absolute cap on the assembled base-times-loading fee.
    fee_cap: u64,
    /// Vendor-calibrated finite-bump sensitivity used to normalize confidence loading.
    confidence_fee_reference_sensitivity: u64,
    /// Minimum raw entry probability allowed for mint admission.
    min_entry_probability: u64,
    /// Maximum raw entry probability allowed for mint admission.
    max_entry_probability: u64,
    /// Window before expiry within which mint admission caps leverage at 1x, in ms.
    /// `0` disables the block.
    no_leverage_window_ms: u64,
}

/// Mint admission outcome: the net premium charged for the order and the static
/// floor `F` (`floor_shares`), returned together so callers read them by name.
public struct MintAdmission has drop {
    net_premium: u64,
    floor_shares: u64,
}

// === Public-Package Functions ===

public(package) fun liquidation_ltv(config: &StrikeExposureConfig): u64 {
    config.liquidation_ltv
}

public(package) fun max_admission_leverage(config: &StrikeExposureConfig): u64 {
    config.max_admission_leverage
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

public(package) fun fee_slope(config: &StrikeExposureConfig): u64 {
    config.fee_slope
}

public(package) fun fee_cap(config: &StrikeExposureConfig): u64 {
    config.fee_cap
}

public(package) fun confidence_fee_reference_sensitivity(config: &StrikeExposureConfig): u64 {
    config.confidence_fee_reference_sensitivity
}

public(package) fun min_entry_probability(config: &StrikeExposureConfig): u64 {
    config.min_entry_probability
}

public(package) fun max_entry_probability(config: &StrikeExposureConfig): u64 {
    config.max_entry_probability
}

public(package) fun no_leverage_window_ms(config: &StrikeExposureConfig): u64 {
    config.no_leverage_window_ms
}

/// Returns the raw trade fee for a live probability and quantity, rounded down so the trader keeps sub-unit dust.
///
public(package) fun trading_fee(
    config: &StrikeExposureConfig,
    probability: u64,
    quantity: u64,
    loading: u64,
): u64 {
    math::mul_down(config.fee_rate(probability, loading), quantity)
}

/// Assert entry probability and leverage policy without deriving quantity-dependent
/// mint terms. Budget-bias sizing runs this before searching so a policy-invalid
/// request aborts with its domain code before any division by `leverage`, in the
/// same order the mint admission itself would report it.
public(package) fun assert_mint_probability_and_leverage_policy(
    config: &StrikeExposureConfig,
    entry_probability: u64,
    leverage: u64,
    time_to_expiry_ms: u64,
) {
    assert!(
        entry_probability >= config.min_entry_probability
            && entry_probability <= config.max_entry_probability,
        EEntryProbabilityOutOfBounds,
    );

    // Leverage is continuous, with the protocol cap scaled down for low prices and
    // withheld entirely inside the no-leverage window before expiry.
    assert!(leverage >= math::float_scaling!(), EInvalidLeverage);
    assert!(
        leverage <= config.admitted_leverage_cap(entry_probability, time_to_expiry_ms),
        ELeverageAboveAdmissionCap,
    );
}

/// Assert entry probability, leverage, net-premium, and barrier policy; return a
/// `MintAdmission` carrying the net premium and the static floor `F`.
///
/// `floor_shares` is the static dollar floor `F = financed_amount = entry_value -
/// net_premium`. Leverage must be at least 1x and no greater than the admission
/// cap, which scales down for low probabilities and drops to 1x inside the
/// no-leverage window before expiry (`time_to_expiry_ms`). The actual live
/// liquidation threshold remains the market's fixed `liquidation_ltv`; admission
/// only decides whether the protocol originates the requested leverage.
public(package) fun assert_mint_admission(
    config: &StrikeExposureConfig,
    entry_probability: u64,
    quantity: u64,
    leverage: u64,
    time_to_expiry_ms: u64,
): MintAdmission {
    config.assert_mint_probability_and_leverage_policy(
        entry_probability,
        leverage,
        time_to_expiry_ms,
    );

    let entry_value = math::mul_down(entry_probability, quantity);
    let net_premium = math::div_down(entry_value, leverage);
    assert!(net_premium >= constants::min_net_premium!(), ENetPremiumBelowMinimum);
    let floor_shares = entry_value - net_premium;

    if (floor_shares > 0) {
        let liquidation_threshold_at_open = math::div_down(floor_shares, config.liquidation_ltv);
        assert!(entry_value > liquidation_threshold_at_open, EOrderBelowLiquidationThreshold);
    };

    MintAdmission { net_premium, floor_shares }
}

public(package) fun net_premium(admission: &MintAdmission): u64 {
    admission.net_premium
}

public(package) fun floor_shares(admission: &MintAdmission): u64 {
    admission.floor_shares
}

public(package) fun new(): StrikeExposureConfig {
    StrikeExposureConfig {
        liquidation_ltv: config_constants::default_liquidation_ltv!(),
        max_admission_leverage: config_constants::default_max_admission_leverage!(),
        backing_buffer_lambda: config_constants::default_backing_buffer_lambda!(),
        base_fee: config_constants::default_base_fee!(),
        min_fee: config_constants::default_min_fee!(),
        fee_slope: config_constants::default_fee_slope!(),
        fee_cap: config_constants::default_fee_cap!(),
        confidence_fee_reference_sensitivity: config_constants::default_confidence_fee_reference_sensitivity!(),
        min_entry_probability: config_constants::default_min_entry_probability!(),
        max_entry_probability: config_constants::default_max_entry_probability!(),
        no_leverage_window_ms: config_constants::default_no_leverage_window_ms!(),
    }
}

/// Snapshot a strike-exposure config into an independent live copy.
public(package) fun snapshot(config: &StrikeExposureConfig): StrikeExposureConfig {
    StrikeExposureConfig {
        liquidation_ltv: config.liquidation_ltv,
        max_admission_leverage: config.max_admission_leverage,
        backing_buffer_lambda: config.backing_buffer_lambda,
        base_fee: config.base_fee,
        min_fee: config.min_fee,
        fee_slope: config.fee_slope,
        fee_cap: config.fee_cap,
        confidence_fee_reference_sensitivity: config.confidence_fee_reference_sensitivity,
        min_entry_probability: config.min_entry_probability,
        max_entry_probability: config.max_entry_probability,
        no_leverage_window_ms: config.no_leverage_window_ms,
    }
}

public(package) fun set_liquidation_ltv(config: &mut StrikeExposureConfig, value: u64) {
    config_constants::assert_liquidation_ltv(value);
    config.liquidation_ltv = value;
}

public(package) fun set_max_admission_leverage(config: &mut StrikeExposureConfig, value: u64) {
    config_constants::assert_max_admission_leverage(value);
    config.max_admission_leverage = value;
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
    assert!(value <= config.fee_cap, EFeeCapBelowMinimum);
    config.min_fee = value;
}

public(package) fun set_fee_slope(config: &mut StrikeExposureConfig, value: u64) {
    config_constants::assert_fee_slope(value);
    config.fee_slope = value;
}

public(package) fun set_fee_cap(config: &mut StrikeExposureConfig, value: u64) {
    config_constants::assert_fee_cap(value);
    assert!(value >= config.min_fee, EFeeCapBelowMinimum);
    config.fee_cap = value;
}

public(package) fun set_confidence_fee_reference_sensitivity(
    config: &mut StrikeExposureConfig,
    value: u64,
) {
    config_constants::assert_confidence_fee_reference_sensitivity(value);
    config.confidence_fee_reference_sensitivity = value;
}

public(package) fun set_min_entry_probability(config: &mut StrikeExposureConfig, value: u64) {
    config_constants::assert_min_entry_probability(value);
    assert!(value < config.max_entry_probability, EInvalidEntryProbabilityBound);
    config.min_entry_probability = value;
}

public(package) fun set_max_entry_probability(config: &mut StrikeExposureConfig, value: u64) {
    config_constants::assert_max_entry_probability(value);
    assert!(value > config.min_entry_probability, EInvalidEntryProbabilityBound);
    config.max_entry_probability = value;
}

public(package) fun set_no_leverage_window_ms(config: &mut StrikeExposureConfig, window_ms: u64) {
    config_constants::assert_no_leverage_window_ms(window_ms);
    config.no_leverage_window_ms = window_ms;
}

/// Return the 1e9-scaled per-unit confidence fee.
fun fee_rate(config: &StrikeExposureConfig, probability: u64, loading: u64): u64 {
    let raw_fee = config.raw_bernoulli_fee_rate(probability);
    let base = raw_fee.max(config.min_fee);
    let multiplier = math::float_scaling!() + math::mul_down(config.fee_slope, loading);
    math::mul_down(base, multiplier).min(config.fee_cap)
}

fun raw_bernoulli_fee_rate(config: &StrikeExposureConfig, probability: u64): u64 {
    assert!(probability <= math::float_scaling!(), EInvalidFeeProbability);
    if (probability == 0 || probability == math::float_scaling!()) return 0;

    let complement = math::float_scaling!() - probability;
    let variance = math::mul_down(probability, complement);
    let bernoulli_factor = math::sqrt_down(variance);
    math::mul_down(config.base_fee, bernoulli_factor)
}

/// Max leverage mint admission will originate, given the entry probability and the
/// time left to expiry.
///
/// Inside the no-leverage window the cap is exactly 1x, so no leverage is
/// originated into the highest-gamma stretch of the market's life regardless of
/// price. Outside it the cap is the configured max scaled down by the
/// low-probability risk curve. A `0` window disables the block: no unsigned
/// time-to-expiry is below zero, so the comparison never fires.
///
/// Precondition: `time_to_expiry_ms` is derived under caller-enforced pre-expiry
/// liveness.
fun admitted_leverage_cap(
    config: &StrikeExposureConfig,
    entry_probability: u64,
    time_to_expiry_ms: u64,
): u64 {
    if (time_to_expiry_ms < config.no_leverage_window_ms) return math::float_scaling!();

    let k = config_constants::admission_leverage_curve_k!();
    let risk_curve = math::mul_div_down(
        entry_probability,
        math::float_scaling!() + k,
        entry_probability + k,
    );
    math::float_scaling!()
        + math::mul_down(config.max_admission_leverage - math::float_scaling!(), risk_curve)
}
