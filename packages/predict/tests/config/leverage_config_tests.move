// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::leverage_config_tests;

use deepbook_predict::{config_constants, constants::float_scaling as float, leverage_config};
use std::unit_test::{assert_eq, destroy};

// === Construction and getter ===

#[test]
fun default_matches_config_constants() {
    let config = leverage_config::new();
    assert_eq!(
        config.max_expiry_floor_premium(),
        config_constants::default_max_expiry_floor_premium!(),
    );
    destroy(config);
}

// === set_template_max_expiry_floor_premium ===

#[test]
fun set_updates_value() {
    let mut config = leverage_config::new();
    config.set_template_max_expiry_floor_premium(300_000_000);
    assert_eq!(config.max_expiry_floor_premium(), 300_000_000);
    destroy(config);
}

#[test]
fun set_accepts_zero_and_float() {
    // min = 0, max = float!(); both endpoints are valid.
    let mut config = leverage_config::new();

    config.set_template_max_expiry_floor_premium(0);
    assert_eq!(config.max_expiry_floor_premium(), 0);

    config.set_template_max_expiry_floor_premium(float!());
    assert_eq!(config.max_expiry_floor_premium(), float!());

    destroy(config);
}

#[test, expected_failure(abort_code = config_constants::EInvalidMaxExpiryFloorPremium)]
fun set_above_float_aborts() {
    let mut config = leverage_config::new();
    config.set_template_max_expiry_floor_premium(float!() + 1);
    abort 999
}
