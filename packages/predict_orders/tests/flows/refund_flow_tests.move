// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Queue refunds: the permissionless deadline `refund` and the admin
/// `admin_refund`. Both run under the emergency freeze, refund the whole budget
/// and order fee (reasons 5 and 7), and skip records that already finished.
#[test_only]
module deepbook_predict::refund_flow_tests;

use deepbook_predict::{
    flow_test_helpers as helpers,
    order_events,
    order_queue,
    queue_e3_test_helpers as e3,
    queue_test_helpers as queue,
    test_constants
};
use std::unit_test::assert_eq;
use sui::event;

/// More visits than any scenario here has records.
const VISIT_ALL: u64 = 100;
const VISIT_TWO: u64 = 2;
const MISSING_RECORD_ID: u64 = 99;
const ONE_EVENT: u64 = 1;

#[test]
fun refund_waits_for_the_deadline_then_refunds_with_reason_5() {
    let (mut fx, expiry_id, trader) = queue::setup_queue_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let account_id = helpers::account_id_bundle(&account);

    let record_id = e3::enqueue_up(&mut fx, &mut market, &mut account);
    assert_eq!(record_id, 0);
    // Placement pinned the one finite boundary of `(strike, +inf)` as a node.
    assert_eq!(helpers::market(&market).payout_tree_node_count(), 1);

    // One millisecond before the deadline nothing is due.
    fx.set_clock_for_testing(e3::deadline_ms() - 1);
    assert_eq!(queue::refund(&mut fx, &mut market, VISIT_ALL), 0);
    e3::assert_status(helpers::market(&market), record_id, order_queue::status_pending());

    // At the deadline the order is refunded in full: budget plus order fee.
    fx.set_clock_for_testing(e3::deadline_ms());
    assert_eq!(queue::refund(&mut fx, &mut market, VISIT_ALL), 1);
    e3::assert_refunded_with(
        helpers::market(&market),
        record_id,
        order_queue::reason_deadline(),
        e3::deadline_ms(),
    );
    e3::assert_pending(helpers::market(&market), 0, 0);
    assert_eq!(helpers::market(&market).waiting_cash_need(), 0);
    assert_eq!(helpers::market(&market).waiting_orders(account_id), 0);
    e3::assert_heads(helpers::market(&market), 1, 1);
    // The deadline refund prunes the emptied, unpinned node.
    assert_eq!(helpers::market(&market).payout_tree_node_count(), 0);
    queue::assert_queue_invariants(helpers::market(&market));

    // Reason 5 moves no market cash, so the event's figures are today's.
    let events = event::events_by_type<order_events::QueuedOrderRefunded>();
    assert_eq!(events.length(), ONE_EVENT);
    e3::assert_event(
        &events[0],
        &e3::expected_mint_refund(
            helpers::market(&market).cash_balance(),
            helpers::market(&market).required_cash(),
            0,
            expiry_id,
            record_id,
            account_id,
            order_queue::reason_deadline(),
            test_constants::alice(),
            e3::deadline_ms(),
        ),
    );

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun refund_runs_under_the_emergency_freeze() {
    let (mut fx, expiry_id, trader) = queue::setup_queue_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let record_id = e3::enqueue_up(&mut fx, &mut market, &mut account);
    fx.set_frozen_bundle(&mut market, true);
    fx.set_clock_for_testing(e3::deadline_ms());

    assert_eq!(queue::refund(&mut fx, &mut market, VISIT_ALL), 1);
    e3::assert_refunded_with(
        helpers::market(&market),
        record_id,
        order_queue::reason_deadline(),
        e3::deadline_ms(),
    );
    queue::assert_queue_invariants(helpers::market(&market));

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun refund_counts_every_visited_record_and_resumes_inside_the_cohort() {
    // Three orders share one cohort. The middle one is admin-refunded first, so
    // a two-visit walk spends a visit on it and stops before the third order.
    let (mut fx, expiry_id, trader) = queue::setup_queue_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    e3::enqueue_up(&mut fx, &mut market, &mut account);
    e3::enqueue_up(&mut fx, &mut market, &mut account);
    e3::enqueue_up(&mut fx, &mut market, &mut account);
    queue::admin_refund(&mut fx, &mut market, vector[1]);
    fx.set_clock_for_testing(e3::deadline_ms());

    // Visits record 0 (refunded) and record 1 (already finished): one refund.
    assert_eq!(queue::refund(&mut fx, &mut market, VISIT_TWO), 1);
    e3::assert_status(helpers::market(&market), 2, order_queue::status_pending());
    // The walk stopped inside the cohort, so its first record moved to 2.
    e3::assert_heads(helpers::market(&market), 2, 3);

    // The next call resumes at record 2 and empties the cohort.
    assert_eq!(queue::refund(&mut fx, &mut market, VISIT_TWO), 1);
    e3::assert_refunded_with(
        helpers::market(&market),
        2,
        order_queue::reason_deadline(),
        e3::deadline_ms(),
    );
    e3::assert_heads(helpers::market(&market), 3, 3);
    e3::assert_pending(helpers::market(&market), 0, 0);
    queue::assert_queue_invariants(helpers::market(&market));

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun refund_without_a_queue_returns_zero_even_while_frozen() {
    let (mut fx, expiry_id, _) = queue::setup_queue_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    let mut market = fx.take_market_bundle(expiry_id);
    fx.set_frozen_bundle(&mut market, true);

    assert_eq!(queue::refund(&mut fx, &mut market, VISIT_ALL), 0);
    e3::assert_heads(helpers::market(&market), 0, 0);
    assert_eq!(event::events_by_type<order_events::QueuedOrderRefunded>().length(), 0);

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun refund_admin_refunds_listed_orders_with_reason_7_and_skips_the_rest() {
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

    // Before any deadline: record 1 is refunded once; the unknown ID and the
    // repeat of record 1 are skipped without aborting.
    queue::admin_refund(&mut fx, &mut market, vector[1, MISSING_RECORD_ID, 1]);
    e3::assert_refunded_with(
        helpers::market(&market),
        1,
        order_queue::reason_admin(),
        test_constants::now_ms(),
    );
    e3::assert_status(helpers::market(&market), 0, order_queue::status_pending());
    e3::assert_pending(helpers::market(&market), 1, 0);
    assert_eq!(helpers::market(&market).waiting_cash_need(), e3::cash_need());
    assert_eq!(helpers::market(&market).waiting_orders(account_id), 1);
    // Record 0 still pins the shared boundary node.
    assert_eq!(helpers::market(&market).payout_tree_node_count(), 1);
    queue::assert_queue_invariants(helpers::market(&market));

    let events = event::events_by_type<order_events::QueuedOrderRefunded>();
    assert_eq!(events.length(), ONE_EVENT);
    e3::assert_event(
        &events[0],
        &e3::expected_mint_refund(
            helpers::market(&market).cash_balance(),
            helpers::market(&market).required_cash(),
            e3::cash_need(),
            expiry_id,
            1,
            account_id,
            order_queue::reason_admin(),
            test_constants::alice(),
            test_constants::now_ms(),
        ),
    );

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun refund_admin_runs_under_the_emergency_freeze() {
    let (mut fx, expiry_id, trader) = queue::setup_queue_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let record_id = e3::enqueue_up(&mut fx, &mut market, &mut account);
    fx.set_frozen_bundle(&mut market, true);
    queue::admin_refund(&mut fx, &mut market, vector[record_id]);

    e3::assert_refunded_with(
        helpers::market(&market),
        record_id,
        order_queue::reason_admin(),
        test_constants::now_ms(),
    );
    e3::assert_pending(helpers::market(&market), 0, 0);
    queue::assert_queue_invariants(helpers::market(&market));

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun refund_admin_skips_a_filled_record() {
    let (mut fx, expiry_id, trader) = queue::setup_queue_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let record_id = e3::enqueue_up(&mut fx, &mut market, &mut account);
    assert_eq!(e3::commit_and_resolve(&mut fx, &mut market), 1);
    e3::assert_status(helpers::market(&market), record_id, order_queue::status_open());

    queue::admin_refund(&mut fx, &mut market, vector[record_id]);
    e3::assert_status(helpers::market(&market), record_id, order_queue::status_open());
    assert_eq!(event::events_by_type<order_events::QueuedOrderRefunded>().length(), 0);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}
