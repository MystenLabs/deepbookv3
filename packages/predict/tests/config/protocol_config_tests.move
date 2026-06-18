// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Regression coverage for per-expiry mint pause after relocation from
/// `ProtocolConfig` to `ExpiryMarket`.
#[test_only]
module deepbook_predict::protocol_config_tests;

use deepbook_predict::{flow_test_helpers as helpers, protocol_config, test_constants, test_helpers};

#[test]
fun expiry_market_mint_pause_defaults_false_and_toggles() {
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    let (pyth, bs, oracle_registry, vault, mut market, config) = fx.take_market(expiry_id);

    assert!(!market.mint_paused());
    fx.set_expiry_mint_paused(&mut market, &config, true);
    assert!(market.mint_paused());
    fx.set_expiry_mint_paused(&mut market, &config, false);
    assert!(!market.mint_paused());

    helpers::return_market(pyth, bs, oracle_registry, vault, market, config);
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
