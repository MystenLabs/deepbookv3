// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Regression coverage for per-expiry mint pause after relocation from
/// `ProtocolConfig` to `ExpiryMarket`.
#[test_only]
module deepbook_predict::protocol_config_tests;

use deepbook_predict::{flow_test_helpers as helpers, test_constants};

#[test]
fun expiry_market_mint_pause_defaults_false_and_toggles() {
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    let (pyth, bs, vault, mut market, config) = fx.take_market(expiry_id);

    assert!(!market.mint_paused());
    fx.set_expiry_mint_paused(&mut market, true);
    assert!(market.mint_paused());
    fx.set_expiry_mint_paused(&mut market, false);
    assert!(!market.mint_paused());

    helpers::return_market(pyth, bs, vault, market, config);
    fx.finish();
}
