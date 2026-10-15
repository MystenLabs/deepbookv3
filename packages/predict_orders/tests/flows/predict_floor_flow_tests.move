// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Predict's version floor above the Predict version this companion links: a
/// Predict floor bumped before the companion relinked. Every walker that calls
/// one of Predict's primitives aborts at Predict's floor and moves nothing,
/// while `cleanup`, the queue reads, and `quote_redeem_open`, which only read
/// Predict, keep working and the waiting escrow stays where it was. Restoring
/// the floor (the relink's stand-in here) lets refunds and settlement finish.
///
/// Orders are 100m mints over `(strike, +inf]` with a 90 USDC budget on the
/// short-expiry market (expiry 240_000). A placement at 120_000 lands on τ
/// 121_000; one at 120_999 on τ 121_800, deadline 126_800.
#[test_only]
module deepbook_predict_orders::predict_floor_flow_tests;

use deepbook_predict::{constants, flow_test_helpers as helpers, protocol_config, test_constants};
use deepbook_predict_orders::{
    order_queue,
    queue,
    queue_event_views as events,
    queue_fixture::{Self as fixture, QueueTest}
};
use std::unit_test::assert_eq;

const QUANTITY: u64 = 100_000_000;
const MAX_COST: u64 = 90_000_000;
/// The 90m budget and the 0.02 USDC order fee.
const ESCROW: u64 = 90_020_000;
const TAU: u64 = 121_000;
const SECOND_PLACED_AT: u64 = 120_999;
const SECOND_DEADLINE: u64 = 126_800;
const DEADLINE: u64 = 126_000;
const EXPIRY: u64 = 240_000;
const MAX_ORDERS: u64 = 100;

// === Walkers abort ===

#[test, expected_failure(abort_code = protocol_config::EPackageVersionDisabled)]
fun resolve_aborts_above_predicts_floor() {
    let mut q = new();
    q.enqueue_atm(QUANTITY, MAX_COST);
    q.commit_at(TAU, fixture::live_price());
    raise_floor(&mut q);
    q.resolve(MAX_ORDERS);
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EPackageVersionDisabled)]
fun refund_aborts_above_predicts_floor() {
    let mut q = new();
    q.enqueue_atm(QUANTITY, MAX_COST);
    raise_floor(&mut q);
    q.set_clock(DEADLINE);
    q.refund(MAX_ORDERS);
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EPackageVersionDisabled)]
fun admin_refund_aborts_above_predicts_floor() {
    let mut q = new();
    let record_id = q.enqueue_atm(QUANTITY, MAX_COST);
    raise_floor(&mut q);
    q.admin_refund(vector[record_id]);
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EPackageVersionDisabled)]
fun settle_step_aborts_above_predicts_floor() {
    let mut q = new();
    q.enqueue_atm(QUANTITY, MAX_COST);
    q.set_clock(EXPIRY);
    raise_floor(&mut q);
    q.settle_step();
    abort 999
}

// === Reads keep working ===

/// Before expiry: the queue reads and the sell quote work above the floor and
/// the waiting order's escrow is untouched. Once the floor is restored the
/// deadline refund runs.
#[test]
fun reads_and_the_sell_quote_work_above_the_floor_and_refunds_resume_once_restored() {
    let mut q = new();
    let filled = q.enqueue_atm(QUANTITY, MAX_COST);
    q.refresh_oracle_at(SECOND_PLACED_AT);
    let waiting = q.enqueue_atm(QUANTITY, MAX_COST);
    q.commit_at(TAU, fixture::live_price());
    assert_eq!(q.resolve(MAX_ORDERS), 1);
    raise_floor(&mut q);

    let record = q.record(waiting);
    assert_eq!(record.status(), order_queue::status_pending());
    assert_eq!(record.funds(), ESCROW);
    let (pending_mints, pending_sells) = q.queue().pending_counts();
    assert_eq!(pending_mints, 1);
    assert_eq!(pending_sells, 0);
    let pricer = q.load_pricer();
    let quote = q.quote_redeem_open(&pricer, filled, QUANTITY);
    assert_eq!(quote.redeem_close_quantity(), QUANTITY);
    assert_eq!(q.record(filled).status(), order_queue::status_open());
    q.assert_invariants();

    restore_floor(&mut q);
    q.set_clock(SECOND_DEADLINE);
    assert_eq!(q.refund(MAX_ORDERS), 1);
    assert_eq!(q.record(waiting).status(), order_queue::status_refunded());
    assert_eq!(q.record(waiting).funds(), 0);
    q.finish();
}

/// After settlement: `cleanup` works above the floor and the escrow still
/// waits. Once the floor is restored the drain refunds it and the payout walk
/// pays the winner, completing the queue.
#[test]
fun cleanup_works_above_the_floor_and_settlement_finishes_once_restored() {
    let mut q = new();
    let refunded = q.enqueue_atm(QUANTITY, MAX_COST);
    let filled = q.enqueue_atm(QUANTITY, MAX_COST);
    q.admin_refund(vector[refunded]);
    q.refresh_oracle_at(SECOND_PLACED_AT);
    let waiting = q.enqueue_atm(QUANTITY, MAX_COST);
    q.commit_at(TAU, fixture::live_price());
    assert_eq!(q.resolve(MAX_ORDERS), 1);
    q.settle_market(spot_above_strike());
    raise_floor(&mut q);

    q.cleanup(vector[refunded]);
    assert!(q.queue().order(refunded).is_none());
    assert_eq!(q.record(waiting).funds(), ESCROW);
    assert_eq!(q.record(filled).status(), order_queue::status_open());

    restore_floor(&mut q);
    assert_eq!(q.settle_step(), queue::phase_pay());
    assert_eq!(q.record(waiting).status(), order_queue::status_refunded());
    assert_eq!(q.record(waiting).funds(), 0);
    assert_eq!(q.settle_step(), queue::phase_done());
    assert_eq!(q.record(filled).status(), order_queue::status_closed());
    assert_eq!(events::settled()[0].payout(), QUANTITY);
    assert_eq!(events::payouts_completed_count(), 1);
    q.finish();
}

// === Helpers ===

fun new(): QueueTest {
    fixture::new_at(test_constants::short_expiry_ms())
}

fun raise_floor(q: &mut QueueTest) {
    q.set_predict_floor(constants::current_version!() + 1);
}

fun restore_floor(q: &mut QueueTest) {
    q.set_predict_floor(constants::current_version!());
}

/// Settlement spot one tick above the strike: inside `(strike, +inf]`.
fun spot_above_strike(): u64 {
    (helpers::strike_tick() + 1) * test_constants::default_tick_size()
}
