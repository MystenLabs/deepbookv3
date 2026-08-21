// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// End-to-end coverage for live partial-close replacement chains and their
/// terminal settlement. Pins position replacement, market backing, terminal
/// liability release, and stable-root event attribution.
#[test_only]
module deepbook_predict::partial_close_flow_tests;

use deepbook_predict::{constants, flow_test_helpers as helpers, order_events, test_constants};
use dusdc::dusdc::DUSDC;
use std::{bcs, unit_test::assert_eq};
use sui::event;

const FIRST_CLOSE: u64 = 300_000_000;
const SECOND_CLOSE: u64 = 200_000_000;
const REMAINING_AFTER_FIRST_CLOSE: u64 = 700_000_000;
const ONE_EVENT: u64 = 1;
const ZERO_LIABILITY: u64 = 0;

public struct ExpectedSettledOrderRedeemed has copy, drop {
    expiry_market_id: ID,
    account_id: ID,
    order_id: u256,
    position_root_id: u256,
    owner: address,
    payout_amount: u64,
    onchain_timestamp_ms: u64,
}

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

#[test]
fun partial_close_replacement_redeems_settled_under_original_root() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let account_id = helpers::account_id_bundle(&account);

    let original_order_id = fx.mint_bundle(
        &mut market,
        &mut account,
        constants::neg_inf!(),
        helpers::strike_tick(),
        test_constants::mint_quantity(),
    );
    fx.advance_live_oracle_bundle(&mut market, test_constants::default_live_price());
    let replacement_order_id = fx
        .redeem_live_bundle(
            &mut market,
            &mut account,
            original_order_id,
            FIRST_CLOSE,
        )
        .destroy_some();
    assert!(!helpers::has_position_bundle(&account, expiry_id, original_order_id));
    assert!(helpers::has_position_bundle(&account, expiry_id, replacement_order_id));

    fx.set_clock_for_testing(test_constants::short_expiry_ms());
    fx.insert_exact_settlement_spot_bundle(&mut market, test_constants::default_live_price());
    assert_eq!(fx.try_settle_bundle(&mut market), true);
    assert_eq!(helpers::market(&market).payout_liability(), REMAINING_AFTER_FIRST_CLOSE);
    assert_eq!(
        helpers::settled_order_payout_bundle(&market, replacement_order_id),
        REMAINING_AFTER_FIRST_CLOSE,
    );

    let balance_before_redeem = fx.account_balance_bundle<DUSDC>(&account);
    fx.redeem_settled_bundle(&mut market, &mut account, replacement_order_id);
    assert_eq!(
        fx.account_balance_bundle<DUSDC>(&account),
        balance_before_redeem + REMAINING_AFTER_FIRST_CLOSE,
    );
    assert_eq!(helpers::market(&market).payout_liability(), ZERO_LIABILITY);
    assert!(!helpers::has_position_bundle(&account, expiry_id, replacement_order_id));

    let events = event::events_by_type<order_events::SettledOrderRedeemed>();
    assert_eq!(events.length(), ONE_EVENT);
    let expected = ExpectedSettledOrderRedeemed {
        expiry_market_id: expiry_id,
        account_id,
        order_id: replacement_order_id,
        position_root_id: original_order_id,
        owner: helpers::owner(&trader),
        payout_amount: REMAINING_AFTER_FIRST_CLOSE,
        onchain_timestamp_ms: test_constants::short_expiry_ms(),
    };
    assert_eq!(bcs::to_bytes(&events[0]), bcs::to_bytes(&expected));

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}
