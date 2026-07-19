// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Strike-exposure config snapshot independence across every stored field.
#[test_only]
module deepbook_predict::structure_strike_exposure_config_behavior_tests;

use deepbook_predict::{config_constants, strike_exposure_config};
use std::unit_test::{assert_eq, destroy};

const MUTATED_LIQUIDATION_LTV: u64 = 500_000_000;
const MUTATED_MAX_ADMISSION_LEVERAGE: u64 = 2_000_000_000;
const MUTATED_BACKING_BUFFER_LAMBDA: u64 = 100_000_000;
const MUTATED_BASE_FEE: u64 = 10_000_000;
const MUTATED_MIN_FEE: u64 = 1_000_000;
const MUTATED_MIN_ENTRY_PROBABILITY: u64 = 20_000_000;
const MUTATED_MAX_ENTRY_PROBABILITY: u64 = 900_000_000;
const MUTATED_EXPIRY_FEE_WINDOW_MS: u64 = 300_000;
const MUTATED_EXPIRY_FEE_MAX_MULTIPLIER: u64 = 2_000_000_000;
const MUTATED_NO_LEVERAGE_WINDOW_MS: u64 = 0;

#[test]
fun snapshot_retains_all_values_after_template_mutation() {
    let mut template = strike_exposure_config::new();
    let snapshot = template.snapshot();
    template.set_liquidation_ltv(MUTATED_LIQUIDATION_LTV);
    template.set_max_admission_leverage(MUTATED_MAX_ADMISSION_LEVERAGE);
    template.set_backing_buffer_lambda(MUTATED_BACKING_BUFFER_LAMBDA);
    template.set_base_fee(MUTATED_BASE_FEE);
    template.set_min_fee(MUTATED_MIN_FEE);
    template.set_min_entry_probability(MUTATED_MIN_ENTRY_PROBABILITY);
    template.set_max_entry_probability(MUTATED_MAX_ENTRY_PROBABILITY);
    template.set_expiry_fee_window_ms(MUTATED_EXPIRY_FEE_WINDOW_MS);
    template.set_expiry_fee_max_multiplier(MUTATED_EXPIRY_FEE_MAX_MULTIPLIER);
    template.set_no_leverage_window_ms(MUTATED_NO_LEVERAGE_WINDOW_MS);
    assert_eq!(snapshot.liquidation_ltv(), config_constants::default_liquidation_ltv!());
    assert_eq!(
        snapshot.max_admission_leverage(),
        config_constants::default_max_admission_leverage!(),
    );
    assert_eq!(
        snapshot.backing_buffer_lambda(),
        config_constants::default_backing_buffer_lambda!(),
    );
    assert_eq!(snapshot.base_fee(), config_constants::default_base_fee!());
    assert_eq!(snapshot.min_fee(), config_constants::default_min_fee!());
    assert_eq!(
        snapshot.min_entry_probability(),
        config_constants::default_min_entry_probability!(),
    );
    assert_eq!(
        snapshot.max_entry_probability(),
        config_constants::default_max_entry_probability!(),
    );
    assert_eq!(snapshot.expiry_fee_window_ms(), config_constants::default_expiry_fee_window_ms!());
    assert_eq!(
        snapshot.expiry_fee_max_multiplier(),
        config_constants::default_expiry_fee_max_multiplier!(),
    );
    assert_eq!(
        snapshot.no_leverage_window_ms(),
        config_constants::default_no_leverage_window_ms!(),
    );
    destroy(snapshot);
    destroy(template);
}
