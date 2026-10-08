// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Stored strike-exposure policy config.
///
/// ProtocolConfig owns the current global template. Each StrikeExposure stores a
/// snapshot initialized from that template, so later admin updates do not reprice
/// active markets. Fee policy lives here because fees consume prices but are not
/// themselves contract probability.
module deepbook_predict::strike_exposure_config;

use deepbook_predict::{config_constants, pricing::RangePrice};
use deepbook_predict_math::math as pmath;
use fixed_math::math;

#[allow(unused_const)]
const EEntryProbabilityOutOfBounds: u64 = 0;
const EInvalidEntryProbabilityBound: u64 = 1;
const EInvalidFeeProbability: u64 = 2;
#[allow(unused_const)]
const EPremiumBelowMinimum: u64 = 3;

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

public(package) fun min_prob(config: &StrikeExposureConfig): u64 {
    config.min_entry_probability
}

public(package) fun max_prob(config: &StrikeExposureConfig): u64 {
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

/// Charge each finite boundary independently, including its floor and rounding.
/// Infinite boundaries contribute no fee; a finite tail still pays the floor.
public(package) fun trading_fee(
    config: &StrikeExposureConfig,
    expiry_ms: u64,
    price: &RangePrice,
    quantity: u64,
    timestamp_ms: u64,
): u64 {
    let lower_fee = price
        .lower_up()
        .map!(|p| config.leg_fee(expiry_ms, p, quantity, timestamp_ms))
        .get_with_default(0);
    let higher_fee = price
        .higher_up()
        .map!(|p| config.leg_fee(expiry_ms, p, quantity, timestamp_ms))
        .get_with_default(0);
    lower_fee + higher_fee
}

/// Non-aborting policy half of `assert_mint_probability_policy`: whether
/// `entry_probability` lies inside the inclusive entry band. The assert calls
/// this, so the rule lives in one place.
public(package) fun prob_ok(
    config: &StrikeExposureConfig,
    entry_probability: u64,
): bool {
    entry_probability >= config.min_entry_probability
        && entry_probability <= config.max_entry_probability
}

/// Non-aborting policy half of `assert_range_mint_probability_policy`: the
/// entry band applied to the actual lower-ABOVE and upper-BELOW legs and to
/// their combined range. An infinite boundary has no leg to check.
public(package) fun range_ok(
    config: &StrikeExposureConfig,
    price: &RangePrice,
): bool {
    price.lower_up().map!(|p| config.prob_ok(p)).get_with_default(true)
        && price
            .higher_up()
            .map!(|p| config.prob_ok(math::float_scaling!() - p))
            .get_with_default(true)
        && config.prob_ok(price.probability())
}

/// Apply entry policy to the actual lower-ABOVE and upper-BELOW legs and to
/// their combined range. This is mint-only; tail positions remain closable.
#[test_only]
public(package) fun assert_range_mint_probability_policy(
    config: &StrikeExposureConfig,
    price: &RangePrice,
) {
    assert!(config.range_ok(price), EEntryProbabilityOutOfBounds);
}

/// Assert entry-probability policy without deriving quantity-dependent mint
/// terms. Budget-bias sizing runs this before searching so a policy-invalid
/// request aborts with its domain code in the same order the mint admission
/// itself would report it.
#[test_only]
public(package) fun assert_mint_probability_policy(
    config: &StrikeExposureConfig,
    entry_probability: u64,
) {
    assert!(config.prob_ok(entry_probability), EEntryProbabilityOutOfBounds);
}

/// Assert entry-probability and premium policy; return the premium. The holder
/// pays the contract's full entry value, so no gross distinction remains.
#[test_only]
public(package) fun assert_mint_admission(
    config: &StrikeExposureConfig,
    entry_probability: u64,
    quantity: u64,
): u64 {
    config.assert_mint_probability_policy(entry_probability);

    let premium = math::mul_down(entry_probability, quantity);
    assert!(premium >= deepbook_predict::constants::min_premium!(), EPremiumBelowMinimum);
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
    }
}

/// Snapshot a strike-exposure config into an independent live copy.
public(package) fun snapshot(config: &StrikeExposureConfig): StrikeExposureConfig {
    StrikeExposureConfig {
        backing_buffer_lambda: config.backing_buffer_lambda,
        base_fee: config.base_fee,
        min_fee: config.min_fee,
        min_entry_probability: config.min_entry_probability,
        max_entry_probability: config.max_entry_probability,
        expiry_fee_window_ms: config.expiry_fee_window_ms,
        expiry_fee_max_multiplier: config.expiry_fee_max_multiplier,
        inventory_impact_max_rate: config.inventory_impact_max_rate,
    }
}

public(package) fun set_lambda(config: &mut StrikeExposureConfig, value: u64) {
    config_constants::chk_lambda(value);
    config.backing_buffer_lambda = value;
}

public(package) fun set_base_fee(config: &mut StrikeExposureConfig, value: u64) {
    config_constants::chk_base_fee(value);
    config.base_fee = value;
}

public(package) fun set_min_fee(config: &mut StrikeExposureConfig, value: u64) {
    config_constants::chk_min_fee(value);
    config.min_fee = value;
}

public(package) fun set_min_prob(config: &mut StrikeExposureConfig, value: u64) {
    config_constants::chk_min_prob(value);
    assert!(value < config.max_entry_probability, EInvalidEntryProbabilityBound);
    config.min_entry_probability = value;
}

public(package) fun set_max_prob(config: &mut StrikeExposureConfig, value: u64) {
    config_constants::chk_max_prob(value);
    assert!(value > config.min_entry_probability, EInvalidEntryProbabilityBound);
    config.max_entry_probability = value;
}

public(package) fun set_fee_win(config: &mut StrikeExposureConfig, value: u64) {
    config_constants::chk_fee_win(value);
    config.expiry_fee_window_ms = value;
}

public(package) fun set_fee_mult(config: &mut StrikeExposureConfig, value: u64) {
    config_constants::chk_fee_mult(value);
    config.expiry_fee_max_multiplier = value;
}

public(package) fun set_impact(config: &mut StrikeExposureConfig, value: u64) {
    config_constants::chk_impact(value);
    config.inventory_impact_max_rate = value;
}

/// Return one finite boundary's fee, rounding down so the trader keeps sub-unit dust:
/// `deepbook_predict_math::math::leg_fee` over this config's Bernoulli fee curve, minimum
/// fee, and expiry ramp.
///
/// Precondition: `timestamp_ms < expiry_ms`; callers must enforce pre-expiry
/// liveness before this helper derives `expiry_ms - timestamp_ms`.
fun leg_fee(
    config: &StrikeExposureConfig,
    expiry_ms: u64,
    probability: u64,
    quantity: u64,
    timestamp_ms: u64,
): u64 {
    // RangePrice fields are private to pricing; its digital probabilities are clamped to [0, 1].
    assert!(probability <= math::float_scaling!(), EInvalidFeeProbability);
    pmath::leg_fee(
        config.base_fee,
        config.min_fee,
        config.expiry_fee_window_ms,
        config.expiry_fee_max_multiplier,
        probability,
        quantity,
        expiry_ms - timestamp_ms,
    )
}
