// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::risk_config_tests;

use deepbook_predict::{config_constants, constants::float_scaling as float, risk_config};
use std::unit_test::{assert_eq, destroy};

// Allocation envelope is [50e9, 250e9] — well inside u64.
const VALID_ALLOCATION: u64 = 100_000_000_000;
const ALLOCATION_BELOW_MIN: u64 = 49_999_999_999;
const ALLOCATION_ABOVE_MAX: u64 = 250_000_000_001;

// Default grow / shrink utilization thresholds are 800e6 / 300e6.
const DEFAULT_GROW_THRESHOLD: u64 = 800_000_000;
const DEFAULT_SHRINK_THRESHOLD: u64 = 300_000_000;

// === Construction and getters ===

#[test]
fun defaults_match_config_constants() {
    let config = risk_config::new();
    assert_eq!(
        config.max_total_exposure_pct(),
        config_constants::default_max_total_exposure_pct!(),
    );
    assert_eq!(config.expiry_allocation(), config_constants::default_allocation!());
    assert_eq!(
        config.grow_utilization_threshold(),
        config_constants::default_grow_utilization_threshold!(),
    );
    assert_eq!(
        config.shrink_utilization_threshold(),
        config_constants::default_shrink_utilization_threshold!(),
    );
    assert_eq!(config.grow_factor(), config_constants::default_grow_factor!());
    assert_eq!(config.shrink_factor(), config_constants::default_shrink_factor!());
    destroy(config);
}

// === set_max_total_exposure_pct ===

#[test]
fun set_max_total_exposure_pct_updates() {
    let mut config = risk_config::new();
    config.set_max_total_exposure_pct(500_000_000);
    assert_eq!(config.max_total_exposure_pct(), 500_000_000);
    destroy(config);
}

#[test]
fun set_max_total_exposure_pct_accepts_endpoints() {
    // Envelope = [1, float!()].
    let mut config = risk_config::new();
    config.set_max_total_exposure_pct(1);
    assert_eq!(config.max_total_exposure_pct(), 1);
    config.set_max_total_exposure_pct(float!());
    assert_eq!(config.max_total_exposure_pct(), float!());
    destroy(config);
}

#[test, expected_failure(abort_code = config_constants::EInvalidMaxTotalExposurePct)]
fun set_max_total_exposure_pct_zero_aborts() {
    let mut config = risk_config::new();
    config.set_max_total_exposure_pct(0);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidMaxTotalExposurePct)]
fun set_max_total_exposure_pct_above_float_aborts() {
    let mut config = risk_config::new();
    config.set_max_total_exposure_pct(float!() + 1);
    abort 999
}

// === set_expiry_allocation ===

#[test]
fun set_expiry_allocation_updates() {
    let mut config = risk_config::new();
    config.set_expiry_allocation(VALID_ALLOCATION);
    assert_eq!(config.expiry_allocation(), VALID_ALLOCATION);
    destroy(config);
}

#[test]
fun set_expiry_allocation_accepts_endpoints() {
    // Envelope = [50e9, 250e9]. Endpoints are exactly where off-by-one bounds
    // bugs hide — assert both pass.
    let mut config = risk_config::new();
    config.set_expiry_allocation(50_000_000_000);
    assert_eq!(config.expiry_allocation(), 50_000_000_000);
    config.set_expiry_allocation(250_000_000_000);
    assert_eq!(config.expiry_allocation(), 250_000_000_000);
    destroy(config);
}

#[test, expected_failure(abort_code = config_constants::EInvalidExpiryAllocation)]
fun set_expiry_allocation_below_min_aborts() {
    let mut config = risk_config::new();
    config.set_expiry_allocation(ALLOCATION_BELOW_MIN);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidExpiryAllocation)]
fun set_expiry_allocation_above_max_aborts() {
    let mut config = risk_config::new();
    config.set_expiry_allocation(ALLOCATION_ABOVE_MAX);
    abort 999
}

// === set_grow_utilization_threshold ===

#[test]
fun set_grow_utilization_threshold_updates() {
    let mut config = risk_config::new();
    config.set_grow_utilization_threshold(900_000_000);
    assert_eq!(config.grow_utilization_threshold(), 900_000_000);
    destroy(config);
}

#[test]
fun set_grow_utilization_threshold_equal_to_shrink_is_allowed() {
    // Cross-field invariant is `grow >= shrink`; equal is the boundary.
    let mut config = risk_config::new();
    config.set_grow_utilization_threshold(DEFAULT_SHRINK_THRESHOLD);
    assert_eq!(config.grow_utilization_threshold(), DEFAULT_SHRINK_THRESHOLD);
    destroy(config);
}

#[test]
fun set_grow_utilization_threshold_zero_after_shrink_zeroed() {
    // 0 is in the envelope but normally blocked by the cross-field check
    // against the default shrink threshold (300e6). Drop shrink to 0 first
    // and 0 becomes a valid grow value.
    let mut config = risk_config::new();
    config.set_shrink_utilization_threshold(0);
    config.set_grow_utilization_threshold(0);
    assert_eq!(config.grow_utilization_threshold(), 0);
    destroy(config);
}

#[test, expected_failure(abort_code = config_constants::EInvalidGrowUtilizationThreshold)]
fun set_grow_utilization_threshold_above_envelope_aborts() {
    // Envelope max = float!().
    let mut config = risk_config::new();
    config.set_grow_utilization_threshold(float!() + 1);
    abort 999
}

#[test, expected_failure(abort_code = risk_config::EInvalidResizeThresholds)]
fun set_grow_utilization_threshold_below_shrink_aborts() {
    // Default shrink = 300e6; a grow value strictly below that violates the
    // cross-field invariant.
    let mut config = risk_config::new();
    config.set_grow_utilization_threshold(DEFAULT_SHRINK_THRESHOLD - 1);
    abort 999
}

// === set_shrink_utilization_threshold ===

#[test]
fun set_shrink_utilization_threshold_updates() {
    let mut config = risk_config::new();
    config.set_shrink_utilization_threshold(200_000_000);
    assert_eq!(config.shrink_utilization_threshold(), 200_000_000);
    destroy(config);
}

#[test]
fun set_shrink_utilization_threshold_equal_to_grow_is_allowed() {
    let mut config = risk_config::new();
    config.set_shrink_utilization_threshold(DEFAULT_GROW_THRESHOLD);
    assert_eq!(config.shrink_utilization_threshold(), DEFAULT_GROW_THRESHOLD);
    destroy(config);
}

#[test, expected_failure(abort_code = config_constants::EInvalidShrinkUtilizationThreshold)]
fun set_shrink_utilization_threshold_above_envelope_aborts() {
    let mut config = risk_config::new();
    config.set_shrink_utilization_threshold(float!() + 1);
    abort 999
}

#[test, expected_failure(abort_code = risk_config::EInvalidResizeThresholds)]
fun set_shrink_utilization_threshold_above_grow_aborts() {
    // Default grow = 800e6; a shrink value strictly above that violates the
    // cross-field invariant.
    let mut config = risk_config::new();
    config.set_shrink_utilization_threshold(DEFAULT_GROW_THRESHOLD + 1);
    abort 999
}

// === set_grow_factor ===

#[test]
fun set_grow_factor_updates() {
    let mut config = risk_config::new();
    config.set_grow_factor(3 * float!());
    assert_eq!(config.grow_factor(), 3 * float!());
    destroy(config);
}

#[test]
fun set_grow_factor_accepts_endpoints() {
    // Envelope = [float!()+1, 10*float!()].
    let mut config = risk_config::new();
    config.set_grow_factor(float!() + 1);
    assert_eq!(config.grow_factor(), float!() + 1);
    config.set_grow_factor(10 * float!());
    assert_eq!(config.grow_factor(), 10 * float!());
    destroy(config);
}

#[test, expected_failure(abort_code = config_constants::EInvalidGrowFactor)]
fun set_grow_factor_zero_aborts() {
    // Far below min (which is float!() + 1) — exercises the under-flow path
    // distinctly from the float!() boundary.
    let mut config = risk_config::new();
    config.set_grow_factor(0);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidGrowFactor)]
fun set_grow_factor_equal_to_float_aborts() {
    // Boundary: grow_factor must be strictly greater than 1.0.
    let mut config = risk_config::new();
    config.set_grow_factor(float!());
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidGrowFactor)]
fun set_grow_factor_above_envelope_aborts() {
    let mut config = risk_config::new();
    config.set_grow_factor(10 * float!() + 1);
    abort 999
}

// === set_shrink_factor ===

#[test]
fun set_shrink_factor_updates() {
    let mut config = risk_config::new();
    config.set_shrink_factor(400_000_000);
    assert_eq!(config.shrink_factor(), 400_000_000);
    destroy(config);
}

#[test]
fun set_shrink_factor_accepts_endpoints() {
    // Envelope = [0, float!()-1].
    let mut config = risk_config::new();
    config.set_shrink_factor(0);
    assert_eq!(config.shrink_factor(), 0);
    config.set_shrink_factor(float!() - 1);
    assert_eq!(config.shrink_factor(), float!() - 1);
    destroy(config);
}

#[test, expected_failure(abort_code = config_constants::EInvalidShrinkFactor)]
fun set_shrink_factor_equal_to_float_aborts() {
    // Boundary: shrink_factor must be strictly less than 1.0.
    let mut config = risk_config::new();
    config.set_shrink_factor(float!());
    abort 999
}
