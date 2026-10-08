// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// `try_settle` over a market with a queue, one phase per call: refund the
/// orders still waiting at expiry in batches, then settle (paying nothing), then
/// pay the Open records from the payout cursor in batches.
/// `MarketPayoutsCompleted` fires exactly once. No phase aborts because of an
/// order: an unpayable record is skipped and leftover escrow is swept.
#[test_only]
module deepbook_predict::settle_queue_flow_tests;

use deepbook_predict::{
    config_events,
    expiry_market,
    flow_test_helpers as helpers,
    order_events,
    order_queue,
    protocol_config,
    queue_e3_test_helpers as e3,
    queue_test_helpers as queue,
    test_constants
};
use std::unit_test::{assert_eq, destroy};
use sui::{balance, event};
use usdc::usdc::USDC;

const REFUND_BATCH_TWO: u64 = 2;
const PAYOUT_BATCH_TWO: u64 = 2;
/// The spec defaults for the two settle batches.
const DEFAULT_REFUND_BATCH: u64 = 450;
const DEFAULT_PAYOUT_BATCH: u64 = 900;
const FIVE_ORDERS: u64 = 5;
const LEFTOVER_ESCROW: u64 = 1_234;
const ONE_MS: u64 = 1;
const ONE_EVENT: u64 = 1;
const TWO_EVENTS: u64 = 2;

#[test]
fun settle_refunds_waiting_orders_in_batches_before_settling() {
    // Five orders wait unfilled past expiry. With a refund batch of 2 the first
    // three calls refund 2, 2 and 1 of them and return false without settling;
    // the fourth settles and pays nothing; the fifth walks the five refunded
    // records and completes.
    let (mut fx, expiry_id, trader) = queue::setup_queue_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let account_id = helpers::account_id_bundle(&account);
    let expiry = test_constants::short_expiry_ms();

    FIVE_ORDERS.do!(|_| {
        e3::enqueue_up(&mut fx, &mut market, &mut account);
    });
    e3::set_settle_batches(&mut fx, &mut market, REFUND_BATCH_TWO, DEFAULT_PAYOUT_BATCH);
    // Placement pinned the one finite boundary all five share.
    assert_eq!(helpers::market(&market).payout_tree_node_count(), 1);

    // Before expiry no phase runs.
    fx.set_clock_for_testing(expiry - ONE_MS);
    assert!(!queue::try_settle(&fx, &mut market));
    e3::assert_pending(helpers::market(&market), FIVE_ORDERS, 0);

    e3::reach_expiry_with_spot(&mut fx, &mut market, e3::spot_above_strike());
    assert!(!queue::try_settle(&fx, &mut market));
    e3::assert_pending(helpers::market(&market), 3, 0);
    e3::assert_heads(helpers::market(&market), 2, FIVE_ORDERS);
    assert!(!helpers::market(&market).is_settled());

    assert!(!queue::try_settle(&fx, &mut market));
    e3::assert_pending(helpers::market(&market), 1, 0);
    e3::assert_heads(helpers::market(&market), 4, FIVE_ORDERS);

    assert!(!queue::try_settle(&fx, &mut market));
    e3::assert_pending(helpers::market(&market), 0, 0);
    e3::assert_heads(helpers::market(&market), FIVE_ORDERS, FIVE_ORDERS);
    assert!(!helpers::market(&market).is_settled());
    FIVE_ORDERS.do!(|record_id| {
        e3::assert_refunded_with(
            helpers::market(&market),
            record_id,
            order_queue::reason_deadline(),
            expiry,
        );
    });
    // Settlement refunds skip pruning: the emptied node stays.
    assert_eq!(helpers::market(&market).payout_tree_node_count(), 1);
    queue::assert_queue_invariants(helpers::market(&market));

    // Settlement refunds report sender @0x0. The first one leaves four orders'
    // cash need waiting: 4 × 99_000_001.
    let refunds = event::events_by_type<order_events::QueuedOrderRefunded>();
    assert_eq!(refunds.length(), FIVE_ORDERS);
    e3::assert_event(
        &refunds[0],
        &e3::expected_mint_refund(
            helpers::market(&market).cash_balance(),
            helpers::market(&market).required_cash(),
            4 * e3::cash_need(),
            expiry_id,
            0,
            account_id,
            order_queue::reason_deadline(),
            @0x0,
            expiry,
        ),
    );

    // The settling call closes the queue and pays nothing.
    assert!(!queue::try_settle(&fx, &mut market));
    assert!(helpers::market(&market).is_settled());
    assert_eq!(event::events_by_type<config_events::MarketSettled>().length(), ONE_EVENT);
    e3::assert_payout_progress(helpers::market(&market), 0, FIVE_ORDERS);
    assert_eq!(event::events_by_type<order_events::MarketPayoutsCompleted>().length(), 0);

    // With no Open record, the payout walk only counts visits, then completes.
    assert!(queue::try_settle(&fx, &mut market));
    e3::assert_payout_progress(helpers::market(&market), FIVE_ORDERS, FIVE_ORDERS);
    assert_eq!(event::events_by_type<order_events::OpenRecordSettled>().length(), 0);
    let completed = event::events_by_type<order_events::MarketPayoutsCompleted>();
    assert_eq!(completed.length(), ONE_EVENT);
    e3::assert_event(&completed[0], &e3::expected_payouts_completed(expiry_id, expiry));

    // Later calls report completion without emitting it again.
    assert!(queue::try_settle(&fx, &mut market));
    assert_eq!(event::events_by_type<order_events::MarketPayoutsCompleted>().length(), ONE_EVENT);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun settle_pays_winners_and_losers_once() {
    // Records 0 and 2 are up-range winners and record 1 a down-range loser.
    // Record 2 is sold early, so it and its filled sell, record 3, are Closed
    // before expiry and the payout walk skips both.
    let (mut fx, expiry_id, trader) = queue::setup_queue_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let account_id = helpers::account_id_bundle(&account);
    let expiry = test_constants::short_expiry_ms();

    e3::enqueue_up(&mut fx, &mut market, &mut account);
    e3::enqueue_down(&mut fx, &mut market, &mut account);
    e3::enqueue_up(&mut fx, &mut market, &mut account);
    assert_eq!(e3::commit_and_resolve(&mut fx, &mut market), 3);
    let winner_order_id = e3::held_order_id(helpers::market(&market), 0);
    let loser_order_id = e3::held_order_id(helpers::market(&market), 1);
    assert_eq!(e3::sell_and_fill(&mut fx, &mut market, &mut account, 2), 3);

    e3::reach_expiry_with_spot(&mut fx, &mut market, e3::spot_above_strike());
    assert!(!queue::try_settle(&fx, &mut market));
    assert!(helpers::market(&market).is_settled());
    assert_eq!(event::events_by_type<order_events::OpenRecordSettled>().length(), 0);
    e3::assert_payout_progress(helpers::market(&market), 0, 4);
    // Only the unsold winner, record 0, still owes its quantity.
    assert_eq!(helpers::market(&market).payout_liability(), e3::quantity());
    let cash_before = helpers::market(&market).cash_balance();

    assert!(queue::try_settle(&fx, &mut market));
    e3::assert_payout_progress(helpers::market(&market), 4, 4);
    // Record 0's payout left market cash, and nothing is owed after it.
    assert_eq!(helpers::market(&market).cash_balance(), cash_before - e3::quantity());
    assert_eq!(helpers::market(&market).payout_liability(), 0);
    e3::assert_status(helpers::market(&market), 0, order_queue::status_closed());
    e3::assert_status(helpers::market(&market), 1, order_queue::status_closed());
    e3::assert_status(helpers::market(&market), 2, order_queue::status_closed());
    e3::assert_status(helpers::market(&market), 3, order_queue::status_closed());
    helpers::assert_market_backed_bundle(&market);

    let settled = event::events_by_type<order_events::OpenRecordSettled>();
    assert_eq!(settled.length(), TWO_EVENTS);
    e3::assert_event(
        &settled[0],
        &e3::expected_open_record_payout(
            expiry_id,
            0,
            account_id,
            winner_order_id,
            e3::quantity(),
            expiry,
        ),
    );
    e3::assert_event(
        &settled[1],
        &e3::expected_open_record_payout(expiry_id, 1, account_id, loser_order_id, 0, expiry),
    );
    assert_eq!(event::events_by_type<order_events::OpenRecordPayoutSkipped>().length(), 0);
    let completed = event::events_by_type<order_events::MarketPayoutsCompleted>();
    assert_eq!(completed.length(), ONE_EVENT);
    e3::assert_event(&completed[0], &e3::expected_payouts_completed(expiry_id, expiry));

    // Nothing is paid or announced twice.
    assert!(queue::try_settle(&fx, &mut market));
    assert_eq!(event::events_by_type<order_events::OpenRecordSettled>().length(), TWO_EVENTS);
    assert_eq!(event::events_by_type<order_events::MarketPayoutsCompleted>().length(), ONE_EVENT);
    assert_eq!(helpers::market(&market).cash_balance(), cash_before - e3::quantity());

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun settle_resumes_payouts_across_calls() {
    // Five filled up-range winners and a payout batch of 2: the payout calls
    // stop at records 2 and 4 and the third completes.
    let (mut fx, expiry_id, trader) = queue::setup_queue_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    FIVE_ORDERS.do!(|_| {
        e3::enqueue_up(&mut fx, &mut market, &mut account);
    });
    assert_eq!(e3::commit_and_resolve(&mut fx, &mut market), FIVE_ORDERS);
    e3::set_settle_batches(&mut fx, &mut market, DEFAULT_REFUND_BATCH, PAYOUT_BATCH_TWO);

    e3::reach_expiry_with_spot(&mut fx, &mut market, e3::spot_above_strike());
    assert!(!queue::try_settle(&fx, &mut market));
    let cash_before = helpers::market(&market).cash_balance();

    assert!(!queue::try_settle(&fx, &mut market));
    e3::assert_payout_progress(helpers::market(&market), 2, FIVE_ORDERS);
    assert_eq!(event::events_by_type<order_events::OpenRecordSettled>().length(), 2);
    assert_eq!(event::events_by_type<order_events::MarketPayoutsCompleted>().length(), 0);

    assert!(!queue::try_settle(&fx, &mut market));
    e3::assert_payout_progress(helpers::market(&market), 4, FIVE_ORDERS);
    assert_eq!(event::events_by_type<order_events::OpenRecordSettled>().length(), 4);
    assert_eq!(event::events_by_type<order_events::MarketPayoutsCompleted>().length(), 0);

    assert!(queue::try_settle(&fx, &mut market));
    e3::assert_payout_progress(helpers::market(&market), FIVE_ORDERS, FIVE_ORDERS);
    assert_eq!(event::events_by_type<order_events::OpenRecordSettled>().length(), FIVE_ORDERS);
    assert_eq!(event::events_by_type<order_events::MarketPayoutsCompleted>().length(), ONE_EVENT);
    assert_eq!(helpers::market(&market).cash_balance(), cash_before - FIVE_ORDERS * e3::quantity());
    assert_eq!(helpers::market(&market).payout_liability(), 0);
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun settle_skips_a_record_the_market_cannot_pay() {
    // Not reachable in production: backing keeps settled cash at or above the
    // settled liability. A test-only seam drains cash to one unit below the
    // winner's payout to pin the skip branch: the winner stays Open with
    // `OpenRecordPayoutSkipped`, the walk still closes the loser and completes.
    let (mut fx, expiry_id, trader) = queue::setup_queue_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let account_id = helpers::account_id_bundle(&account);
    let expiry = test_constants::short_expiry_ms();

    e3::enqueue_up(&mut fx, &mut market, &mut account);
    e3::enqueue_down(&mut fx, &mut market, &mut account);
    assert_eq!(e3::commit_and_resolve(&mut fx, &mut market), 2);
    let winner_order_id = e3::held_order_id(helpers::market(&market), 0);
    let loser_order_id = e3::held_order_id(helpers::market(&market), 1);

    e3::reach_expiry_with_spot(&mut fx, &mut market, e3::spot_above_strike());
    assert!(!queue::try_settle(&fx, &mut market));
    let short_cash = e3::quantity() - 1;
    let drain = helpers::market(&market).cash_balance() - short_cash;
    destroy(expiry_market::take_market_cash_for_testing(helpers::market_mut(&mut market), drain));

    assert!(queue::try_settle(&fx, &mut market));
    e3::assert_payout_progress(helpers::market(&market), 2, 2);
    e3::assert_status(helpers::market(&market), 0, order_queue::status_open());
    e3::assert_status(helpers::market(&market), 1, order_queue::status_closed());
    // Neither the skip nor the zero payout moved cash or liability.
    assert_eq!(helpers::market(&market).cash_balance(), short_cash);
    assert_eq!(helpers::market(&market).payout_liability(), e3::quantity());

    let skipped = event::events_by_type<order_events::OpenRecordPayoutSkipped>();
    assert_eq!(skipped.length(), ONE_EVENT);
    e3::assert_event(
        &skipped[0],
        &e3::expected_open_record_payout(
            expiry_id,
            0,
            account_id,
            winner_order_id,
            e3::quantity(),
            expiry,
        ),
    );
    let settled = event::events_by_type<order_events::OpenRecordSettled>();
    assert_eq!(settled.length(), ONE_EVENT);
    e3::assert_event(
        &settled[0],
        &e3::expected_open_record_payout(expiry_id, 1, account_id, loser_order_id, 0, expiry),
    );
    // A skipped record still lets the walk complete, once.
    assert_eq!(event::events_by_type<order_events::MarketPayoutsCompleted>().length(), ONE_EVENT);
    assert!(queue::try_settle(&fx, &mut market));
    assert_eq!(event::events_by_type<order_events::OpenRecordPayoutSkipped>().length(), ONE_EVENT);
    assert_eq!(event::events_by_type<order_events::MarketPayoutsCompleted>().length(), ONE_EVENT);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun settle_sweeps_leftover_queue_escrow_into_market_cash() {
    // Not reachable in production: escrow holds exactly the waiting orders'
    // funds. A test-only seam adds escrow no order owns, which must reach market
    // cash at settlement rather than stay stranded.
    let (mut fx, expiry_id, trader) = queue::setup_queue_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let expiry = test_constants::short_expiry_ms();

    e3::enqueue_up(&mut fx, &mut market, &mut account);
    expiry_market::add_queue_escrow_for_testing(
        helpers::market_mut(&mut market),
        balance::create_for_testing<USDC>(LEFTOVER_ESCROW),
    );

    e3::reach_expiry_with_spot(&mut fx, &mut market, e3::spot_above_strike());
    // Refund phase: the order takes back exactly its own escrow.
    assert!(!queue::try_settle(&fx, &mut market));
    e3::assert_status(helpers::market(&market), 0, order_queue::status_refunded());
    assert_eq!(expiry_market::queue_escrow_for_testing(helpers::market(&market)), LEFTOVER_ESCROW);
    let cash_before = helpers::market(&market).cash_balance();

    // Settling call: the leftover joins market cash.
    assert!(!queue::try_settle(&fx, &mut market));
    assert!(helpers::market(&market).is_settled());
    assert_eq!(helpers::market(&market).cash_balance(), cash_before + LEFTOVER_ESCROW);
    assert_eq!(expiry_market::queue_escrow_for_testing(helpers::market(&market)), 0);
    queue::assert_queue_invariants(helpers::market(&market));
    let swept = event::events_by_type<order_events::QueueEscrowSwept>();
    assert_eq!(swept.length(), ONE_EVENT);
    e3::assert_event(&swept[0], &e3::expected_escrow_swept(expiry_id, LEFTOVER_ESCROW, expiry));

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun settle_without_a_queue_or_policy_completes_in_the_settling_call() {
    // A market that never had a queue, before the delayed-execution policy
    // exists: settlement falls back to the compiled batch sizes instead of
    // aborting, and the settling call itself completes the payouts.
    let (mut fx, expiry_id, _) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    let mut market = fx.take_market_bundle(expiry_id);
    let expiry = test_constants::short_expiry_ms();
    assert!(helpers::config(&market).delayed_execution_policy().is_none());

    e3::reach_expiry_with_spot(&mut fx, &mut market, e3::spot_above_strike());
    assert!(queue::try_settle(&fx, &mut market));
    assert!(helpers::market(&market).is_settled());
    e3::assert_payout_progress(helpers::market(&market), 0, 0);
    assert_eq!(event::events_by_type<config_events::MarketSettled>().length(), ONE_EVENT);
    assert_eq!(event::events_by_type<order_events::QueueEscrowSwept>().length(), 0);
    let completed = event::events_by_type<order_events::MarketPayoutsCompleted>();
    assert_eq!(completed.length(), ONE_EVENT);
    e3::assert_event(&completed[0], &e3::expected_payouts_completed(expiry_id, expiry));

    assert!(queue::try_settle(&fx, &mut market));
    assert_eq!(event::events_by_type<order_events::MarketPayoutsCompleted>().length(), ONE_EVENT);

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test, expected_failure(abort_code = protocol_config::EProtocolFrozen)]
fun settle_aborts_while_frozen() {
    let (mut fx, expiry_id, _) = queue::setup_queue_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    let mut market = fx.take_market_bundle(expiry_id);
    e3::reach_expiry_with_spot(&mut fx, &mut market, e3::spot_above_strike());
    fx.set_frozen_bundle(&mut market, true);
    queue::try_settle(&fx, &mut market);

    abort 999
}
