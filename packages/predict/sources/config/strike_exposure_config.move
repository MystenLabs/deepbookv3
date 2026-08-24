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

const EEntryProbabilityOutOfBounds: u64 = 0;
const EInvalidEntryProbabilityBound: u64 = 1;
const EInvalidFeeProbability: u64 = 2;
const EPremiumBelowMinimum: u64 = 3;
const ESkewRateExceedsFeeFloor: u64 = 4;

/// Expiry-local exposure and fee policy expressed in Predict's 1e9 fixed-point scale.
public struct StrikeExposureConfig has store {
    /// Fraction of the disjoint-book backing gap reserved for early exits.
    /// A value of 1.0 reserves the full gap.
    backing_buffer_lambda: u64,
    /// Base fee multiplier for Bernoulli scaling.
    /// Effective base fee = base_fee * sqrt(price * (1 - price)).
    base_fee: u64,
    /// Minimum per-unit fee floor; live trade fees never go below this value.
    min_fee: u64,
    /// Minimum raw entry probability allowed for mint admission.
    min_entry_probability: u64,
    /// Maximum raw entry probability allowed for mint admission.
    max_entry_probability: u64,
    /// Window before expiry over which trade fees ramp up.
    expiry_fee_window_ms: u64,
    /// Fee multiplier reached at expiry, in FLOAT_SCALING; 1x disables the ramp.
    expiry_fee_max_multiplier: u64,
    /// Maximum marginal rate of the path-independent inventory-impact curve, in
    /// FLOAT_SCALING. `0` disables both charges and rebates.
    inventory_impact_max_rate: u64,
    /// Rate on the payout profile's probability-weighted standard deviation.
    /// Zero disables the charge.
    inventory_skew_rate: u64,
}

// === Public-Package Functions ===

public(package) fun backing_buffer_lambda(config: &StrikeExposureConfig): u64 {
    config.backing_buffer_lambda
}

public(package) fun base_fee(config: &StrikeExposureConfig): u64 {
    config.base_fee
}

public(package) fun min_fee(config: &StrikeExposureConfig): u64 {
    config.min_fee
}

public(package) fun min_entry_probability(config: &StrikeExposureConfig): u64 {
    config.min_entry_probability
}

public(package) fun max_entry_probability(config: &StrikeExposureConfig): u64 {
    config.max_entry_probability
}

public(package) fun expiry_fee_window_ms(config: &StrikeExposureConfig): u64 {
    config.expiry_fee_window_ms
}

public(package) fun expiry_fee_max_multiplier(config: &StrikeExposureConfig): u64 {
    config.expiry_fee_max_multiplier
}

public(package) fun inventory_impact_max_rate(config: &StrikeExposureConfig): u64 {
    config.inventory_impact_max_rate
}

public(package) fun inventory_skew_rate(config: &StrikeExposureConfig): u64 {
    config.inventory_skew_rate
}

/// Returns the raw trade fee for a live probability and quantity, rounded down so the trader keeps sub-unit dust.
///
/// Precondition: `timestamp_ms < expiry_ms`. Live-pricing callers enforce this
/// before passing timestamps because the fee-rate helper derives time-to-expiry
/// with exact subtraction.
public(package) fun trading_fee(
    config: &StrikeExposureConfig,
    expiry_ms: u64,
    probability: u64,
    quantity: u64,
    timestamp_ms: u64,
): u64 {
    math::mul_down(config.fee_rate(expiry_ms, probability, timestamp_ms), quantity)
}

/// Assert entry-probability policy without deriving quantity-dependent mint
/// terms. Budget-bias sizing runs this before searching so a policy-invalid
/// request aborts with its domain code in the same order the mint admission
/// itself would report it.
public(package) fun assert_mint_probability_policy(
    config: &StrikeExposureConfig,
    entry_probability: u64,
) {
    assert!(
        entry_probability >= config.min_entry_probability
            && entry_probability <= config.max_entry_probability,
        EEntryProbabilityOutOfBounds,
    );
}

/// Assert entry-probability and premium policy; return the premium. The holder
/// pays the contract's full entry value, so no gross distinction remains.
public(package) fun assert_mint_admission(
    config: &StrikeExposureConfig,
    entry_probability: u64,
    quantity: u64,
): u64 {
    config.assert_mint_probability_policy(entry_probability);

    let premium = math::mul_down(entry_probability, quantity);
    assert!(premium >= constants::min_premium!(), EPremiumBelowMinimum);
    premium
}

public(package) fun new(): StrikeExposureConfig {
    StrikeExposureConfig {
        backing_buffer_lambda: config_constants::default_backing_buffer_lambda!(),
        base_fee: config_constants::default_base_fee!(),
        min_fee: config_constants::default_min_fee!(),
        min_entry_probability: config_constants::default_min_entry_probability!(),
        max_entry_probability: config_constants::default_max_entry_probability!(),
        expiry_fee_window_ms: config_constants::default_expiry_fee_window_ms!(),
        expiry_fee_max_multiplier: config_constants::default_expiry_fee_max_multiplier!(),
        inventory_impact_max_rate: config_constants::default_inventory_impact_max_rate!(),
        inventory_skew_rate: config_constants::default_inventory_skew_rate!(),
    }
}

/// Snapshot a strike-exposure config into an independent live copy.
///
/// The rate/fee-floor relation re-asserted here is maintained by both setters
/// (`assert_skew_rate_within_fee_floor`), so the template can never hold the
/// bad pairing and this is a structurally unreachable tripwire — kept because
/// creation is the moment the pairing freezes into a market for life, and an
/// unreachable abort here is cheaper than a reachable bad snapshot. No
/// `expected_failure` test per unit-tests rule 4.
public(package) fun snapshot(config: &StrikeExposureConfig): StrikeExposureConfig {
    assert!(config.inventory_skew_rate <= 2 * config.min_fee, ESkewRateExceedsFeeFloor);
    StrikeExposureConfig {
        backing_buffer_lambda: config.backing_buffer_lambda,
        base_fee: config.base_fee,
        min_fee: config.min_fee,
        min_entry_probability: config.min_entry_probability,
        max_entry_probability: config.max_entry_probability,
        expiry_fee_window_ms: config.expiry_fee_window_ms,
        expiry_fee_max_multiplier: config.expiry_fee_max_multiplier,
        inventory_impact_max_rate: config.inventory_impact_max_rate,
        inventory_skew_rate: config.inventory_skew_rate,
    }
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
    config.assert_skew_rate_within_fee_floor(config.inventory_skew_rate, value);
    config.min_fee = value;
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

public(package) fun set_expiry_fee_window_ms(config: &mut StrikeExposureConfig, value: u64) {
    config_constants::assert_expiry_fee_window_ms(value);
    config.expiry_fee_window_ms = value;
}

public(package) fun set_expiry_fee_max_multiplier(config: &mut StrikeExposureConfig, value: u64) {
    config_constants::assert_expiry_fee_max_multiplier(value);
    config.expiry_fee_max_multiplier = value;
}

public(package) fun set_inventory_impact_max_rate(config: &mut StrikeExposureConfig, value: u64) {
    config_constants::assert_inventory_impact_max_rate(value);
    config.inventory_impact_max_rate = value;
}

public(package) fun set_inventory_skew_rate(config: &mut StrikeExposureConfig, value: u64) {
    config_constants::assert_inventory_skew_rate(value);
    config.assert_skew_rate_within_fee_floor(value, config.min_fee);
    config.inventory_skew_rate = value;
}

/// Return the 1e9-scaled per-unit trade fee.
///
/// Precondition: `timestamp_ms < expiry_ms`; callers must enforce pre-expiry
/// liveness before this helper derives `expiry_ms - timestamp_ms`.
fun fee_rate(
    config: &StrikeExposureConfig,
    expiry_ms: u64,
    probability: u64,
    timestamp_ms: u64,
): u64 {
    let raw_fee = config.raw_bernoulli_fee_rate(probability);
    let base = raw_fee.max(config.min_fee);
    let multiplier = config.expiry_fee_multiplier(expiry_ms - timestamp_ms);
    math::mul_down(base, multiplier)
}

fun raw_bernoulli_fee_rate(config: &StrikeExposureConfig, probability: u64): u64 {
    assert!(probability <= math::float_scaling!(), EInvalidFeeProbability);
    if (probability == 0 || probability == math::float_scaling!()) return 0;

    let complement = math::float_scaling!() - probability;
    let variance = math::mul_down(probability, complement);
    let bernoulli_factor = math::sqrt_down(variance);
    math::mul_down(config.base_fee, bernoulli_factor)
}

/// Linear ramp that scales the trade fee up as expiry approaches.
fun expiry_fee_multiplier(config: &StrikeExposureConfig, time_to_expiry_ms: u64): u64 {
    if (time_to_expiry_ms >= config.expiry_fee_window_ms) return math::float_scaling!();

    // = (max_multiplier - 1) * elapsed / window, round down; the trader keeps the ramp dust.
    let ramp = math::mul_div_down(
        config.expiry_fee_max_multiplier - math::float_scaling!(),
        config.expiry_fee_window_ms - time_to_expiry_ms,
        config.expiry_fee_window_ms,
    );
    math::float_scaling!() + ramp
}

/// The rate/fee-floor relation, enforced at every write to either side so the
/// template can never hold a pairing that would abort market creation.
///
/// A skew rebate is bounded by `rate * quantity / 2` — the deviation of a payout
/// profile moves by at most half the quantity added — while the ordinary fee is
/// bounded below by `min_fee * quantity`, since the `base_fee * sqrt(p(1-p))`
/// term vanishes at both probability extremes. Once `rate` passes twice the
/// floor, a trade that flattens the book earns more than it pays and the rebate
/// becomes farmable, which is exactly what `max_inventory_skew_rate` was sized
/// to prevent. Enforced relationally rather than by constants because `min_fee`
/// is admin-tunable with a floor of zero.
fun assert_skew_rate_within_fee_floor(
    _config: &StrikeExposureConfig,
    inventory_skew_rate: u64,
    min_fee: u64,
) {
    assert!(inventory_skew_rate <= 2 * min_fee, ESkewRateExceedsFeeFloor);
}
