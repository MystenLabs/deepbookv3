// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// `cleanup`: after settlement anyone may delete finished queue records
/// (Refunded and Closed) for their storage rebate. Open records stay until the
/// settlement payout walk closes them, and that walk counts deleted IDs as
/// visited.
#[test_only]
module deepbook_predict::cleanup_flow_tests;

use deepbook_predict::{
    expiry_market,
    flow_test_helpers as helpers,
    order_events,
    order_queue,
    queue_e3_test_helpers as e3,
    queue_test_helpers as queue,
    test_constants
};
use std::unit_test::assert_eq;
use sui::event;

const MISSING_RECORD_ID: u64 = 99;
const ONE_EVENT: u64 = 1;
const TWO_EVENTS: u64 = 2;

#[test, expected_failure(abort_code = expiry_market::EMarketNotSettled)]
fun cleanup_requires_a_settled_market() {
    let (mut fx, expiry_id, _) = queue::setup_queue_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    let mut market = fx.take_market_bundle(expiry_id);
    queue::cleanup(&mut fx, &mut market, vector[0]);

    abort 999
}

#[test]
fun cleanup_on_a_settled_market_without_a_queue_changes_nothing() {
    let (mut fx, expiry_id, _) = queue::setup_queue_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    let mut market = fx.take_market_bundle(expiry_id);
    e3::reach_expiry_with_spot(&mut fx, &mut market, e3::spot_above_strike());
    assert!(queue::try_settle(&fx, &mut market));

    queue::cleanup(&mut fx, &mut market, vector[0, MISSING_RECORD_ID]);
    assert_eq!(event::events_by_type<order_events::QueuedOrdersCleaned>().length(), 0);
    e3::assert_heads(helpers::market(&market), 0, 0);

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun cleanup_deletes_refunded_and_closed_records_only() {
    // Record 0 fills and stays Open. Record 1 fills and is sold early, so it and
    // its filled sell, record 3, are Closed. Record 2 is admin-refunded
    // (Refunded).
    let (mut fx, expiry_id, trader) = queue::setup_queue_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let account_id = helpers::account_id_bundle(&account);

    e3::enqueue_up(&mut fx, &mut market, &mut account);
    e3::enqueue_up(&mut fx, &mut market, &mut account);
    e3::enqueue_up(&mut fx, &mut market, &mut account);
    queue::admin_refund(&mut fx, &mut market, vector[2]);
    assert_eq!(e3::commit_and_resolve(&mut fx, &mut market), 2);
    assert_eq!(e3::sell_and_fill(&mut fx, &mut market, &mut account, 1), 3);
    let open_order_id = e3::held_order_id(helpers::market(&market), 0);

    let expiry = test_constants::short_expiry_ms();
    e3::reach_expiry_with_spot(&mut fx, &mut market, e3::spot_above_strike());
    // The settling call pays nothing, so record 0 is still Open.
    assert!(!queue::try_settle(&fx, &mut market));
    assert!(helpers::market(&market).is_settled());

    queue::cleanup(&mut fx, &mut market, vector[0, 1, 2, 3, MISSING_RECORD_ID]);
    e3::assert_status(helpers::market(&market), 0, order_queue::status_open());
    assert!(helpers::market(&market).queued_order(1).is_none());
    assert!(helpers::market(&market).queued_order(2).is_none());
    assert!(helpers::market(&market).queued_order(3).is_none());
    let cleaned = event::events_by_type<order_events::QueuedOrdersCleaned>();
    assert_eq!(cleaned.length(), ONE_EVENT);
    e3::assert_event(&cleaned[0], &e3::expected_record_ids(expiry_id, vector[1, 2, 3], expiry));

    // The payout walk counts the three deleted IDs as visited and pays record 0.
    assert!(queue::try_settle(&fx, &mut market));
    e3::assert_payout_progress(helpers::market(&market), 4, 4);
    let settled = event::events_by_type<order_events::OpenRecordSettled>();
    assert_eq!(settled.length(), ONE_EVENT);
    e3::assert_event(
        &settled[0],
        &e3::expected_open_record_payout(
            expiry_id,
            0,
            account_id,
            open_order_id,
            e3::quantity(),
            expiry,
        ),
    );

    // Paid, record 0 is Closed and can go too.
    queue::cleanup(&mut fx, &mut market, vector[0]);
    assert!(helpers::market(&market).queued_order(0).is_none());
    let cleaned = event::events_by_type<order_events::QueuedOrdersCleaned>();
    assert_eq!(cleaned.length(), TWO_EVENTS);
    e3::assert_event(&cleaned[1], &e3::expected_record_ids(expiry_id, vector[0], expiry));

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}
