// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::risk_config_tests;

use deepbook_predict::{constants, risk_config};
use std::unit_test::{assert_eq, destroy};

// === new() defaults ===

#[test]
fun new_returns_correct_default() {
    let config = risk_config::new();
    assert_eq!(config.max_total_exposure_pct(), constants::default_max_total_exposure_pct!());
    destroy(config);
}

// === set_max_total_exposure_pct ===

#[test]
fun set_max_total_exposure_pct_valid_value() {
    let mut config = risk_config::new();
    config.set_max_total_exposure_pct(500_000_000);
    assert_eq!(config.max_total_exposure_pct(), 500_000_000);
    destroy(config);
}

#[test]
fun set_max_total_exposure_pct_lower_boundary() {
    let mut config = risk_config::new();
    config.set_max_total_exposure_pct(1);
    assert_eq!(config.max_total_exposure_pct(), 1);
    destroy(config);
}

#[test]
fun set_max_total_exposure_pct_upper_boundary() {
    let mut config = risk_config::new();
    config.set_max_total_exposure_pct(constants::float_scaling!());
    assert_eq!(config.max_total_exposure_pct(), constants::float_scaling!());
    destroy(config);
}

#[test, expected_failure(abort_code = risk_config::EExceedsMaxPct)]
fun set_max_total_exposure_pct_zero_aborts() {
    let mut config = risk_config::new();
    config.set_max_total_exposure_pct(0);

    abort 999
}

#[test, expected_failure(abort_code = risk_config::EExceedsMaxPct)]
fun set_max_total_exposure_pct_exceeds_max_aborts() {
    let mut config = risk_config::new();
    config.set_max_total_exposure_pct(constants::float_scaling!() + 1);

    abort 999
}
