// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Regression coverage for cross-cutting `ProtocolConfig` gates.
#[test_only]
module deepbook_predict::protocol_config_tests;

use deepbook_predict::{
    config_constants,
    flow_test_helpers as helpers,
    protocol_config,
    test_constants,
    test_helpers
};

#[test]
fun expiry_market_mint_pause_defaults_false_and_toggles() {
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    let mut market = fx.take_market_bundle(expiry_id);

    assert!(!helpers::market(&market).mint_paused());
    fx.set_expiry_mint_paused_bundle(&mut market, true);
    assert!(helpers::market(&market).mint_paused());
    fx.set_expiry_mint_paused_bundle(&mut market, false);
    assert!(!helpers::market(&market).mint_paused());

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test, expected_failure(abort_code = protocol_config::EVersionWatermarkNotAdvanced)]
fun bump_version_watermark_at_current_version_aborts() {
    // At genesis the watermark already equals the running `current_version!()`, so
    // `bump_version_watermark` cannot advance the floor and aborts.
    let (_scenario, _reg, mut config, admin_cap) = test_helpers::begin_registry_test();
    config.bump_version_watermark(&admin_cap);
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EValuationInProgress)]
fun set_pyth_spot_freshness_during_valuation_aborts() {
    let (_scenario, _reg, mut config, admin_cap) = test_helpers::begin_registry_test();
    config.begin_valuation();
    config.set_pyth_spot_freshness_ms(
        &admin_cap,
        config_constants::min_pyth_spot_freshness_ms!(),
    );
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EValuationInProgress)]
fun set_block_scholes_price_freshness_during_valuation_aborts() {
    let (_scenario, _reg, mut config, admin_cap) = test_helpers::begin_registry_test();
    config.begin_valuation();
    config.set_block_scholes_price_freshness_ms(
        &admin_cap,
        config_constants::min_block_scholes_price_freshness_ms!(),
    );
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EValuationInProgress)]
fun set_block_scholes_svi_freshness_during_valuation_aborts() {
    let (_scenario, _reg, mut config, admin_cap) = test_helpers::begin_registry_test();
    config.begin_valuation();
    config.set_block_scholes_svi_freshness_ms(
        &admin_cap,
        config_constants::min_block_scholes_svi_freshness_ms!(),
    );
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EValuationInProgress)]
fun set_protocol_reserve_profit_share_during_valuation_aborts() {
    let (_scenario, _reg, mut config, admin_cap) = test_helpers::begin_registry_test();
    config.begin_valuation();
    config.set_protocol_reserve_profit_share(
        &admin_cap,
        config_constants::min_protocol_reserve_profit_share!(),
    );
    abort 999
}
