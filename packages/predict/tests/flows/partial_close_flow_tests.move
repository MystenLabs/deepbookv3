// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// End-to-end coverage for consecutive partial live closes. Each close replaces
/// the account position and preserves market backing for the remaining quantity.
#[test_only]
module deepbook_predict::partial_close_flow_tests;

use deepbook_predict::{constants, flow_test_helpers as helpers, test_constants};

const FIRST_CLOSE: u64 = 300_000_000;
const SECOND_CLOSE: u64 = 200_000_000;

#[test]
fun consecutive_partial_closes_replace_position_and_preserve_backing() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let order_id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );

    let closes = vector[FIRST_CLOSE, SECOND_CLOSE];
    let mut survivor_id = order_id;
    let mut i = 0;
    while (i < closes.length()) {
        fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
        let replacement = fx.redeem_live_bundle(
            &mut market,
            &mut account,
            survivor_id,
            closes[i],
        );
        survivor_id = replacement.destroy_some();
        assert!(helpers::has_position_bundle(&account, expiry_id, survivor_id));
        helpers::assert_market_backed_bundle(&market);
        i = i + 1;
    };

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}
