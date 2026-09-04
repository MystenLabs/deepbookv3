// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::pricing_config_tests;

use deepbook_predict::{config_constants, pricing_config};
use std::unit_test::{assert_eq, destroy};

const VALID_PYTH_SPOT_FRESHNESS_MS: u64 = 5_000;
const VALID_BLOCK_SCHOLES_PRICE_FRESHNESS_MS: u64 = 4_000;
const VALID_BLOCK_SCHOLES_SVI_FRESHNESS_MS: u64 = 30_000;
const FRESHNESS_ABOVE_MAX: u64 = 60_001;
// The SVI window has its own, wider maximum (120s).
const SVI_FRESHNESS_ABOVE_MAX: u64 = 120_001;

// === Construction and getters ===

/// Pins the deployed default windows as literals: comparing the constructor against the same
/// macros would pass under any constant change, so a retune must consciously edit this test.
#[test]
fun defaults_are_the_deployed_values() {
    let config = pricing_config::new();
    assert_eq!(config.pyth_spot_freshness_ms(), 3_000);
    assert_eq!(config.block_scholes_price_freshness_ms(), 5_000);
    assert_eq!(config.block_scholes_svi_freshness_ms(), 60_000);
    destroy(config);
}

// === use_pyth_spot_for_forward ===

#[test]
fun default_forward_source_is_the_pyth_reanchored_basis() {
    // Asserted as the literal, not against the default macro: the ratified default
    // is that live pricing carries the Block Scholes basis on the Pyth spot, and a
    // macro-vs-getter comparison would pass whichever way that default was flipped.
    let config = pricing_config::new();
    assert!(config.use_pyth_spot_for_forward());
    destroy(config);
}

#[test]
fun set_use_pyth_spot_for_forward_toggles_both_ways() {
    let mut config = pricing_config::new();
    config.set_use_pyth_spot_for_forward(false);
    assert!(!config.use_pyth_spot_for_forward());
    config.set_use_pyth_spot_for_forward(true);
    assert!(config.use_pyth_spot_for_forward());
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

// === set_block_scholes_price_freshness_ms ===

#[test]
fun set_block_scholes_price_freshness_ms_updates() {
    let mut config = pricing_config::new();
    config.set_block_scholes_price_freshness_ms(VALID_BLOCK_SCHOLES_PRICE_FRESHNESS_MS);
    assert_eq!(config.block_scholes_price_freshness_ms(), VALID_BLOCK_SCHOLES_PRICE_FRESHNESS_MS);
    destroy(config);
}

#[test]
fun set_block_scholes_price_freshness_ms_accepts_endpoints() {
    let mut config = pricing_config::new();
    config.set_block_scholes_price_freshness_ms(1);
    assert_eq!(config.block_scholes_price_freshness_ms(), 1);
    config.set_block_scholes_price_freshness_ms(60_000);
    assert_eq!(config.block_scholes_price_freshness_ms(), 60_000);
    destroy(config);
}

#[test, expected_failure(abort_code = config_constants::EInvalidBlockScholesPriceFreshnessMs)]
fun set_block_scholes_price_freshness_ms_zero_aborts() {
    let mut config = pricing_config::new();
    config.set_block_scholes_price_freshness_ms(0);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidBlockScholesPriceFreshnessMs)]
fun set_block_scholes_price_freshness_ms_above_max_aborts() {
    let mut config = pricing_config::new();
    config.set_block_scholes_price_freshness_ms(FRESHNESS_ABOVE_MAX);
    abort 999
}

// === set_block_scholes_svi_freshness_ms ===

#[test]
fun set_block_scholes_svi_freshness_ms_updates() {
    let mut config = pricing_config::new();
    config.set_block_scholes_svi_freshness_ms(VALID_BLOCK_SCHOLES_SVI_FRESHNESS_MS);
    assert_eq!(config.block_scholes_svi_freshness_ms(), VALID_BLOCK_SCHOLES_SVI_FRESHNESS_MS);
    destroy(config);
}

#[test]
fun set_block_scholes_svi_freshness_ms_accepts_endpoints() {
    let mut config = pricing_config::new();
    config.set_block_scholes_svi_freshness_ms(1);
    assert_eq!(config.block_scholes_svi_freshness_ms(), 1);
    config.set_block_scholes_svi_freshness_ms(120_000);
    assert_eq!(config.block_scholes_svi_freshness_ms(), 120_000);
    destroy(config);
}

#[test, expected_failure(abort_code = config_constants::EInvalidBlockScholesSVIFreshnessMs)]
fun set_block_scholes_svi_freshness_ms_zero_aborts() {
    let mut config = pricing_config::new();
    config.set_block_scholes_svi_freshness_ms(0);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidBlockScholesSVIFreshnessMs)]
fun set_block_scholes_svi_freshness_ms_above_max_aborts() {
    let mut config = pricing_config::new();
    config.set_block_scholes_svi_freshness_ms(SVI_FRESHNESS_ABOVE_MAX);
    abort 999
}
