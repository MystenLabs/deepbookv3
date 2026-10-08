// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Queue refunds through Predict's `release`: the permissionless deadline
/// `refund` and the admin `admin_refund`. Both run while Predict is frozen and
/// with this companion's witness removed, refund the whole budget and order fee
/// (reasons 5 and 7), return a committed mint's reserved subsidy to the
/// incentives, hand a sell's position back to its record, and skip records that
/// already finished. A deadline walk visits at most 450 records per call. A
/// RefundDue record, a status nothing sets at launch (a test seam marks it),
/// refunds with its stored reason and that reason's fee rule: reasons 1 and 2
/// keep the order fee in market cash.
///
/// Orders are 100-contract mints over `(strike, +inf]` placed at 120_000 on the
/// short-expiry market, so they share one cohort at τ 121_000 with deadline
/// 126_000.
#[test_only]
module deepbook_predict_orders::refund_flow_tests;

use deepbook_predict::{constants, protocol_config, test_constants};
use deepbook_predict_orders::{
    order_queue,
    queue_event_views as events,
    queue_fixture::{Self as fixture, QueueTest}
};
use std::unit_test::{assert_eq, destroy};

/// More visits than any scenario here has records.
const VISIT_ALL: u64 = 100;
const VISIT_TWO: u64 = 2;
const MISSING_RECORD_ID: u64 = 99;
const TAU: u64 = 121_000;
const DEADLINE: u64 = 126_000;
/// One order: 100 contracts with a 90 USDC cap, below the quantity and the
/// deposit, so the escrowed budget is the cap.
const QUANTITY: u64 = 100_000_000;
const MAX_COST: u64 = 90_000_000;
const ORDER_FEE: u64 = 20_000;
/// ceil(100_000_000 * 0.99) + 1.
const CASH_NEED: u64 = 99_000_001;
/// 10 USDC of incentives.
const INCENTIVES: u64 = 10_000_000;
/// 20% of the order's t₀ trading fee, 0.005 * 100m = 500_000: 100_000.
const RESERVED_SUBSIDY: u64 = 100_000;
/// ceil(100_000_000 * (1 - 0.31)) + 1.
const SELL_CASH_NEED: u64 = 69_000_001;
const SELL_PLACED_AT: u64 = 121_200;
/// Missing record IDs between two orders of one cohort, more than one call's
/// 450 visits.
const SKIPPED_IDS: u64 = 500;
/// The most records one `refund` call visits.
const MAX_VISITS_PER_CALL: u64 = 450;
/// More visits than any call allows.
const VISIT_UNBOUNDED: u64 = 18_446_744_073_709_551_615;
/// Pool liquidity, so a flush can start.
const SUPPLY_AMOUNT: u64 = 100_000_000_000;
/// A 4m at-the-money mint with a 3 USDC cap, for the default-expiry pool market.
const SMALL_QUANTITY: u64 = 4_000_000;
const SMALL_MAX_COST: u64 = 3_000_000;

#[test]
fun refund_waits_for_the_deadline_then_refunds_with_reason_5() {
    let mut q = fixture::new_at(test_constants::short_expiry_ms());
    let account_id = q.account_id();
    let record_id = enqueue(&mut q);
    assert_eq!(record_id, 0);
    // Placement pinned the one finite boundary of `(strike, +inf)` as a node.
    let (waiting_cash_need, nodes) = q.ledger();
    assert_eq!(nodes, 1);
    assert_eq!(waiting_cash_need, CASH_NEED);

    // One millisecond before the deadline nothing is due.
    q.set_clock(DEADLINE - 1);
    assert_eq!(q.refund(VISIT_ALL), 0);
    assert_eq!(q.record(record_id).status(), order_queue::status_pending());

    // At the deadline the order is refunded in full: budget plus order fee.
    q.set_clock(DEADLINE);
    assert_eq!(q.refund(VISIT_ALL), 1);
    assert_refunded_with(&q, record_id, order_queue::reason_deadline(), DEADLINE);
    assert_pending(&q, 0, 0);
    assert_eq!(q.queue().waiting_orders(account_id), 0);
    let (resolve_head, next_id, _, _) = q.queue().queue_heads();
    assert_eq!(resolve_head, 1);
    assert_eq!(next_id, 1);
    // Predict released the cash need and pruned the emptied, unpinned node.
    let (waiting_cash_need, nodes) = q.ledger();
    assert_eq!(waiting_cash_need, 0);
    assert_eq!(nodes, 0);
    q.assert_invariants();

    // Reason 5 moves no market cash, so the event's figures are today's.
    let refunds = events::refunds();
    assert_eq!(refunds.length(), 1);
    let refund = refunds[0];
    assert_eq!(refund.refund_market_cash(), q.market().cash_balance());
    assert_eq!(refund.refund_waiting_cash_need(), 0);
    assert_eq!(refund.refund_record_id(), record_id);
    assert_eq!(refund.refund_account_id(), account_id);
    assert_eq!(refund.refund_kind(), order_queue::kind_exact_quantity());
    assert_eq!(refund.refund_reason(), order_queue::reason_deadline());
    assert_eq!(refund.refund_escrow_returned(), MAX_COST);
    assert_eq!(refund.refund_order_fee_returned(), ORDER_FEE);
    assert_eq!(refund.refund_subsidy_returned(), 0);
    assert!(!refund.refund_position_returned());
    assert_eq!(refund.refund_sender(), test_constants::alice());
    assert_eq!(refund.refund_onchain_timestamp_ms(), DEADLINE);
    q.finish();
}

#[test]
fun refund_runs_under_the_emergency_freeze() {
    let mut q = fixture::new_at(test_constants::short_expiry_ms());
    let record_id = enqueue(&mut q);
    q.set_frozen(true);
    q.set_clock(DEADLINE);

    assert_eq!(q.refund(VISIT_ALL), 1);
    assert_refunded_with(&q, record_id, order_queue::reason_deadline(), DEADLINE);
    q.assert_invariants();
    q.finish();
}

/// Removing the witness stops fills, never exits: a committed order still
/// reaches its deadline refund, with its reserved subsidy back in the
/// incentives.
#[test]
fun refund_runs_with_the_witness_removed_and_returns_the_reserved_subsidy() {
    let mut q = fixture::new_at(test_constants::short_expiry_ms());
    q.fund_incentives(INCENTIVES);
    let incentives = q.market().fee_incentive_balance();
    let record_id = enqueue(&mut q);
    q.commit_at(TAU, fixture::live_price());
    assert_eq!(q.record(record_id).escrow().subsidy_reserved(), RESERVED_SUBSIDY);
    assert_eq!(q.market().fee_incentive_balance(), incentives - RESERVED_SUBSIDY);
    q.set_witness(false);
    q.set_clock(DEADLINE);

    assert_eq!(q.refund(VISIT_ALL), 1);

    assert_refunded_with(&q, record_id, order_queue::reason_deadline(), DEADLINE);
    assert_eq!(q.market().fee_incentive_balance(), incentives);
    let refund = events::refunds()[0];
    assert_eq!(refund.refund_subsidy_returned(), RESERVED_SUBSIDY);
    assert_eq!(refund.refund_escrow_returned(), MAX_COST);
    q.assert_invariants();
    q.finish();
}

#[test]
fun refund_counts_every_visited_record_and_resumes_inside_the_cohort() {
    // Three orders share one cohort. The middle one is admin-refunded first, so
    // a two-visit walk spends a visit on it and stops before the third order.
    let mut q = fixture::new_at(test_constants::short_expiry_ms());
    enqueue(&mut q);
    enqueue(&mut q);
    enqueue(&mut q);
    q.admin_refund(vector[1]);
    q.set_clock(DEADLINE);

    // Visits record 0 (refunded) and record 1 (already finished): one refund.
    assert_eq!(q.refund(VISIT_TWO), 1);
    assert_eq!(q.record(2).status(), order_queue::status_pending());
    // The walk stopped inside the cohort, so its first record moved to 2.
    let (resolve_head, next_id, _, _) = q.queue().queue_heads();
    assert_eq!(resolve_head, 2);
    assert_eq!(next_id, 3);

    // The next call resumes at record 2 and empties the cohort.
    assert_eq!(q.refund(VISIT_TWO), 1);
    assert_refunded_with(&q, 2, order_queue::reason_deadline(), DEADLINE);
    let (resolve_head, _, _, _) = q.queue().queue_heads();
    assert_eq!(resolve_head, 3);
    assert_pending(&q, 0, 0);
    q.assert_invariants();
    q.finish();
}

/// A walk asked for every record still stops after 450 visits, so one call's
/// refund events stay under Sui's per-transaction limit. The skipped IDs stand
/// in for visited records with nothing to do.
#[test]
fun refund_visits_at_most_450_records_per_call() {
    let mut q = fixture::new_at(test_constants::short_expiry_ms());
    let first = enqueue(&mut q);
    q.skip_record_ids(SKIPPED_IDS);
    let last = enqueue(&mut q);
    assert_eq!(last, SKIPPED_IDS + 1);
    let (cohorts, _, _) = q.queue().waiting_cohorts();
    assert_eq!(cohorts, 1);
    q.set_clock(DEADLINE);

    // Record 0 and the first 449 missing IDs use up the call.
    assert_eq!(q.refund(VISIT_UNBOUNDED), 1);
    assert_refunded_with(&q, first, order_queue::reason_deadline(), DEADLINE);
    assert_eq!(q.record(last).status(), order_queue::status_pending());
    let (resolve_head, _, _, _) = q.queue().queue_heads();
    assert_eq!(resolve_head, MAX_VISITS_PER_CALL);

    // The next call resumes there and reaches the last order.
    assert_eq!(q.refund(VISIT_UNBOUNDED), 1);
    assert_refunded_with(&q, last, order_queue::reason_deadline(), DEADLINE);
    assert_pending(&q, 0, 0);
    q.assert_invariants();
    q.finish();
}

#[test]
fun refund_of_an_empty_queue_returns_zero_even_while_frozen() {
    let mut q = fixture::new_at(test_constants::short_expiry_ms());
    q.set_frozen(true);

    assert_eq!(q.refund(VISIT_ALL), 0);
    let (resolve_head, next_id, _, _) = q.queue().queue_heads();
    assert_eq!(resolve_head, 0);
    assert_eq!(next_id, 0);
    assert!(events::refunds().is_empty());
    q.finish();
}

#[test]
fun admin_refund_refunds_listed_orders_with_reason_7_and_skips_the_rest() {
    let mut q = fixture::new_at(test_constants::short_expiry_ms());
    let account_id = q.account_id();
    enqueue(&mut q);
    enqueue(&mut q);

    // Before any deadline: record 1 is refunded once; the unknown ID and the
    // repeat of record 1 are skipped without aborting.
    q.admin_refund(vector[1, MISSING_RECORD_ID, 1]);
    assert_refunded_with(&q, 1, order_queue::reason_admin(), test_constants::now_ms());
    assert_eq!(q.record(0).status(), order_queue::status_pending());
    assert_pending(&q, 1, 0);
    assert_eq!(q.queue().waiting_orders(account_id), 1);
    // Record 0 still pins the shared boundary node.
    let (waiting_cash_need, nodes) = q.ledger();
    assert_eq!(waiting_cash_need, CASH_NEED);
    assert_eq!(nodes, 1);
    q.assert_invariants();

    let refunds = events::refunds();
    assert_eq!(refunds.length(), 1);
    assert_eq!(refunds[0].refund_record_id(), 1);
    assert_eq!(refunds[0].refund_reason(), order_queue::reason_admin());
    assert_eq!(refunds[0].refund_waiting_cash_need(), CASH_NEED);
    assert_eq!(refunds[0].refund_order_fee_returned(), ORDER_FEE);
    q.finish();
}

#[test]
fun admin_refund_runs_under_the_emergency_freeze() {
    let mut q = fixture::new_at(test_constants::short_expiry_ms());
    let record_id = enqueue(&mut q);
    q.set_frozen(true);
    q.admin_refund(vector[record_id]);

    assert_refunded_with(&q, record_id, order_queue::reason_admin(), test_constants::now_ms());
    assert_pending(&q, 0, 0);
    q.assert_invariants();
    q.finish();
}

#[test]
fun admin_refund_skips_a_filled_record() {
    let mut q = fixture::new_at(test_constants::short_expiry_ms());
    let record_id = enqueue(&mut q);
    q.commit_at(TAU, fixture::live_price());
    assert_eq!(q.resolve(VISIT_ALL), 1);
    assert_eq!(q.record(record_id).status(), order_queue::status_open());
    let mut q = q.next_tx(test_constants::alice());

    q.admin_refund(vector[record_id]);
    assert_eq!(q.record(record_id).status(), order_queue::status_open());
    assert!(events::refunds().is_empty());
    q.finish();
}

/// An admin refund of a waiting sell hands Predict's receipt back open, so the
/// sell's record returns to Open holding the whole position, with the order
/// fee returned.
#[test]
fun admin_refund_of_a_waiting_sell_returns_its_position() {
    let mut q = fixture::new_at(test_constants::short_expiry_ms());
    let mint_id = enqueue(&mut q);
    q.commit_at(TAU, fixture::live_price());
    q.resolve(VISIT_ALL);
    let held = q.record(mint_id).position();
    q.refresh_oracle_at(SELL_PLACED_AT);
    let sell_id = q.enqueue_sell(mint_id, QUANTITY, 0, 0);
    let (waiting_cash_need, _) = q.ledger();
    assert_eq!(waiting_cash_need, SELL_CASH_NEED);
    let mut q = q.next_tx(test_constants::alice());

    q.admin_refund(vector[sell_id]);

    let sell = q.record(sell_id);
    assert_eq!(sell.status(), order_queue::status_open());
    assert_eq!(sell.result().reason(), order_queue::reason_admin());
    assert_eq!(sell.position(), held);
    assert_eq!(sell.receipt_stage(), constants::receipt_stage_open!());
    assert_eq!(sell.funds(), 0);
    let (waiting_cash_need, _) = q.ledger();
    assert_eq!(waiting_cash_need, 0);
    let refund = events::refunds()[0];
    assert!(refund.refund_position_returned());
    assert_eq!(refund.refund_kind(), order_queue::kind_redeem_open());
    assert_eq!(refund.refund_escrow_returned(), 0);
    assert_eq!(refund.refund_order_fee_returned(), ORDER_FEE);
    // The position still sells again.
    let resell_id = q.enqueue_sell(sell_id, QUANTITY, 0, 0);
    assert_eq!(q.record(resell_id).position(), held);
    q.assert_invariants();
    q.finish();
}

// === RefundDue ===

/// A RefundDue mint with reason 1 refunds through `release` with that reason,
/// which keeps the order fee in market cash and returns the budget, as a
/// reason-1 refund out of `try_fill` does.
#[test]
fun a_refund_due_mint_with_reason_1_keeps_the_order_fee_in_market_cash() {
    let mut q = fixture::new_at(test_constants::short_expiry_ms());
    let account_id = q.account_id();
    let record_id = enqueue(&mut q);
    q.commit_at(TAU, fixture::live_price());
    q.mark_refund_due(record_id, order_queue::reason_limits());
    let cash_before = q.market().cash_balance();

    assert_eq!(q.resolve(VISIT_ALL), 1);

    assert_refunded_with(&q, record_id, order_queue::reason_limits(), TAU);
    assert_eq!(q.market().cash_balance(), cash_before + ORDER_FEE);
    assert_pending(&q, 0, 0);
    assert_eq!(q.queue().waiting_orders(account_id), 0);
    let (waiting_cash_need, nodes) = q.ledger();
    assert_eq!(waiting_cash_need, 0);
    assert_eq!(nodes, 0);
    let refunds = events::refunds();
    assert_eq!(refunds.length(), 1);
    let refund = refunds[0];
    assert_eq!(refund.refund_reason(), order_queue::reason_limits());
    assert_eq!(refund.refund_escrow_returned(), MAX_COST);
    assert_eq!(refund.refund_order_fee_returned(), 0);
    assert_eq!(refund.refund_market_cash(), cash_before + ORDER_FEE);
    q.assert_invariants();
    q.finish();
}

/// A RefundDue sell with reason 2 keeps its order fee too, whichever refund
/// reaches it (here the admin's, whose reason 7 the stored reason replaces),
/// and returns its position to the record.
#[test]
fun a_refund_due_sell_with_reason_2_keeps_the_fee_and_returns_its_position() {
    let mut q = fixture::new_at(test_constants::short_expiry_ms());
    let mint_id = enqueue(&mut q);
    q.commit_at(TAU, fixture::live_price());
    q.resolve(VISIT_ALL);
    let held = q.record(mint_id).position();
    q.refresh_oracle_at(SELL_PLACED_AT);
    let sell_id = q.enqueue_sell(mint_id, QUANTITY, 0, 0);
    q.mark_refund_due(sell_id, order_queue::reason_admission());
    let mut q = q.next_tx(test_constants::alice());
    let cash_before = q.market().cash_balance();

    q.admin_refund(vector[sell_id]);

    let sell = q.record(sell_id);
    assert_eq!(sell.status(), order_queue::status_open());
    assert_eq!(sell.result().reason(), order_queue::reason_admission());
    assert_eq!(sell.position(), held);
    assert_eq!(sell.receipt_stage(), constants::receipt_stage_open!());
    assert_eq!(sell.funds(), 0);
    assert_eq!(q.market().cash_balance(), cash_before + ORDER_FEE);
    let refund = events::refunds()[0];
    assert_eq!(refund.refund_reason(), order_queue::reason_admission());
    assert!(refund.refund_position_returned());
    assert_eq!(refund.refund_escrow_returned(), 0);
    assert_eq!(refund.refund_order_fee_returned(), 0);
    q.assert_invariants();
    q.finish();
}

/// Keeping the fee moves market cash, so like a fill it refuses the keeper's
/// open snapshot stage.
#[test, expected_failure(abort_code = protocol_config::ESnapshotInProgress)]
fun a_fee_keeping_refund_inside_the_snapshot_stage_aborts() {
    let mut q = fixture::new_with_pool(SUPPLY_AMOUNT);
    let record_id = q.enqueue_atm(SMALL_QUANTITY, SMALL_MAX_COST);
    q.commit_at(TAU, fixture::live_price());
    q.mark_refund_due(record_id, order_queue::reason_limits());
    let stage = q.start_snapshot();
    q.resolve(VISIT_ALL);
    destroy(stage);
    abort 999
}

// === Helpers ===

fun enqueue(q: &mut QueueTest): u64 {
    q.enqueue_atm(QUANTITY, MAX_COST)
}

fun assert_pending(q: &QueueTest, mints: u64, sells: u64) {
    let (pending_mints, pending_sells) = q.queue().pending_counts();
    assert_eq!(pending_mints, mints);
    assert_eq!(pending_sells, sells);
}

/// A mint refunded with `reason` at `finished_at_ms`: Refunded, with no receipt
/// and no escrow left in the record.
fun assert_refunded_with(q: &QueueTest, record_id: u64, reason: u8, finished_at_ms: u64) {
    let record = q.record(record_id);
    assert_eq!(record.status(), order_queue::status_refunded());
    assert_eq!(record.result().reason(), reason);
    assert_eq!(record.result().result_quantity(), 0);
    assert_eq!(record.result().result_amount(), 0);
    assert_eq!(record.result().finished_at_ms(), finished_at_ms);
    assert_eq!(record.receipt_stage(), 0);
    assert_eq!(record.funds(), 0);
}
