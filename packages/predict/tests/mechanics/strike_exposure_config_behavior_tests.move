// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Strike-exposure policy defaults, setter writes, and reachable endpoints.
#[test_only]
module deepbook_predict::scope_mechanics__intent_behavior__strike_exposure_config_tests;

use deepbook_predict::{config_constants, strike_exposure_config};
use std::unit_test::{assert_eq, destroy};

const SAMPLE_LIQUIDATION_LTV: u64 = 500_000_000;
const SAMPLE_MAX_ADMISSION_LEVERAGE: u64 = 2_000_000_000;
const SAMPLE_BACKING_BUFFER_LAMBDA: u64 = 100_000_000;
const SAMPLE_BASE_FEE: u64 = 10_000_000;
const SAMPLE_MIN_FEE: u64 = 1_000_000;
const SAMPLE_MIN_ENTRY_PROBABILITY: u64 = 20_000_000;
const SAMPLE_MAX_ENTRY_PROBABILITY: u64 = 900_000_000;
const SAMPLE_EXPIRY_FEE_WINDOW_MS: u64 = 300_000;
const SAMPLE_EXPIRY_FEE_MAX_MULTIPLIER: u64 = 2_000_000_000;
const SAMPLE_NO_LEVERAGE_WINDOW_MS: u64 = 0;
const RAW_UNIT: u64 = 1;

#[test]
fun defaults_match_each_owned_policy_constant() {
    let config = strike_exposure_config::new();
    assert_eq!(config.liquidation_ltv(), config_constants::default_liquidation_ltv!());
    assert_eq!(
        config.max_admission_leverage(),
        config_constants::default_max_admission_leverage!(),
    );
    assert_eq!(config.backing_buffer_lambda(), config_constants::default_backing_buffer_lambda!());
    assert_eq!(config.base_fee(), config_constants::default_base_fee!());
    assert_eq!(config.min_fee(), config_constants::default_min_fee!());
    assert_eq!(config.min_entry_probability(), config_constants::default_min_entry_probability!());
    assert_eq!(config.max_entry_probability(), config_constants::default_max_entry_probability!());
    assert_eq!(config.expiry_fee_window_ms(), config_constants::default_expiry_fee_window_ms!());
    assert_eq!(
        config.expiry_fee_max_multiplier(),
        config_constants::default_expiry_fee_max_multiplier!(),
    );
    assert_eq!(config.no_leverage_window_ms(), config_constants::default_no_leverage_window_ms!());
    destroy(config);
}

#[test]
fun every_setter_stores_its_supplied_value() {
    let mut config = strike_exposure_config::new();
    config.set_liquidation_ltv(SAMPLE_LIQUIDATION_LTV);
    config.set_max_admission_leverage(SAMPLE_MAX_ADMISSION_LEVERAGE);
    config.set_backing_buffer_lambda(SAMPLE_BACKING_BUFFER_LAMBDA);
    config.set_base_fee(SAMPLE_BASE_FEE);
    config.set_min_fee(SAMPLE_MIN_FEE);
    config.set_min_entry_probability(SAMPLE_MIN_ENTRY_PROBABILITY);
    config.set_max_entry_probability(SAMPLE_MAX_ENTRY_PROBABILITY);
    config.set_expiry_fee_window_ms(SAMPLE_EXPIRY_FEE_WINDOW_MS);
    config.set_expiry_fee_max_multiplier(SAMPLE_EXPIRY_FEE_MAX_MULTIPLIER);
    config.set_no_leverage_window_ms(SAMPLE_NO_LEVERAGE_WINDOW_MS);
    assert_eq!(config.liquidation_ltv(), SAMPLE_LIQUIDATION_LTV);
    assert_eq!(config.max_admission_leverage(), SAMPLE_MAX_ADMISSION_LEVERAGE);
    assert_eq!(config.backing_buffer_lambda(), SAMPLE_BACKING_BUFFER_LAMBDA);
    assert_eq!(config.base_fee(), SAMPLE_BASE_FEE);
    assert_eq!(config.min_fee(), SAMPLE_MIN_FEE);
    assert_eq!(config.min_entry_probability(), SAMPLE_MIN_ENTRY_PROBABILITY);
    assert_eq!(config.max_entry_probability(), SAMPLE_MAX_ENTRY_PROBABILITY);
    assert_eq!(config.expiry_fee_window_ms(), SAMPLE_EXPIRY_FEE_WINDOW_MS);
    assert_eq!(config.expiry_fee_max_multiplier(), SAMPLE_EXPIRY_FEE_MAX_MULTIPLIER);
    assert_eq!(config.no_leverage_window_ms(), SAMPLE_NO_LEVERAGE_WINDOW_MS);
    destroy(config);
}

#[test]
fun every_setter_accepts_its_reachable_boundaries() {
    let mut config = strike_exposure_config::new();
    config.set_liquidation_ltv(config_constants::min_liquidation_ltv!());
    assert_eq!(config.liquidation_ltv(), config_constants::min_liquidation_ltv!());
    config.set_liquidation_ltv(config_constants::max_liquidation_ltv!());
    assert_eq!(config.liquidation_ltv(), config_constants::max_liquidation_ltv!());
    config.set_max_admission_leverage(config_constants::min_max_admission_leverage!());
    assert_eq!(config.max_admission_leverage(), config_constants::min_max_admission_leverage!());
    config.set_max_admission_leverage(config_constants::max_max_admission_leverage!());
    assert_eq!(config.max_admission_leverage(), config_constants::max_max_admission_leverage!());
    config.set_backing_buffer_lambda(config_constants::min_backing_buffer_lambda!());
    assert_eq!(config.backing_buffer_lambda(), config_constants::min_backing_buffer_lambda!());
    config.set_backing_buffer_lambda(config_constants::max_backing_buffer_lambda!());
    assert_eq!(config.backing_buffer_lambda(), config_constants::max_backing_buffer_lambda!());
    config.set_base_fee(config_constants::min_base_fee!());
    assert_eq!(config.base_fee(), config_constants::min_base_fee!());
    config.set_base_fee(config_constants::max_base_fee!());
    assert_eq!(config.base_fee(), config_constants::max_base_fee!());
    config.set_min_fee(config_constants::min_min_fee!());
    assert_eq!(config.min_fee(), config_constants::min_min_fee!());
    config.set_min_fee(config_constants::max_min_fee!());
    assert_eq!(config.min_fee(), config_constants::max_min_fee!());
    config.set_max_entry_probability(config_constants::max_max_entry_probability!());
    assert_eq!(config.max_entry_probability(), config_constants::max_max_entry_probability!());
    config.set_min_entry_probability(config_constants::max_min_entry_probability!() - RAW_UNIT);
    assert_eq!(
        config.min_entry_probability(),
        config_constants::max_min_entry_probability!() - RAW_UNIT,
    );
    config.set_min_entry_probability(config_constants::min_min_entry_probability!());
    assert_eq!(config.min_entry_probability(), config_constants::min_min_entry_probability!());
    config.set_max_entry_probability(config_constants::min_min_entry_probability!() + RAW_UNIT);
    assert_eq!(
        config.max_entry_probability(),
        config_constants::min_min_entry_probability!() + RAW_UNIT,
    );
    config.set_expiry_fee_window_ms(config_constants::min_expiry_fee_window_ms!());
    assert_eq!(config.expiry_fee_window_ms(), config_constants::min_expiry_fee_window_ms!());
    config.set_expiry_fee_window_ms(config_constants::max_expiry_fee_window_ms!());
    assert_eq!(config.expiry_fee_window_ms(), config_constants::max_expiry_fee_window_ms!());
    config.set_expiry_fee_max_multiplier(config_constants::min_expiry_fee_max_multiplier!());
    assert_eq!(
        config.expiry_fee_max_multiplier(),
        config_constants::min_expiry_fee_max_multiplier!(),
    );
    config.set_expiry_fee_max_multiplier(config_constants::max_expiry_fee_max_multiplier!());
    assert_eq!(
        config.expiry_fee_max_multiplier(),
        config_constants::max_expiry_fee_max_multiplier!(),
    );
    config.set_no_leverage_window_ms(config_constants::min_no_leverage_window_ms!());
    assert_eq!(config.no_leverage_window_ms(), config_constants::min_no_leverage_window_ms!());
    config.set_no_leverage_window_ms(config_constants::max_no_leverage_window_ms!());
    assert_eq!(config.no_leverage_window_ms(), config_constants::max_no_leverage_window_ms!());
    destroy(config);
}
