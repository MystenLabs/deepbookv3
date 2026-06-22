// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::ewma_config_tests;

use deepbook_predict::{config_constants, ewma_config};
use std::unit_test::{assert_eq, destroy};

const ALPHA_MIN: u64 = 1;
const ALPHA_MAX: u64 = 100_000_000;
const Z_SCORE_MIN: u64 = 1_000_000_000; // 1 sigma
const Z_SCORE_MAX: u64 = 10_000_000_000; // 10 sigma
const PENALTY_RATE_MAX: u64 = 2_000_000; // 20 bps

// === Construction and getters ===

#[test]
fun defaults_match_config_constants() {
    let config = ewma_config::new();

    assert_eq!(config.alpha(), config_constants::default_ewma_alpha!());
    assert_eq!(config.z_score_threshold(), config_constants::default_ewma_z_score_threshold!());
    assert_eq!(config.penalty_rate(), config_constants::default_ewma_penalty_rate!());
    assert!(!config.enabled());

    destroy(config);
}

// === set_params ===

#[test]
fun set_params_updates_all_values() {
    let mut config = ewma_config::new();

    config.set_params(ALPHA_MAX, Z_SCORE_MAX, PENALTY_RATE_MAX);

    assert_eq!(config.alpha(), ALPHA_MAX);
    assert_eq!(config.z_score_threshold(), Z_SCORE_MAX);
    assert_eq!(config.penalty_rate(), PENALTY_RATE_MAX);

    destroy(config);
}

#[test]
fun set_params_accepts_lower_boundaries() {
    let mut config = ewma_config::new();

    config.set_params(ALPHA_MIN, Z_SCORE_MIN, 0);

    assert_eq!(config.alpha(), ALPHA_MIN);
    assert_eq!(config.z_score_threshold(), Z_SCORE_MIN);
    assert_eq!(config.penalty_rate(), 0);

    destroy(config);
}

#[test, expected_failure(abort_code = config_constants::EInvalidEwmaAlpha)]
fun set_params_alpha_above_max_aborts() {
    let mut config = ewma_config::new();
    config.set_params(ALPHA_MAX + 1, Z_SCORE_MIN, 0);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidEwmaAlpha)]
fun set_params_alpha_zero_aborts() {
    let mut config = ewma_config::new();
    config.set_params(0, Z_SCORE_MIN, 0);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidEwmaZScoreThreshold)]
fun set_params_threshold_below_min_aborts() {
    let mut config = ewma_config::new();
    config.set_params(ALPHA_MIN, Z_SCORE_MIN - 1, 0);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidEwmaZScoreThreshold)]
fun set_params_threshold_above_max_aborts() {
    let mut config = ewma_config::new();
    config.set_params(ALPHA_MIN, Z_SCORE_MAX + 1, 0);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidEwmaPenaltyRate)]
fun set_params_fee_above_max_aborts() {
    let mut config = ewma_config::new();
    config.set_params(ALPHA_MIN, Z_SCORE_MIN, PENALTY_RATE_MAX + 1);
    abort 999
}

// === set_enabled ===

#[test]
fun set_enabled_toggles() {
    let mut config = ewma_config::new();

    config.set_enabled(true);
    assert!(config.enabled());

    config.set_enabled(false);
    assert!(!config.enabled());

    destroy(config);
}
