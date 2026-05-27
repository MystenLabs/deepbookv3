// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::pricing_config_tests;

use deepbook_predict::{config_constants, constants::float_scaling as float, pricing_config};
use std::unit_test::{assert_eq, destroy};

// Values inside the config_constants envelope for each setter.
const VALID_BASE_FEE: u64 = 30_000_000;
const VALID_MIN_FEE: u64 = 2_000_000;
const VALID_PYTH_SPOT_FRESHNESS_MS: u64 = 5_000;
const VALID_BLOCK_SCHOLES_PRICES_FRESHNESS_MS: u64 = 4_000;
const VALID_BLOCK_SCHOLES_SVI_FRESHNESS_MS: u64 = 30_000;
const FRESHNESS_ABOVE_MAX: u64 = 60_001;
const NEW_MIN_ASK_PRICE: u64 = 20_000_000;
const NEW_MAX_ASK_PRICE: u64 = 980_000_000;

// === Construction and getters ===

#[test]
fun defaults_match_config_constants() {
    let config = pricing_config::new();
    assert_eq!(config.base_fee(), config_constants::default_base_fee!());
    assert_eq!(config.min_fee(), config_constants::default_min_fee!());
    assert_eq!(config.min_ask_price(), config_constants::default_min_ask_price!());
    assert_eq!(config.max_ask_price(), config_constants::default_max_ask_price!());
    assert_eq!(
        config.pyth_spot_freshness_ms(),
        config_constants::default_pyth_spot_freshness_ms!(),
    );
    assert_eq!(
        config.block_scholes_prices_freshness_ms(),
        config_constants::default_block_scholes_prices_freshness_ms!(),
    );
    assert_eq!(
        config.block_scholes_svi_freshness_ms(),
        config_constants::default_block_scholes_svi_freshness_ms!(),
    );
    destroy(config);
}

// === set_base_fee ===

#[test]
fun set_base_fee_updates() {
    let mut config = pricing_config::new();
    config.set_base_fee(VALID_BASE_FEE);
    assert_eq!(config.base_fee(), VALID_BASE_FEE);
    destroy(config);
}

#[test]
fun set_base_fee_accepts_endpoints() {
    let mut config = pricing_config::new();
    config.set_base_fee(1);
    assert_eq!(config.base_fee(), 1);
    config.set_base_fee(float!());
    assert_eq!(config.base_fee(), float!());
    destroy(config);
}

#[test, expected_failure(abort_code = config_constants::EInvalidBaseFee)]
fun set_base_fee_zero_aborts() {
    let mut config = pricing_config::new();
    config.set_base_fee(0);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidBaseFee)]
fun set_base_fee_above_float_aborts() {
    let mut config = pricing_config::new();
    config.set_base_fee(float!() + 1);
    abort 999
}

// === set_min_fee ===

#[test]
fun set_min_fee_updates() {
    let mut config = pricing_config::new();
    config.set_min_fee(VALID_MIN_FEE);
    assert_eq!(config.min_fee(), VALID_MIN_FEE);
    destroy(config);
}

#[test]
fun set_min_fee_accepts_endpoints() {
    // Envelope = [0, float!()].
    let mut config = pricing_config::new();
    config.set_min_fee(0);
    assert_eq!(config.min_fee(), 0);
    config.set_min_fee(float!());
    assert_eq!(config.min_fee(), float!());
    destroy(config);
}

#[test, expected_failure(abort_code = config_constants::EInvalidMinFee)]
fun set_min_fee_above_float_aborts() {
    let mut config = pricing_config::new();
    config.set_min_fee(float!() + 1);
    abort 999
}

// === set_min_ask_price / set_max_ask_price ===

#[test]
fun set_ask_prices_round_trip() {
    let mut config = pricing_config::new();

    config.set_min_ask_price(NEW_MIN_ASK_PRICE);
    config.set_max_ask_price(NEW_MAX_ASK_PRICE);

    assert_eq!(config.min_ask_price(), NEW_MIN_ASK_PRICE);
    assert_eq!(config.max_ask_price(), NEW_MAX_ASK_PRICE);
    destroy(config);
}

#[test, expected_failure(abort_code = config_constants::EInvalidMinAskPrice)]
fun set_min_ask_price_above_envelope_aborts() {
    // Envelope max = float!()-1; equality is out of range.
    let mut config = pricing_config::new();
    config.set_min_ask_price(float!());
    abort 999
}

#[test, expected_failure(abort_code = pricing_config::EInvalidAskBound)]
fun set_min_ask_price_equal_to_max_aborts() {
    // Cross-field invariant: min < max strictly.
    let mut config = pricing_config::new();
    let current_max = config.max_ask_price();
    config.set_min_ask_price(current_max);
    abort 999
}

#[test, expected_failure(abort_code = pricing_config::EInvalidAskBound)]
fun set_min_ask_price_above_current_max_aborts() {
    let mut config = pricing_config::new();
    let current_max = config.max_ask_price();
    config.set_min_ask_price(current_max + 1);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidMaxAskPrice)]
fun set_max_ask_price_above_envelope_aborts() {
    let mut config = pricing_config::new();
    config.set_max_ask_price(float!());
    abort 999
}

#[test, expected_failure(abort_code = pricing_config::EInvalidAskBound)]
fun set_max_ask_price_equal_to_min_aborts() {
    let mut config = pricing_config::new();
    let current_min = config.min_ask_price();
    config.set_max_ask_price(current_min);
    abort 999
}

#[test, expected_failure(abort_code = pricing_config::EInvalidAskBound)]
fun set_max_ask_price_below_current_min_aborts() {
    let mut config = pricing_config::new();
    let current_min = config.min_ask_price();
    config.set_max_ask_price(current_min - 1);
    abort 999
}

// === set_pyth_spot_freshness_ms ===

#[test]
fun set_pyth_spot_freshness_ms_updates() {
    let mut config = pricing_config::new();
    config.set_pyth_spot_freshness_ms(VALID_PYTH_SPOT_FRESHNESS_MS);
    assert_eq!(config.pyth_spot_freshness_ms(), VALID_PYTH_SPOT_FRESHNESS_MS);
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

// === set_block_scholes_prices_freshness_ms ===

#[test]
fun set_block_scholes_prices_freshness_ms_updates() {
    let mut config = pricing_config::new();
    config.set_block_scholes_prices_freshness_ms(VALID_BLOCK_SCHOLES_PRICES_FRESHNESS_MS);
    assert_eq!(config.block_scholes_prices_freshness_ms(), VALID_BLOCK_SCHOLES_PRICES_FRESHNESS_MS);
    destroy(config);
}

#[test, expected_failure(abort_code = config_constants::EInvalidBlockScholesPricesFreshnessMs)]
fun set_block_scholes_prices_freshness_ms_zero_aborts() {
    let mut config = pricing_config::new();
    config.set_block_scholes_prices_freshness_ms(0);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidBlockScholesPricesFreshnessMs)]
fun set_block_scholes_prices_freshness_ms_above_max_aborts() {
    let mut config = pricing_config::new();
    config.set_block_scholes_prices_freshness_ms(FRESHNESS_ABOVE_MAX);
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

#[test, expected_failure(abort_code = config_constants::EInvalidBlockScholesSVIFreshnessMs)]
fun set_block_scholes_svi_freshness_ms_zero_aborts() {
    let mut config = pricing_config::new();
    config.set_block_scholes_svi_freshness_ms(0);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidBlockScholesSVIFreshnessMs)]
fun set_block_scholes_svi_freshness_ms_above_max_aborts() {
    let mut config = pricing_config::new();
    config.set_block_scholes_svi_freshness_ms(FRESHNESS_ABOVE_MAX);
    abort 999
}
