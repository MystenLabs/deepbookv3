// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// `settle_step` over an expired market's queue, one bounded phase per call:
/// DRAIN refunds the orders still waiting through Predict's `release`, with no
/// pruning and no account rows, whether or not Predict has settled; PAY, once
/// Predict has settled, pays the Open records from the payout cursor through
/// `try_pay_settled`, counting finished records and deleted IDs as visits; DONE
/// emits `MarketPayoutsCompleted` once. Both phases run while Predict is frozen
/// and with the witness removed, an unpayable record is skipped, and a drain
/// after the first settled sweep returns reserved subsidies that a later sweep
/// collects.
///
/// Orders are 100-contract mints placed at 120_000 on the short-expiry market
/// (expiry 240_000): over `(strike, +inf]` (up, a winner at the settlement spot)
/// or `(-inf, strike]` (down, a loser). They share one cohort at τ 121_000.
#[test_only]
module deepbook_predict_orders::settle_step_flow_tests;

use deepbook_predict::{constants, expiry_market, flow_test_helpers as helpers, test_constants};
use deepbook_predict_orders::{
    order_queue,
    queue,
    queue_event_views as events,
    queue_fixture::{Self as fixture, QueueTest}
};
use std::unit_test::{assert_eq, destroy};

const QUANTITY: u64 = 100_000_000;
const MAX_COST: u64 = 90_000_000;
const TAU: u64 = 121_000;
const SELL_TAU: u64 = 122_000;
/// A placement at 120_999 lands on τ floor(121_999 / 200) * 200 = 121_800, a
/// second cohort, while the first (τ 121_000) still waits uncommitted.
const SECOND_PLACED_AT: u64 = 120_999;
const SECOND_TAU: u64 = 121_800;
const EXPIRY: u64 = 240_000;
const RESOLVE_ALL: u64 = 100;
const FIVE_ORDERS: u64 = 5;
const BATCH_TWO: u64 = 2;
const DEFAULT_CAPACITY: u64 = 100;
const DEFAULT_PER_ACCOUNT_CAP: u64 = 5;
const DEFAULT_REFUND_BATCH: u64 = 450;
const DEFAULT_PAYOUT_BATCH: u64 = 900;
/// ceil(100_000_000 * 0.99) + 1.
const CASH_NEED: u64 = 99_000_001;
/// 10 USDC of incentives.
const INCENTIVES: u64 = 10_000_000;
/// 20% of the order's t₀ trading fee, 0.005 * 100m = 500_000.
const RESERVED_SUBSIDY: u64 = 100_000;

// === Drain ===

/// Five orders wait unfilled past expiry. With a refund batch of 2 the first
/// three calls refund 2, 2, and 1 of them, before Predict settles; a PAY call
/// then waits on Predict; after Predict settles, one call walks the five
/// refunded records and completes.
#[test]
fun drain_refunds_waiting_orders_in_batches_then_pays_after_predict_settles() {
    let mut q = fixture::new_at(test_constants::short_expiry_ms());
    let account_id = q.account_id();
    FIVE_ORDERS.do!(|_| { enqueue_up(&mut q); });
    set_batches(&mut q, BATCH_TWO, DEFAULT_PAYOUT_BATCH);
    // Placement pinned the one finite boundary all five share.
    let (_, nodes) = q.ledger();
    assert_eq!(nodes, 1);

    q.set_clock(EXPIRY);
    assert_eq!(q.settle_step(), queue::phase_drain());
    assert_pending(&q, 3);
    let (resolve_head, _, _, _) = q.queue().queue_heads();
    assert_eq!(resolve_head, 2);
    assert!(!q.market().is_settled());

    assert_eq!(q.settle_step(), queue::phase_drain());
    assert_pending(&q, 1);

    // The last refund ends the drain; the call reports the next phase.
    assert_eq!(q.settle_step(), queue::phase_pay());
    assert_pending(&q, 0);
    FIVE_ORDERS.do!(|record_id| {
        let record = q.record(record_id);
        assert_eq!(record.status(), order_queue::status_refunded());
        assert_eq!(record.result().reason(), order_queue::reason_deadline());
        assert_eq!(record.result().finished_at_ms(), EXPIRY);
        assert_eq!(record.funds(), 0);
    });
    // The drain skips pruning, so the emptied node stays, and skips the account
    // rows, which no placement reads after expiry.
    let (waiting_cash_need, nodes) = q.ledger();
    assert_eq!(waiting_cash_need, 0);
    assert_eq!(nodes, 1);
    assert_eq!(q.queue().waiting_orders(account_id), FIVE_ORDERS);
    q.assert_invariants();
    // The first refund leaves four orders' cash need waiting.
    let refunds = events::refunds();
    assert_eq!(refunds.length(), FIVE_ORDERS);
    assert_eq!(refunds[0].refund_waiting_cash_need(), 4 * CASH_NEED);
    assert_eq!(refunds[0].refund_reason(), order_queue::reason_deadline());
    assert_eq!(refunds[0].refund_sender(), test_constants::alice());

    // Predict has not settled: PAY waits and changes nothing.
    assert_eq!(q.settle_step(), queue::phase_pay());
    assert_payout_progress(&q, 0, FIVE_ORDERS, false);

    q.settle_market(spot_above_strike());
    // With no Open record the payout walk only counts visits, then completes.
    assert_eq!(q.settle_step(), queue::phase_done());
    assert_payout_progress(&q, FIVE_ORDERS, FIVE_ORDERS, true);
    assert!(events::settled().is_empty());
    assert_eq!(events::payouts_completed_count(), 1);
    let (cohorts, _, _) = q.queue().waiting_cohorts();
    assert_eq!(cohorts, 0);

    // Later calls report completion without emitting it again.
    assert_eq!(q.settle_step(), queue::phase_done());
    assert_eq!(events::payouts_completed_count(), 1);
    q.finish();
}

/// A queue that never held an order completes in its first call after Predict
/// settles.
#[test]
fun an_empty_queue_completes_in_one_call() {
    let mut q = fixture::new_at(test_constants::short_expiry_ms());
    q.settle_market(spot_above_strike());

    assert_eq!(q.settle_step(), queue::phase_done());
    assert_payout_progress(&q, 0, 0, true);
    assert_eq!(events::payouts_completed_count(), 1);
    q.finish();
}

#[test, expected_failure(abort_code = queue::EMarketNotExpired)]
fun settle_step_before_expiry_aborts() {
    let mut q = fixture::new_at(test_constants::short_expiry_ms());
    enqueue_up(&mut q);
    q.set_clock(EXPIRY - 1);
    q.settle_step();
    abort 999
}

/// A committed order left unresolved still holds its reserved subsidy. Draining
/// it after the first settled sweep returns the subsidy to the market's
/// incentives, and the next sweep collects it.
#[test]
fun a_drain_after_the_first_sweep_returns_the_reserved_subsidy() {
    let mut q = fixture::new_at(test_constants::short_expiry_ms());
    q.fund_incentives(INCENTIVES);
    let record_id = enqueue_up(&mut q);
    q.commit_at(TAU, fixture::live_price());
    assert_eq!(q.record(record_id).escrow().subsidy_reserved(), RESERVED_SUBSIDY);

    q.settle_market(spot_above_strike());
    q.rebalance();
    assert_eq!(q.market().fee_incentive_balance(), 0);

    assert_eq!(q.settle_step(), queue::phase_pay());
    assert_eq!(q.market().fee_incentive_balance(), RESERVED_SUBSIDY);
    assert_eq!(events::refunds()[0].refund_subsidy_returned(), RESERVED_SUBSIDY);
    q.rebalance();
    assert_eq!(q.market().fee_incentive_balance(), 0);
    q.assert_invariants();
    q.finish();
}

// === Pay ===

#[test]
fun pay_pays_winners_and_losers_once() {
    // Records 0 and 2 are up-range winners and record 1 a down-range loser.
    // Record 2 is sold early, so it and its filled sell, record 3, are Closed
    // before expiry and the payout walk skips both.
    let mut q = fixture::new_at(test_constants::short_expiry_ms());
    let account_id = q.account_id();
    enqueue_up(&mut q);
    enqueue_down(&mut q);
    enqueue_up(&mut q);
    assert_eq!(commit_and_resolve(&mut q), 3);
    let winner_order_id = q.record(0).position().order_id();
    let loser_order_id = q.record(1).position().order_id();
    assert_eq!(sell_and_fill(&mut q, 2), 3);

    q.settle_market(spot_above_strike());
    // Only the unsold winner, record 0, still owes its quantity.
    assert_eq!(q.market().payout_liability(), QUANTITY);
    let cash_before = q.market().cash_balance();

    assert_eq!(q.settle_step(), queue::phase_done());
    assert_payout_progress(&q, 4, 4, true);
    // Record 0's payout left market cash, and nothing is owed after it.
    assert_eq!(q.market().cash_balance(), cash_before - QUANTITY);
    assert_eq!(q.market().payout_liability(), 0);
    4u64.do!(|record_id| {
        let record = q.record(record_id);
        assert_eq!(record.status(), order_queue::status_closed());
        // Every receipt was consumed.
        assert_eq!(record.receipt_stage(), 0);
        assert_eq!(record.position(), order_queue::empty_position());
    });
    q.assert_backed();

    let settled = events::settled();
    assert_eq!(settled.length(), 2);
    assert_eq!(settled[0].payout_record_id(), 0);
    assert_eq!(settled[0].payout_account_id(), account_id);
    assert_eq!(settled[0].payout_order_id(), winner_order_id);
    assert_eq!(settled[0].payout(), QUANTITY);
    assert_eq!(settled[1].payout_record_id(), 1);
    assert_eq!(settled[1].payout_order_id(), loser_order_id);
    assert_eq!(settled[1].payout(), 0);
    assert!(events::skipped().is_empty());
    assert_eq!(events::payouts_completed_count(), 1);

    // Nothing is paid or announced twice.
    assert_eq!(q.settle_step(), queue::phase_done());
    assert_eq!(events::settled().length(), 2);
    assert_eq!(events::payouts_completed_count(), 1);
    assert_eq!(q.market().cash_balance(), cash_before - QUANTITY);
    q.finish();
}

#[test]
fun pay_resumes_across_calls() {
    // Five filled up-range winners and a payout batch of 2: the payout calls
    // stop at records 2 and 4 and the third completes.
    let mut q = fixture::new_at(test_constants::short_expiry_ms());
    FIVE_ORDERS.do!(|_| { enqueue_up(&mut q); });
    assert_eq!(commit_and_resolve(&mut q), FIVE_ORDERS);
    set_batches(&mut q, DEFAULT_REFUND_BATCH, BATCH_TWO);
    q.settle_market(spot_above_strike());
    let cash_before = q.market().cash_balance();

    assert_eq!(q.settle_step(), queue::phase_pay());
    assert_payout_progress(&q, 2, FIVE_ORDERS, false);
    assert_eq!(events::settled().length(), 2);
    assert_eq!(events::payouts_completed_count(), 0);

    assert_eq!(q.settle_step(), queue::phase_pay());
    assert_payout_progress(&q, 4, FIVE_ORDERS, false);
    assert_eq!(events::settled().length(), 4);

    assert_eq!(q.settle_step(), queue::phase_done());
    assert_payout_progress(&q, FIVE_ORDERS, FIVE_ORDERS, true);
    assert_eq!(events::settled().length(), FIVE_ORDERS);
    assert_eq!(events::payouts_completed_count(), 1);
    assert_eq!(q.market().cash_balance(), cash_before - FIVE_ORDERS * QUANTITY);
    assert_eq!(q.market().payout_liability(), 0);
    q.assert_backed();
    q.finish();
}

/// Deleted records are holes the payout walk counts as visits.
#[test]
fun pay_counts_deleted_records_as_visits() {
    // Record 0 is admin-refunded, record 1 fills, record 2 is admin-refunded.
    let mut q = fixture::new_at(test_constants::short_expiry_ms());
    enqueue_up(&mut q);
    enqueue_up(&mut q);
    enqueue_up(&mut q);
    q.admin_refund(vector[0, 2]);
    assert_eq!(commit_and_resolve(&mut q), 1);
    set_batches(&mut q, DEFAULT_REFUND_BATCH, BATCH_TWO);
    q.settle_market(spot_above_strike());
    q.cleanup(vector[0, 2]);
    assert!(q.queue().order(0).is_none());
    assert!(q.queue().order(2).is_none());

    // Visits hole 0 and pays record 1.
    assert_eq!(q.settle_step(), queue::phase_pay());
    assert_payout_progress(&q, 2, 3, false);
    assert_eq!(events::settled().length(), 1);
    assert_eq!(q.record(1).status(), order_queue::status_closed());
    // Visits hole 2 and completes.
    assert_eq!(q.settle_step(), queue::phase_done());
    assert_payout_progress(&q, 3, 3, true);
    assert_eq!(events::settled().length(), 1);
    q.finish();
}

#[test]
fun pay_skips_a_record_the_market_cannot_pay() {
    // Not reachable in production: backing keeps settled cash at or above the
    // settled liability. A test-only Predict seam drains cash to one unit below
    // the winner's payout to pin the skip branch: the winner stays Open with its
    // receipt and `OpenRecordPayoutSkipped`, and the walk still closes the
    // loser and completes.
    let mut q = fixture::new_at(test_constants::short_expiry_ms());
    enqueue_up(&mut q);
    enqueue_down(&mut q);
    assert_eq!(commit_and_resolve(&mut q), 2);
    let winner_order_id = q.record(0).position().order_id();
    q.settle_market(spot_above_strike());
    let short_cash = QUANTITY - 1;
    let drain = q.market().cash_balance() - short_cash;
    destroy(expiry_market::take_market_cash_for_testing(q.market_mut(), drain));

    assert_eq!(q.settle_step(), queue::phase_done());
    assert_payout_progress(&q, 2, 2, true);
    let winner = q.record(0);
    assert_eq!(winner.status(), order_queue::status_open());
    assert_eq!(winner.receipt_stage(), constants::receipt_stage_open!());
    assert_eq!(q.record(1).status(), order_queue::status_closed());
    // Neither the skip nor the zero payout moved cash or liability.
    assert_eq!(q.market().cash_balance(), short_cash);
    assert_eq!(q.market().payout_liability(), QUANTITY);

    let skipped = events::skipped();
    assert_eq!(skipped.length(), 1);
    assert_eq!(skipped[0].payout_record_id(), 0);
    assert_eq!(skipped[0].payout_order_id(), winner_order_id);
    assert_eq!(skipped[0].payout(), QUANTITY);
    assert_eq!(events::settled().length(), 1);
    // A skipped record still lets the walk complete, once, and it cannot be
    // cleaned up while it holds its receipt.
    assert_eq!(events::payouts_completed_count(), 1);
    q.cleanup(vector[0]);
    assert!(q.queue().order(0).is_some());
    q.finish();
}

// === Exits under a freeze or without the witness ===

/// Predict's `release` and `try_pay_settled` check only its version floor, so
/// both phases run while Predict is frozen.
#[test]
fun drain_and_pay_run_while_predict_is_frozen() {
    let mut q = fixture::new_at(test_constants::short_expiry_ms());
    let waiting = enqueue_up(&mut q);
    let filled = enqueue_up_at(&mut q, SECOND_PLACED_AT);
    assert_eq!(commit_and_resolve_at(&mut q, SECOND_TAU), 1);
    assert_eq!(q.record(filled).status(), order_queue::status_open());
    q.settle_market(spot_above_strike());
    q.set_frozen(true);

    let mut phase = q.settle_step();
    while (phase != queue::phase_done()) phase = q.settle_step();

    assert_eq!(q.record(waiting).status(), order_queue::status_refunded());
    assert_eq!(q.record(filled).status(), order_queue::status_closed());
    assert_eq!(events::settled()[0].payout(), QUANTITY);
    assert_eq!(events::payouts_completed_count(), 1);
    q.finish();
}

#[test]
fun drain_and_pay_run_with_the_witness_removed() {
    let mut q = fixture::new_at(test_constants::short_expiry_ms());
    let waiting = enqueue_up(&mut q);
    let filled = enqueue_up_at(&mut q, SECOND_PLACED_AT);
    assert_eq!(commit_and_resolve_at(&mut q, SECOND_TAU), 1);
    q.settle_market(spot_above_strike());
    q.set_witness(false);

    let mut phase = q.settle_step();
    while (phase != queue::phase_done()) phase = q.settle_step();

    assert_eq!(q.record(waiting).status(), order_queue::status_refunded());
    assert_eq!(q.record(filled).status(), order_queue::status_closed());
    assert_eq!(events::payouts_completed_count(), 1);
    q.finish();
}

// === Cleanup ===

#[test, expected_failure(abort_code = queue::EMarketNotSettled)]
fun cleanup_requires_a_settled_market() {
    let mut q = fixture::new_at(test_constants::short_expiry_ms());
    q.cleanup(vector[0]);
    abort 999
}

#[test]
fun cleanup_of_an_empty_queue_changes_nothing() {
    let mut q = fixture::new_at(test_constants::short_expiry_ms());
    q.settle_market(spot_above_strike());

    q.cleanup(vector[0, 99]);
    assert!(events::cleaned().is_empty());
    let (_, next_id, _, _) = q.queue().queue_heads();
    assert_eq!(next_id, 0);
    q.finish();
}

#[test]
fun cleanup_deletes_refunded_and_closed_records_only() {
    // Record 0 fills and stays Open. Record 1 fills and is sold early, so it and
    // its filled sell, record 3, are Closed. Record 2 is admin-refunded.
    let mut q = fixture::new_at(test_constants::short_expiry_ms());
    enqueue_up(&mut q);
    enqueue_up(&mut q);
    enqueue_up(&mut q);
    q.admin_refund(vector[2]);
    assert_eq!(commit_and_resolve(&mut q), 2);
    assert_eq!(sell_and_fill(&mut q, 1), 3);
    q.settle_market(spot_above_strike());

    q.cleanup(vector[0, 1, 2, 3, 99]);
    assert_eq!(q.record(0).status(), order_queue::status_open());
    assert!(q.queue().order(1).is_none());
    assert!(q.queue().order(2).is_none());
    assert!(q.queue().order(3).is_none());
    let cleaned = events::cleaned();
    assert_eq!(cleaned.length(), 1);
    assert_eq!(cleaned[0], vector[1, 2, 3]);

    // The payout walk counts the three deleted IDs as visited and pays record 0.
    assert_eq!(q.settle_step(), queue::phase_done());
    assert_eq!(events::settled().length(), 1);

    // Paid, record 0 is Closed and can go too.
    q.cleanup(vector[0]);
    assert!(q.queue().order(0).is_none());
    assert_eq!(events::cleaned()[1], vector[0]);
    q.finish();
}

// === Helpers ===

/// Settlement spot one tick above the strike: inside `(strike, +inf]` and
/// outside `(-inf, strike]`.
fun spot_above_strike(): u64 {
    (helpers::strike_tick() + 1) * test_constants::default_tick_size()
}

fun enqueue_up(q: &mut QueueTest): u64 {
    q.enqueue_atm(QUANTITY, MAX_COST)
}

/// An up mint placed at `placed_at_ms`, a later cohort than one placed at
/// 120_000.
fun enqueue_up_at(q: &mut QueueTest, placed_at_ms: u64): u64 {
    q.refresh_oracle_at(placed_at_ms);
    q.enqueue_atm(QUANTITY, MAX_COST)
}

fun enqueue_down(q: &mut QueueTest): u64 {
    q.enqueue_quantity(0, helpers::strike_tick(), QUANTITY, MAX_COST, std::u64::max_value!())
}

/// Commit the 121_000 cohort at the live price and resolve everything.
fun commit_and_resolve(q: &mut QueueTest): u64 {
    commit_and_resolve_at(q, TAU)
}

fun commit_and_resolve_at(q: &mut QueueTest, tau_ms: u64): u64 {
    q.commit_at(tau_ms, fixture::live_price());
    q.resolve(RESOLVE_ALL)
}

/// Sell Open record `record_id`'s whole position early at τ and fill the sell
/// at SELL_TAU, so the source and the sell record both end Closed. Returns the
/// sell's record ID.
fun sell_and_fill(q: &mut QueueTest, record_id: u64): u64 {
    q.refresh_oracle_at(TAU);
    let sell_id = q.enqueue_sell(record_id, QUANTITY, 0, 0);
    q.commit_at(SELL_TAU, fixture::live_price());
    assert_eq!(q.resolve(RESOLVE_ALL), 1);
    assert_eq!(q.record(record_id).status(), order_queue::status_closed());
    assert_eq!(q.record(sell_id).status(), order_queue::status_closed());
    sell_id
}

fun set_batches(q: &mut QueueTest, refund_batch: u64, payout_batch: u64) {
    q.set_limits(
        DEFAULT_CAPACITY,
        DEFAULT_CAPACITY,
        DEFAULT_PER_ACCOUNT_CAP,
        constants::position_lot_size!(),
        refund_batch,
        payout_batch,
    );
}

fun assert_pending(q: &QueueTest, mints: u64) {
    let (pending_mints, pending_sells) = q.queue().pending_counts();
    assert_eq!(pending_mints, mints);
    assert_eq!(pending_sells, 0);
}

fun assert_payout_progress(q: &QueueTest, cursor: u64, next_id: u64, completed: bool) {
    let (payout_cursor, actual_next_id, payouts_completed) = q.queue().payout_progress();
    assert_eq!(payout_cursor, cursor);
    assert_eq!(actual_next_id, next_id);
    assert_eq!(payouts_completed, completed);
}
