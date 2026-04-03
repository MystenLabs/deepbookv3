// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::pricing_config_tests;

use deepbook_predict::{constants, pricing_config};
use std::unit_test::{assert_eq, destroy};

const MAX_U64: u64 = 18_446_744_073_709_551_615;

// === new() defaults ===

#[test]
fun new_returns_correct_defaults() {
    let config = pricing_config::new();
    assert_eq!(config.base_spread(), constants::default_base_spread!());
    assert_eq!(config.min_spread(), constants::default_min_spread!());
    assert_eq!(config.utilization_multiplier(), constants::default_utilization_multiplier!());
    destroy(config);
}

// === set_base_spread ===

#[test]
fun set_base_spread_valid_value() {
    let mut config = pricing_config::new();
    config.set_base_spread(100_000_000);
    assert_eq!(config.base_spread(), 100_000_000);
    destroy(config);
}

#[test]
fun set_base_spread_lower_boundary() {
    let mut config = pricing_config::new();
    config.set_base_spread(1);
    assert_eq!(config.base_spread(), 1);
    destroy(config);
}

#[test]
fun set_base_spread_upper_boundary() {
    let mut config = pricing_config::new();
    config.set_base_spread(constants::float_scaling!());
    assert_eq!(config.base_spread(), constants::float_scaling!());
    destroy(config);
}

#[test, expected_failure(abort_code = pricing_config::EInvalidSpread)]
fun set_base_spread_zero_aborts() {
    let mut config = pricing_config::new();
    config.set_base_spread(0);

    abort
}

#[test, expected_failure(abort_code = pricing_config::EInvalidSpread)]
fun set_base_spread_exceeds_max_aborts() {
    let mut config = pricing_config::new();
    config.set_base_spread(constants::float_scaling!() + 1);

    abort
}

// === set_min_spread ===

#[test]
fun set_min_spread_valid_value() {
    let mut config = pricing_config::new();
    config.set_min_spread(10_000_000);
    assert_eq!(config.min_spread(), 10_000_000);
    destroy(config);
}

#[test]
fun set_min_spread_zero_is_valid() {
    let mut config = pricing_config::new();
    config.set_min_spread(0);
    assert_eq!(config.min_spread(), 0);
    destroy(config);
}

#[test]
fun set_min_spread_upper_boundary() {
    let mut config = pricing_config::new();
    config.set_min_spread(constants::float_scaling!());
    assert_eq!(config.min_spread(), constants::float_scaling!());
    destroy(config);
}

#[test, expected_failure(abort_code = pricing_config::EInvalidSpread)]
fun set_min_spread_exceeds_max_aborts() {
    let mut config = pricing_config::new();
    config.set_min_spread(constants::float_scaling!() + 1);

    abort
}

// === set_utilization_multiplier ===

#[test]
fun set_utilization_multiplier_any_value() {
    let mut config = pricing_config::new();
    config.set_utilization_multiplier(5_000_000_000);
    assert_eq!(config.utilization_multiplier(), 5_000_000_000);
    destroy(config);
}

#[test]
fun set_utilization_multiplier_zero() {
    let mut config = pricing_config::new();
    config.set_utilization_multiplier(0);
    assert_eq!(config.utilization_multiplier(), 0);
    destroy(config);
}

#[test]
fun set_utilization_multiplier_max_u64() {
    let mut config = pricing_config::new();
    config.set_utilization_multiplier(MAX_U64);
    assert_eq!(config.utilization_multiplier(), MAX_U64);
    destroy(config);
}
