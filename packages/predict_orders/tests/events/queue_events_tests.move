// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Wire layouts of the companion's queue events. Each emitter is called with a
/// distinct value per field, and the event's BCS bytes are compared with a
/// local struct that spells out the published field order, so a reordered,
/// retyped, or dropped field fails here before it freezes at publish.
/// `DelayedExecutionPolicyUpdated` is pinned by the desk policy tests.
#[test_only]
module deepbook_predict_orders::queue_events_tests;

use deepbook_predict::pricing::{Self, VolSnapshot};
use deepbook_predict_orders::{
    order_queue::{Self, HeldPosition, OrderRequest, OrderTiming},
    order_queue_test_helpers as h,
    queue_events
};
use fixed_math::i64;
use std::{bcs, unit_test::{assert_eq, destroy}};
use sui::event;

const ONE_EVENT: u64 = 1;
const FIRST: u64 = 0;
const SENDER: address = @0x5E;
const ONCHAIN_MS: u64 = 1_750_000_000_123;

public struct ExpectedOrderEnqueued has copy, drop {
    expiry_market_id: ID,
    record_id: u64,
    account_id: ID,
    kind: u8,
    request: OrderRequest,
    position: HeldPosition,
    timing: OrderTiming,
    vol: VolSnapshot,
    budget: u64,
    order_fee: u64,
    cash_need: u64,
    subsidy_bound: u64,
    builder_code_id: Option<ID>,
    referrer_account_id: Option<ID>,
    source_record_id: Option<u64>,
    market_cash: u64,
    required_cash: u64,
    waiting_cash_need: u64,
    onchain_timestamp_ms: u64,
}

public struct ExpectedCohortCommitted has copy, drop {
    expiry_market_id: ID,
    tau_ms: u64,
    tick_ms: u64,
    first_record_id: u64,
    last_record_id: u64,
    spot: u64,
    generation_us: u64,
    pyth_source_id: u32,
    pyth_channel: u8,
    sender: address,
    onchain_timestamp_ms: u64,
}

public struct ExpectedQueuedOrderFilled has copy, drop {
    market_cash: u64,
    required_cash: u64,
    waiting_cash_need: u64,
    expiry_market_id: ID,
    record_id: u64,
    account_id: ID,
    kind: u8,
    quantity: u64,
    amount: u64,
    trading_fee: u64,
    builder_fee: u64,
    referral_fee: u64,
    order_fee: u64,
    subsidy_used: u64,
    inventory_impact: u64,
    tau_ms: u64,
    tick_ms: u64,
    position: HeldPosition,
    sender: address,
    onchain_timestamp_ms: u64,
}

public struct ExpectedQueuedOrderRefunded has copy, drop {
    market_cash: u64,
    required_cash: u64,
    waiting_cash_need: u64,
    expiry_market_id: ID,
    record_id: u64,
    account_id: ID,
    kind: u8,
    reason: u8,
    escrow_returned: u64,
    order_fee_returned: u64,
    subsidy_returned: u64,
    position_returned: bool,
    sender: address,
    onchain_timestamp_ms: u64,
}

public struct ExpectedRecordIds has copy, drop {
    expiry_market_id: ID,
    record_ids: vector<u64>,
    onchain_timestamp_ms: u64,
}

public struct ExpectedOpenRecordPayout has copy, drop {
    expiry_market_id: ID,
    record_id: u64,
    account_id: ID,
    order_id: u256,
    payout: u64,
    onchain_timestamp_ms: u64,
}

public struct ExpectedMarketPayoutsCompleted has copy, drop {
    expiry_market_id: ID,
    onchain_timestamp_ms: u64,
}

#[test]
fun order_enqueued_layout() {
    let ctx = &mut tx_context::dummy();
    let book = order_queue::new_book(ctx);
    let request = order_queue::new_request(1, 2, 3, 4, 5, 6, 7, 8, 9);
    let position = order_queue::new_held_position(10, 11, 12);
    let timing = book.plan_timing(&h::default_policy(), h::expiry_ms(), 0, h::base_ms());
    let vol = pricing::new_vol_snapshot_for_testing(
        30,
        31,
        32,
        i64::from_parts(33, true),
        34,
        i64::from_parts(35, false),
        i64::from_parts(36, true),
        37,
        38,
        39,
        40,
    );
    let expected = ExpectedOrderEnqueued {
        expiry_market_id: market_id(),
        record_id: 13,
        account_id: h::account(0),
        kind: order_queue::kind_redeem_open(),
        request,
        position,
        timing,
        vol,
        budget: 14,
        order_fee: 15,
        cash_need: 16,
        subsidy_bound: 17,
        builder_code_id: option::some(h::account(1)),
        referrer_account_id: option::some(h::account(2)),
        source_record_id: option::some(18),
        market_cash: 19,
        required_cash: 20,
        waiting_cash_need: 21,
        onchain_timestamp_ms: ONCHAIN_MS,
    };

    queue_events::emit_order_enqueued(
        expected.expiry_market_id,
        expected.record_id,
        expected.account_id,
        expected.kind,
        request,
        position,
        timing,
        vol,
        expected.budget,
        expected.order_fee,
        expected.cash_need,
        expected.subsidy_bound,
        expected.builder_code_id,
        expected.referrer_account_id,
        expected.source_record_id,
        expected.market_cash,
        expected.required_cash,
        expected.waiting_cash_need,
        expected.onchain_timestamp_ms,
    );

    let events = event::events_by_type<queue_events::OrderEnqueued>();
    assert_eq!(events.length(), ONE_EVENT);
    assert_eq!(bcs::to_bytes(&events[FIRST]), bcs::to_bytes(&expected));
    destroy(book);
}

#[test]
fun cohort_committed_layout() {
    let expected = ExpectedCohortCommitted {
        expiry_market_id: market_id(),
        tau_ms: 1,
        tick_ms: 2,
        first_record_id: 3,
        last_record_id: 4,
        spot: 5,
        generation_us: 6,
        pyth_source_id: 7,
        pyth_channel: 8,
        sender: SENDER,
        onchain_timestamp_ms: ONCHAIN_MS,
    };

    queue_events::emit_cohort_committed(
        expected.expiry_market_id,
        expected.tau_ms,
        expected.tick_ms,
        expected.first_record_id,
        expected.last_record_id,
        expected.spot,
        expected.generation_us,
        expected.pyth_source_id,
        expected.pyth_channel,
        expected.sender,
        expected.onchain_timestamp_ms,
    );

    let events = event::events_by_type<queue_events::CohortCommitted>();
    assert_eq!(events.length(), ONE_EVENT);
    assert_eq!(bcs::to_bytes(&events[FIRST]), bcs::to_bytes(&expected));
}

#[test]
fun queued_order_filled_layout() {
    let expected = ExpectedQueuedOrderFilled {
        market_cash: 1,
        required_cash: 2,
        waiting_cash_need: 3,
        expiry_market_id: market_id(),
        record_id: 4,
        account_id: h::account(0),
        kind: order_queue::kind_exact_cost(),
        quantity: 5,
        amount: 6,
        trading_fee: 7,
        builder_fee: 8,
        referral_fee: 9,
        order_fee: 10,
        subsidy_used: 11,
        inventory_impact: 12,
        tau_ms: 13,
        tick_ms: 14,
        position: order_queue::new_held_position(15, 16, 17),
        sender: SENDER,
        onchain_timestamp_ms: ONCHAIN_MS,
    };

    queue_events::emit_queued_order_filled(
        expected.market_cash,
        expected.required_cash,
        expected.waiting_cash_need,
        expected.expiry_market_id,
        expected.record_id,
        expected.account_id,
        expected.kind,
        expected.quantity,
        expected.amount,
        expected.trading_fee,
        expected.builder_fee,
        expected.referral_fee,
        expected.order_fee,
        expected.subsidy_used,
        expected.inventory_impact,
        expected.tau_ms,
        expected.tick_ms,
        expected.position,
        expected.sender,
        expected.onchain_timestamp_ms,
    );

    let events = event::events_by_type<queue_events::QueuedOrderFilled>();
    assert_eq!(events.length(), ONE_EVENT);
    assert_eq!(bcs::to_bytes(&events[FIRST]), bcs::to_bytes(&expected));
}

#[test]
fun queued_order_refunded_layout() {
    let expected = ExpectedQueuedOrderRefunded {
        market_cash: 1,
        required_cash: 2,
        waiting_cash_need: 3,
        expiry_market_id: market_id(),
        record_id: 4,
        account_id: h::account(0),
        kind: order_queue::kind_redeem_open(),
        reason: order_queue::reason_no_cash(),
        escrow_returned: 5,
        order_fee_returned: 6,
        subsidy_returned: 7,
        position_returned: true,
        sender: SENDER,
        onchain_timestamp_ms: ONCHAIN_MS,
    };

    queue_events::emit_queued_order_refunded(
        expected.market_cash,
        expected.required_cash,
        expected.waiting_cash_need,
        expected.expiry_market_id,
        expected.record_id,
        expected.account_id,
        expected.kind,
        expected.reason,
        expected.escrow_returned,
        expected.order_fee_returned,
        expected.subsidy_returned,
        expected.position_returned,
        expected.sender,
        expected.onchain_timestamp_ms,
    );

    let events = event::events_by_type<queue_events::QueuedOrderRefunded>();
    assert_eq!(events.length(), ONE_EVENT);
    assert_eq!(bcs::to_bytes(&events[FIRST]), bcs::to_bytes(&expected));
}

#[test]
fun queued_orders_cleaned_layout() {
    let expected = ExpectedRecordIds {
        expiry_market_id: market_id(),
        record_ids: vector[1, 2],
        onchain_timestamp_ms: ONCHAIN_MS,
    };

    queue_events::emit_queued_orders_cleaned(
        expected.expiry_market_id,
        expected.record_ids,
        expected.onchain_timestamp_ms,
    );

    let events = event::events_by_type<queue_events::QueuedOrdersCleaned>();
    assert_eq!(events.length(), ONE_EVENT);
    assert_eq!(bcs::to_bytes(&events[FIRST]), bcs::to_bytes(&expected));
}

#[test]
fun open_record_settled_and_skipped_layouts() {
    let settled = ExpectedOpenRecordPayout {
        expiry_market_id: market_id(),
        record_id: 1,
        account_id: h::account(0),
        order_id: 2,
        payout: 3,
        onchain_timestamp_ms: ONCHAIN_MS,
    };
    let skipped = ExpectedOpenRecordPayout {
        expiry_market_id: market_id(),
        record_id: 4,
        account_id: h::account(1),
        order_id: 5,
        payout: 6,
        onchain_timestamp_ms: ONCHAIN_MS + 1,
    };

    queue_events::emit_open_record_settled(
        settled.expiry_market_id,
        settled.record_id,
        settled.account_id,
        settled.order_id,
        settled.payout,
        settled.onchain_timestamp_ms,
    );
    queue_events::emit_open_record_payout_skipped(
        skipped.expiry_market_id,
        skipped.record_id,
        skipped.account_id,
        skipped.order_id,
        skipped.payout,
        skipped.onchain_timestamp_ms,
    );

    let settled_events = event::events_by_type<queue_events::OpenRecordSettled>();
    assert_eq!(settled_events.length(), ONE_EVENT);
    assert_eq!(bcs::to_bytes(&settled_events[FIRST]), bcs::to_bytes(&settled));
    let skipped_events = event::events_by_type<queue_events::OpenRecordPayoutSkipped>();
    assert_eq!(skipped_events.length(), ONE_EVENT);
    assert_eq!(bcs::to_bytes(&skipped_events[FIRST]), bcs::to_bytes(&skipped));
}

#[test]
fun market_payouts_completed_layout() {
    let expected = ExpectedMarketPayoutsCompleted {
        expiry_market_id: market_id(),
        onchain_timestamp_ms: ONCHAIN_MS,
    };

    queue_events::emit_market_payouts_completed(
        expected.expiry_market_id,
        expected.onchain_timestamp_ms,
    );

    let events = event::events_by_type<queue_events::MarketPayoutsCompleted>();
    assert_eq!(events.length(), ONE_EVENT);
    assert_eq!(bcs::to_bytes(&events[FIRST]), bcs::to_bytes(&expected));
}

fun market_id(): ID {
    object::id_from_address(@0xE1)
}
