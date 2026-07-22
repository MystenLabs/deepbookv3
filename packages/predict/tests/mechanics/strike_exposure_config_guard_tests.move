// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Strike-exposure scalar, relational, fee, and admission guards.
#[test_only]
module deepbook_predict::scope_mechanics__intent_guard__strike_exposure_config_tests;

use deepbook_predict::{config_constants, strike_exposure_config};

const FLOAT: u64 = 1_000_000_000;
const HALF_PROBABILITY: u64 = 500_000_000;
const LOW_PROBABILITY: u64 = 100_000_000;
const QUANTITY: u64 = 1_000_000_000;
const DEFAULT_HALF_PROBABILITY_CAP: u64 = 2_714_285_714;
const OUTSIDE_NO_LEVERAGE_WINDOW_MS: u64 = 86_400_000;
const TEST_EXPIRY_MS: u64 = 100_000_000;
const MINIMUM_PREMIUM_QUANTITY_MINUS_ONE: u64 = 1_999_998;
const TWO_X_LEVERAGE: u64 = 2_000_000_000;
const RAW_UNIT: u64 = 1;
const ZERO_TIMESTAMP_MS: u64 = 0;

#[test, expected_failure(abort_code = config_constants::EInvalidLiquidationLtv)]
fun liquidation_ltv_one_below_min_aborts() {
    strike_exposure_config::new().set_liquidation_ltv(
        config_constants::min_liquidation_ltv!() - RAW_UNIT,
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidLiquidationLtv)]
fun liquidation_ltv_one_above_max_aborts() {
    strike_exposure_config::new().set_liquidation_ltv(
        config_constants::max_liquidation_ltv!() + RAW_UNIT,
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidMaxAdmissionLeverage)]
fun max_leverage_one_below_min_aborts() {
    strike_exposure_config::new().set_max_admission_leverage(
        config_constants::min_max_admission_leverage!() - RAW_UNIT,
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidMaxAdmissionLeverage)]
fun max_leverage_one_above_max_aborts() {
    strike_exposure_config::new().set_max_admission_leverage(
        config_constants::max_max_admission_leverage!() + RAW_UNIT,
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidBackingBufferLambda)]
fun backing_lambda_one_below_min_aborts() {
    strike_exposure_config::new().set_backing_buffer_lambda(
        config_constants::min_backing_buffer_lambda!() - RAW_UNIT,
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidBackingBufferLambda)]
fun backing_lambda_one_above_max_aborts() {
    strike_exposure_config::new().set_backing_buffer_lambda(
        config_constants::max_backing_buffer_lambda!() + RAW_UNIT,
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidBaseFee)]
fun zero_base_fee_aborts() {
    strike_exposure_config::new().set_base_fee(config_constants::min_base_fee!() - RAW_UNIT);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidBaseFee)]
fun base_fee_one_above_max_aborts() {
    strike_exposure_config::new().set_base_fee(config_constants::max_base_fee!() + RAW_UNIT);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidMinFee)]
fun min_fee_one_above_max_aborts() {
    strike_exposure_config::new().set_min_fee(config_constants::max_min_fee!() + RAW_UNIT);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidMinEntryProbability)]
fun minimum_probability_one_below_envelope_aborts() {
    strike_exposure_config::new().set_min_entry_probability(
        config_constants::min_min_entry_probability!() - RAW_UNIT,
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidMinEntryProbability)]
fun minimum_probability_one_above_envelope_aborts() {
    strike_exposure_config::new().set_min_entry_probability(
        config_constants::max_min_entry_probability!() + RAW_UNIT,
    );
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure_config::EInvalidEntryProbabilityBound)]
fun minimum_probability_equal_to_current_max_aborts() {
    let mut config = strike_exposure_config::new();
    config.set_min_entry_probability(config_constants::default_max_entry_probability!());
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidMaxEntryProbability)]
fun maximum_probability_one_above_envelope_aborts() {
    strike_exposure_config::new().set_max_entry_probability(
        config_constants::max_max_entry_probability!() + RAW_UNIT,
    );
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure_config::EInvalidEntryProbabilityBound)]
fun maximum_probability_equal_to_current_min_aborts() {
    let mut config = strike_exposure_config::new();
    config.set_max_entry_probability(config_constants::default_min_entry_probability!());
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidExpiryFeeWindowMs)]
fun expiry_fee_window_one_below_min_aborts() {
    strike_exposure_config::new().set_expiry_fee_window_ms(
        config_constants::min_expiry_fee_window_ms!() - RAW_UNIT,
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidExpiryFeeWindowMs)]
fun expiry_fee_window_one_above_max_aborts() {
    strike_exposure_config::new().set_expiry_fee_window_ms(
        config_constants::max_expiry_fee_window_ms!() + RAW_UNIT,
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidExpiryFeeMaxMultiplier)]
fun expiry_multiplier_one_below_min_aborts() {
    strike_exposure_config::new().set_expiry_fee_max_multiplier(
        config_constants::min_expiry_fee_max_multiplier!() - RAW_UNIT,
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidExpiryFeeMaxMultiplier)]
fun expiry_multiplier_one_above_max_aborts() {
    strike_exposure_config::new().set_expiry_fee_max_multiplier(
        config_constants::max_expiry_fee_max_multiplier!() + RAW_UNIT,
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidNoLeverageWindowMs)]
fun no_leverage_window_one_above_max_aborts() {
    strike_exposure_config::new().set_no_leverage_window_ms(
        config_constants::max_no_leverage_window_ms!() + RAW_UNIT,
    );
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure_config::EInvalidFeeProbability)]
fun fee_probability_one_above_full_aborts() {
    strike_exposure_config::new().trading_fee(
        TEST_EXPIRY_MS,
        FLOAT + RAW_UNIT,
        QUANTITY,
        ZERO_TIMESTAMP_MS,
    );
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure_config::EEntryProbabilityOutOfBounds)]
fun admission_probability_one_below_min_aborts() {
    let config = strike_exposure_config::new();
    config.assert_mint_probability_and_leverage_policy(
        config_constants::default_min_entry_probability!() - RAW_UNIT,
        FLOAT,
        config_constants::default_no_leverage_window_ms!(),
    );
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure_config::EEntryProbabilityOutOfBounds)]
fun admission_probability_one_above_max_aborts() {
    let config = strike_exposure_config::new();
    config.assert_mint_probability_and_leverage_policy(
        config_constants::default_max_entry_probability!() + RAW_UNIT,
        FLOAT,
        config_constants::default_no_leverage_window_ms!(),
    );
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure_config::EInvalidLeverage)]
fun leverage_one_below_one_x_aborts() {
    strike_exposure_config::new().assert_mint_probability_and_leverage_policy(
        HALF_PROBABILITY,
        FLOAT - RAW_UNIT,
        OUTSIDE_NO_LEVERAGE_WINDOW_MS,
    );
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure_config::ELeverageAboveAdmissionCap)]
fun leverage_one_above_exact_curve_cap_aborts() {
    strike_exposure_config::new().assert_mint_probability_and_leverage_policy(
        HALF_PROBABILITY,
        DEFAULT_HALF_PROBABILITY_CAP + RAW_UNIT,
        OUTSIDE_NO_LEVERAGE_WINDOW_MS,
    );
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure_config::ELeverageAboveAdmissionCap)]
fun low_probability_curve_rejects_two_x() {
    strike_exposure_config::new().assert_mint_admission(
        LOW_PROBABILITY,
        QUANTITY,
        TWO_X_LEVERAGE,
        OUTSIDE_NO_LEVERAGE_WINDOW_MS,
    );
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure_config::ELeverageAboveAdmissionCap)]
fun configured_max_leverage_rescales_curve_cap() {
    let mut config = strike_exposure_config::new();
    config.set_max_admission_leverage(TWO_X_LEVERAGE);
    config.assert_mint_admission(
        HALF_PROBABILITY,
        QUANTITY,
        TWO_X_LEVERAGE,
        OUTSIDE_NO_LEVERAGE_WINDOW_MS,
    );
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure_config::ELeverageAboveAdmissionCap)]
fun no_leverage_window_rejects_one_unit_above_one_x() {
    let config = strike_exposure_config::new();
    config.assert_mint_probability_and_leverage_policy(
        HALF_PROBABILITY,
        FLOAT + RAW_UNIT,
        config_constants::default_no_leverage_window_ms!() - RAW_UNIT,
    );
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure_config::ENetPremiumBelowMinimum)]
fun net_premium_one_below_min_aborts() {
    strike_exposure_config::new().assert_mint_admission(
        HALF_PROBABILITY,
        MINIMUM_PREMIUM_QUANTITY_MINUS_ONE,
        FLOAT,
        OUTSIDE_NO_LEVERAGE_WINDOW_MS,
    );
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure_config::EOrderBelowLiquidationThreshold)]
fun liquidation_threshold_equality_aborts() {
    let mut config = strike_exposure_config::new();
    config.set_liquidation_ltv(config_constants::min_liquidation_ltv!());
    config.assert_mint_admission(
        HALF_PROBABILITY,
        QUANTITY,
        TWO_X_LEVERAGE,
        OUTSIDE_NO_LEVERAGE_WINDOW_MS,
    );
    abort 999
}
