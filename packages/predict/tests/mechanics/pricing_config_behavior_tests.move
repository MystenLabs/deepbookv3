// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Oracle freshness defaults and accepted endpoint writes.
#[test_only]
module deepbook_predict::mechanics_pricing_config_behavior_tests;

use deepbook_predict::{config_constants, pricing_config};
use std::unit_test::{assert_eq, destroy};

#[test]
fun defaults_match_owned_policy_constants() {
    let config = pricing_config::new();
    assert_eq!(
        config.pyth_spot_freshness_ms(),
        config_constants::default_pyth_spot_freshness_ms!(),
    );
    assert_eq!(
        config.block_scholes_price_freshness_ms(),
        config_constants::default_block_scholes_price_freshness_ms!(),
    );
    assert_eq!(
        config.block_scholes_svi_freshness_ms(),
        config_constants::default_block_scholes_svi_freshness_ms!(),
    );
    destroy(config);
}

#[test]
fun every_freshness_setter_accepts_both_endpoints() {
    let mut config = pricing_config::new();
    config.set_pyth_spot_freshness_ms(config_constants::min_pyth_spot_freshness_ms!());
    assert_eq!(config.pyth_spot_freshness_ms(), config_constants::min_pyth_spot_freshness_ms!());
    config.set_block_scholes_price_freshness_ms(
        config_constants::min_block_scholes_price_freshness_ms!(),
    );
    assert_eq!(
        config.block_scholes_price_freshness_ms(),
        config_constants::min_block_scholes_price_freshness_ms!(),
    );
    config.set_block_scholes_svi_freshness_ms(
        config_constants::min_block_scholes_svi_freshness_ms!(),
    );
    assert_eq!(
        config.block_scholes_svi_freshness_ms(),
        config_constants::min_block_scholes_svi_freshness_ms!(),
    );
    config.set_pyth_spot_freshness_ms(config_constants::max_pyth_spot_freshness_ms!());
    assert_eq!(config.pyth_spot_freshness_ms(), config_constants::max_pyth_spot_freshness_ms!());
    config.set_block_scholes_price_freshness_ms(
        config_constants::max_block_scholes_price_freshness_ms!(),
    );
    assert_eq!(
        config.block_scholes_price_freshness_ms(),
        config_constants::max_block_scholes_price_freshness_ms!(),
    );
    config.set_block_scholes_svi_freshness_ms(
        config_constants::max_block_scholes_svi_freshness_ms!(),
    );
    assert_eq!(
        config.block_scholes_svi_freshness_ms(),
        config_constants::max_block_scholes_svi_freshness_ms!(),
    );
    destroy(config);
}
