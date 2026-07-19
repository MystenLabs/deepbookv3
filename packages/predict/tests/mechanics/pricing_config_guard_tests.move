// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Oracle freshness first-invalid guards.
#[test_only]
module deepbook_predict::mechanics_pricing_config_guard_tests;

use deepbook_predict::{config_constants, pricing_config};

const RAW_MILLISECOND: u64 = 1;

#[test, expected_failure(abort_code = config_constants::EInvalidPythSpotFreshnessMs)]
fun pyth_zero_aborts() {
    pricing_config::new().set_pyth_spot_freshness_ms(
        config_constants::min_pyth_spot_freshness_ms!() - RAW_MILLISECOND,
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidPythSpotFreshnessMs)]
fun pyth_one_above_max_aborts() {
    pricing_config::new().set_pyth_spot_freshness_ms(
        config_constants::max_pyth_spot_freshness_ms!() + RAW_MILLISECOND,
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidBlockScholesPriceFreshnessMs)]
fun block_scholes_price_zero_aborts() {
    pricing_config::new().set_block_scholes_price_freshness_ms(
        config_constants::min_block_scholes_price_freshness_ms!() - RAW_MILLISECOND,
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidBlockScholesPriceFreshnessMs)]
fun block_scholes_price_one_above_max_aborts() {
    pricing_config::new().set_block_scholes_price_freshness_ms(
        config_constants::max_block_scholes_price_freshness_ms!() + RAW_MILLISECOND,
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidBlockScholesSVIFreshnessMs)]
fun block_scholes_svi_zero_aborts() {
    pricing_config::new().set_block_scholes_svi_freshness_ms(
        config_constants::min_block_scholes_svi_freshness_ms!() - RAW_MILLISECOND,
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidBlockScholesSVIFreshnessMs)]
fun block_scholes_svi_one_above_max_aborts() {
    pricing_config::new().set_block_scholes_svi_freshness_ms(
        config_constants::max_block_scholes_svi_freshness_ms!() + RAW_MILLISECOND,
    );
    abort 999
}
