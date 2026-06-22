// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::pricing_config_tests;

use deepbook_predict::{config_constants, pricing_config};
use std::unit_test::{assert_eq, destroy};

const VALID_PYTH_SPOT_FRESHNESS_MS: u64 = 5_000;
const VALID_BLOCK_SCHOLES_SURFACE_FRESHNESS_MS: u64 = 4_000;
const FRESHNESS_ABOVE_MAX: u64 = 60_001;

// === Construction and getters ===

#[test]
fun defaults_match_config_constants() {
    let config = pricing_config::new();
    assert_eq!(
        config.pyth_spot_freshness_ms(),
        config_constants::default_pyth_spot_freshness_ms!(),
    );
    assert_eq!(
        config.block_scholes_surface_freshness_ms(),
        config_constants::default_block_scholes_surface_freshness_ms!(),
    );
    destroy(config);
}

// === set_pyth_spot_freshness_ms ===

#[test]
fun set_pyth_spot_freshness_ms_updates() {
    let mut config = pricing_config::new();
    config.set_pyth_spot_freshness_ms(VALID_PYTH_SPOT_FRESHNESS_MS);
    assert_eq!(config.pyth_spot_freshness_ms(), VALID_PYTH_SPOT_FRESHNESS_MS);
    destroy(config);
}

#[test]
fun set_pyth_spot_freshness_ms_accepts_endpoints() {
    let mut config = pricing_config::new();
    config.set_pyth_spot_freshness_ms(1);
    assert_eq!(config.pyth_spot_freshness_ms(), 1);
    config.set_pyth_spot_freshness_ms(60_000);
    assert_eq!(config.pyth_spot_freshness_ms(), 60_000);
    destroy(config);
}

#[test, expected_failure(abort_code = config_constants::EInvalidPythSpotFreshnessMs)]
fun set_pyth_spot_freshness_ms_zero_aborts() {
    let mut config = pricing_config::new();
    config.set_pyth_spot_freshness_ms(0);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidPythSpotFreshnessMs)]
fun set_pyth_spot_freshness_ms_above_max_aborts() {
    let mut config = pricing_config::new();
    config.set_pyth_spot_freshness_ms(FRESHNESS_ABOVE_MAX);
    abort 999
}

// === set_block_scholes_surface_freshness_ms ===

#[test]
fun set_block_scholes_surface_freshness_ms_updates() {
    let mut config = pricing_config::new();
    config.set_block_scholes_surface_freshness_ms(VALID_BLOCK_SCHOLES_SURFACE_FRESHNESS_MS);
    assert_eq!(
        config.block_scholes_surface_freshness_ms(),
        VALID_BLOCK_SCHOLES_SURFACE_FRESHNESS_MS,
    );
    destroy(config);
}

#[test]
fun set_block_scholes_surface_freshness_ms_accepts_endpoints() {
    let mut config = pricing_config::new();
    config.set_block_scholes_surface_freshness_ms(1);
    assert_eq!(config.block_scholes_surface_freshness_ms(), 1);
    config.set_block_scholes_surface_freshness_ms(60_000);
    assert_eq!(config.block_scholes_surface_freshness_ms(), 60_000);
    destroy(config);
}

#[test, expected_failure(abort_code = config_constants::EInvalidBlockScholesSurfaceFreshnessMs)]
fun set_block_scholes_surface_freshness_ms_zero_aborts() {
    let mut config = pricing_config::new();
    config.set_block_scholes_surface_freshness_ms(0);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidBlockScholesSurfaceFreshnessMs)]
fun set_block_scholes_surface_freshness_ms_above_max_aborts() {
    let mut config = pricing_config::new();
    config.set_block_scholes_surface_freshness_ms(FRESHNESS_ABOVE_MAX);
    abort 999
}
