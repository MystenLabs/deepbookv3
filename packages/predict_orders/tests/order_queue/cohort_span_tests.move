// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Record, span, and counter bookkeeping: append, commit, finishing an order,
/// the walker resume, `advance_heads`, and the settlement and cleanup
/// primitives. Orders are placed with the fixture policy (delay 1_000 on 200
/// ms, stall 5_000): an order at `BASE + k * 200` gets τ = `BASE + 1_000 + k *
/// 200` and D = τ + 5_000. The records hold no receipt (see
/// `order_queue_test_helpers`); Predict's pins and waiting cash need, and the
/// escrow a record holds, are covered by the flow suites.
#[test_only]
module deepbook_predict_orders::cohort_span_tests;

use deepbook_predict_orders::{order_queue::{Self, OrderBook}, order_queue_test_helpers as h};
use std::unit_test::{assert_eq, destroy};
use sui::balance;

const BASE: u64 = 1_000_000_000;
const TAU_0: u64 = 1_000_001_000;
const DEADLINE_0: u64 = 1_000_006_000;
const TAU_1: u64 = 1_000_001_200;
const TAU_2: u64 = 1_000_001_400;
const FILL_MS: u64 = 1_000_001_500;
const US_PER_MS: u64 = 1_000;

const BUDGET: u64 = 1_000_000;
const ORDER_FEE: u64 = 20_000;
/// The exact-quantity cash need of 1_000_000 at p_min 0.01: ceil(0.99 * 1m) + 1.
const MINT_CASH_NEED: u64 = 990_001;
const SELL_QUANTITY: u64 = 5_000_000;
/// ceil(5_000_000 * 0.69) + 1.
const SELL_CASH_NEED: u64 = 3_450_001;
const SELL_ORDER_ID: u256 = 555;
const SELL_ROOT_ID: u256 = 444;
const SELL_OPENED_AT: u64 = 12_345;
const OTHER_TICK: u64 = 300;

const FILLED_ORDER_ID: u256 = 777;
const FILLED_QUANTITY: u64 = 5_000_000;
const FILLED_COST: u64 = 980_000;
const SELL_PROCEEDS: u64 = 3_000_000;
const RESERVATION: u64 = 300;
const COMMITTED_SPOT: u64 = 50_000_000_000;

// === append ===

#[test]
fun the_first_mint_opens_a_span_and_counts_itself() {
    let ctx = &mut tx_context::dummy();
    let mut book = order_queue::new_book(ctx);

    let id = place_mint(&mut book, BASE, h::account(0), h::lower_tick(), h::higher_tick());

    assert_eq!(id, 0);
    assert_eq!(book.next_id(), 1);
    assert_eq!(book.resolve_head(), 0);
    assert_eq!(book.last_tau_ms(), TAU_0);
    assert_eq!(book.cohort_count(), 1);
    let span = book.cohort(0);
    assert_eq!(span.span_tau_ms(), TAU_0);
    assert_eq!(span.span_deadline_ms(), DEADLINE_0);
    assert_eq!(span.span_first_id(), 0);
    assert_eq!(span.span_end_id(), 1);
    assert_eq!(span.span_pyth_channel(), h::channel_200ms());
    assert!(!span.span_committed());
    assert_eq!(span.span_unfinished(), 1);
    assert_eq!(book.pending_mints(), 1);
    assert_eq!(book.pending_sells(), 0);
    assert_eq!(book.account_waiting(h::account(0)), 1);
    assert_eq!(book.account_waiting(h::account(1)), 0);
    let record = book.view(id).destroy_some();
    assert_eq!(record.status(), order_queue::status_pending());
    assert_eq!(record.kind(), order_queue::kind_exact_quantity());
    assert_eq!(record.timing().tau_ms(), TAU_0);
    assert_eq!(record.escrow().cash_need(), MINT_CASH_NEED);
    assert_eq!(record.result().reason(), 0);
    assert_eq!(record.receive_address(), h::receive_address());
    assert_eq!(record.receipt_stage(), 0);
    assert_eq!(record.funds(), 0);
    destroy(book);
}

#[test]
fun the_same_tau_extends_the_last_span_and_a_later_tau_opens_one() {
    let ctx = &mut tx_context::dummy();
    let mut book = order_queue::new_book(ctx);

    place_mint(&mut book, BASE, h::account(0), h::lower_tick(), h::higher_tick());
    place_mint(&mut book, BASE, h::account(1), h::lower_tick(), OTHER_TICK);

    assert_eq!(book.cohort_count(), 1);
    assert_eq!(book.cohort(0).span_end_id(), 2);
    assert_eq!(book.cohort(0).span_unfinished(), 2);

    let id = place_mint(&mut book, BASE + 200, h::account(0), h::lower_tick(), h::higher_tick());

    assert_eq!(id, 2);
    assert_eq!(book.cohort_count(), 2);
    let span = book.cohort(1);
    assert_eq!(span.span_tau_ms(), TAU_1);
    assert_eq!(span.span_first_id(), 2);
    assert_eq!(span.span_end_id(), 3);
    assert_eq!(span.span_unfinished(), 1);
    assert_eq!(book.pending_mints(), 3);
    assert_eq!(book.account_waiting(h::account(0)), 2);
    assert_eq!(book.account_waiting(h::account(1)), 1);
    destroy(book);
}

#[test]
fun a_sell_counts_as_a_sell_and_holds_its_position() {
    let ctx = &mut tx_context::dummy();
    let mut book = order_queue::new_book(ctx);

    let id = place_sell(&mut book, BASE);

    assert_eq!(book.pending_sells(), 1);
    assert_eq!(book.pending_mints(), 0);
    let record = book.view(id).destroy_some();
    assert_eq!(record.kind(), order_queue::kind_redeem_open());
    assert_eq!(record.escrow().cash_need(), SELL_CASH_NEED);
    assert_eq!(record.position().order_id(), SELL_ORDER_ID);
    assert_eq!(record.position().root_id(), SELL_ROOT_ID);
    assert_eq!(record.position().opened_at_ms(), SELL_OPENED_AT);
    destroy(book);
}

// === Commit ===

#[test]
fun commit_order_prices_a_record_and_escrows_its_subsidy() {
    let ctx = &mut tx_context::dummy();
    let mut book = order_queue::new_book(ctx);
    let id = place_mint(&mut book, BASE, h::account(0), h::lower_tick(), h::higher_tick());

    let generation_us = TAU_0 * US_PER_MS;
    book.commit_order(
        id,
        order_queue::new_committed_price(COMMITTED_SPOT, TAU_0, generation_us),
        balance::create_for_testing(RESERVATION),
    );

    let record = book.view(id).destroy_some();
    assert_eq!(record.status(), order_queue::status_committed());
    assert_eq!(record.price().spot(), COMMITTED_SPOT);
    assert_eq!(record.price().tick_ms(), TAU_0);
    assert_eq!(record.price().generation_us(), generation_us);
    assert_eq!(record.escrow().subsidy_reserved(), RESERVATION);
    // The reservation joined the record's own escrow.
    assert_eq!(record.funds(), RESERVATION);
    destroy(book);
}

#[test]
fun marking_cohorts_committed_raises_last_committed_and_never_lowers_it() {
    let ctx = &mut tx_context::dummy();
    let mut book = order_queue::new_book(ctx);
    place_mint(&mut book, BASE, h::account(0), h::lower_tick(), h::higher_tick());
    place_mint(&mut book, BASE + 200, h::account(0), h::lower_tick(), h::higher_tick());

    book.mark_cohort_committed(1);
    assert_eq!(book.last_committed_tau_ms(), TAU_1);
    assert!(!book.cohort(0).span_committed());
    assert!(book.cohort(1).span_committed());
    assert_eq!(book.oldest_uncommitted_tau(), option::some(TAU_0));
    // The stuck gate's first rule only watches cohorts above the last commit.
    assert_eq!(book.oldest_uncommitted_tau_above_committed(), option::none());

    book.mark_cohort_committed(0);
    assert_eq!(book.last_committed_tau_ms(), TAU_1);
    assert!(book.cohort(0).span_committed());
    assert_eq!(book.oldest_uncommitted_tau(), option::none());
    destroy(book);
}

// === Finishing ===

#[test]
fun finish_order_opens_a_mint_and_releases_its_counts_exactly_once() {
    let ctx = &mut tx_context::dummy();
    let mut book = order_queue::new_book(ctx);
    let id = place_mint(&mut book, BASE, h::account(0), h::lower_tick(), h::higher_tick());
    place_mint(&mut book, BASE, h::account(1), h::lower_tick(), OTHER_TICK);
    let position = order_queue::new_held_position(FILLED_ORDER_ID, FILLED_ORDER_ID, TAU_0);

    book.finish_order(
        id,
        order_queue::status_open(),
        option::none(),
        position,
        0,
        FILLED_QUANTITY,
        FILLED_COST,
        true,
        FILL_MS,
    );

    let record = book.view(id).destroy_some();
    assert_eq!(record.status(), order_queue::status_open());
    assert_eq!(record.position().order_id(), FILLED_ORDER_ID);
    assert_eq!(record.position().opened_at_ms(), TAU_0);
    assert_eq!(record.result().reason(), 0);
    assert_eq!(record.result().result_quantity(), FILLED_QUANTITY);
    assert_eq!(record.result().result_amount(), FILLED_COST);
    assert_eq!(record.result().finished_at_ms(), FILL_MS);
    // Only the other mint is left.
    assert_eq!(book.pending_mints(), 1);
    assert_eq!(book.account_waiting(h::account(0)), 0);
    assert_eq!(book.account_waiting(h::account(1)), 1);
    assert_eq!(book.cohort(0).span_unfinished(), 1);
    destroy(book);
}

/// The settlement drain finishes orders without touching the account rows.
#[test]
fun finish_order_without_the_account_row_leaves_it() {
    let ctx = &mut tx_context::dummy();
    let mut book = order_queue::new_book(ctx);
    let id = place_mint(&mut book, BASE, h::account(0), h::lower_tick(), h::higher_tick());

    book.finish_order(
        id,
        order_queue::status_refunded(),
        option::none(),
        order_queue::empty_position(),
        order_queue::reason_deadline(),
        0,
        0,
        false,
        FILL_MS,
    );

    assert_eq!(book.pending_mints(), 0);
    assert_eq!(book.cohort(0).span_unfinished(), 0);
    assert_eq!(book.account_waiting(h::account(0)), 1);
    assert_eq!(book.view(id).destroy_some().result().reason(), order_queue::reason_deadline());
    destroy(book);
}

#[test]
fun finish_order_closes_a_full_sell() {
    let ctx = &mut tx_context::dummy();
    let mut book = order_queue::new_book(ctx);
    let id = place_sell(&mut book, BASE);

    book.finish_order(
        id,
        order_queue::status_closed(),
        option::none(),
        order_queue::empty_position(),
        0,
        SELL_QUANTITY,
        SELL_PROCEEDS,
        true,
        FILL_MS,
    );

    let record = book.view(id).destroy_some();
    assert_eq!(record.status(), order_queue::status_closed());
    assert_eq!(record.position().order_id(), 0);
    assert_eq!(record.result().result_amount(), SELL_PROCEEDS);
    assert_eq!(book.pending_sells(), 0);
    assert_eq!(book.account_waiting(h::account(0)), 0);
    assert_eq!(book.cohort(0).span_unfinished(), 0);
    destroy(book);
}

#[test, expected_failure(abort_code = order_queue::ERecordNotOpen)]
fun close_open_record_of_a_pending_record_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut book = order_queue::new_book(ctx);
    let id = place_mint(&mut book, BASE, h::account(0), h::lower_tick(), h::higher_tick());
    let (receipt, _) = book.close_open_record(id);
    destroy(receipt);
    abort 999
}

#[test, expected_failure(abort_code = order_queue::ERecordNotOpen)]
fun close_open_record_of_a_missing_record_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut book = order_queue::new_book(ctx);
    let (receipt, _) = book.close_open_record(0);
    destroy(receipt);
    abort 999
}

// === Walkers ===

#[test]
fun orders_finish_in_any_order_and_the_span_goes_only_after_the_last() {
    let ctx = &mut tx_context::dummy();
    let mut book = order_queue::new_book(ctx);
    let first = place_mint(&mut book, BASE, h::account(0), h::lower_tick(), h::higher_tick());
    let second = place_mint(&mut book, BASE, h::account(0), h::lower_tick(), h::higher_tick());
    let third = place_mint(&mut book, BASE, h::account(0), h::lower_tick(), h::higher_tick());

    fill_mint(&mut book, third);
    book.advance_heads();
    assert_eq!(book.cohort_count(), 1);
    assert_eq!(book.cohort(0).span_unfinished(), 2);
    assert_eq!(book.resolve_head(), 0);

    fill_mint(&mut book, first);
    book.advance_heads();
    assert_eq!(book.cohort(0).span_unfinished(), 1);
    // A finished order alone does not move first_id.
    assert_eq!(book.resolve_head(), 0);
    assert_eq!(book.oldest_unfinished_tau(), option::some(TAU_0));

    fill_mint(&mut book, second);
    book.advance_heads();
    assert_eq!(book.cohort_count(), 0);
    assert_eq!(book.resolve_head(), 3);
    assert_eq!(book.oldest_unfinished_tau(), option::none());
    destroy(book);
}

#[test]
fun advance_heads_drops_a_finished_span_from_the_middle() {
    let ctx = &mut tx_context::dummy();
    let mut book = order_queue::new_book(ctx);
    let a = place_mint(&mut book, BASE, h::account(0), h::lower_tick(), h::higher_tick());
    let b = place_mint(&mut book, BASE + 200, h::account(0), h::lower_tick(), h::higher_tick());
    place_mint(&mut book, BASE + 400, h::account(0), h::lower_tick(), h::higher_tick());

    fill_mint(&mut book, b);
    book.advance_heads();

    assert_eq!(book.cohort_count(), 2);
    assert_eq!(book.cohort(0).span_tau_ms(), TAU_0);
    assert_eq!(book.cohort(1).span_tau_ms(), TAU_2);
    assert_eq!(book.cohort(1).span_first_id(), 2);
    assert_eq!(book.resolve_head(), 0);

    fill_mint(&mut book, a);
    book.advance_heads();
    assert_eq!(book.cohort_count(), 1);
    assert_eq!(book.resolve_head(), 2);
    destroy(book);
}

#[test]
fun a_walker_moves_first_id_forward_only_and_never_past_the_span_end() {
    let ctx = &mut tx_context::dummy();
    let mut book = order_queue::new_book(ctx);
    let first = place_mint(&mut book, BASE, h::account(0), h::lower_tick(), h::higher_tick());
    let second = place_mint(&mut book, BASE, h::account(0), h::lower_tick(), h::higher_tick());
    place_mint(&mut book, BASE, h::account(0), h::lower_tick(), h::higher_tick());
    place_mint(&mut book, BASE, h::account(0), h::lower_tick(), h::higher_tick());

    // A walker visits records 0 and 1, finishes both, and stops before 2.
    fill_mint(&mut book, first);
    fill_mint(&mut book, second);
    book.set_cohort_first_id(0, 2);
    book.advance_heads();
    assert_eq!(book.cohort(0).span_first_id(), 2);
    assert_eq!(book.resolve_head(), 2);
    assert_eq!(book.cohort(0).span_unfinished(), 2);

    // Never backward.
    book.set_cohort_first_id(0, 1);
    assert_eq!(book.cohort(0).span_first_id(), 2);
    // Never past end_id (4).
    book.set_cohort_first_id(0, 9);
    assert_eq!(book.cohort(0).span_first_id(), 4);
    destroy(book);
}

// === Settlement and cleanup ===

#[test]
fun settle_queue_clears_the_spans_and_moves_the_head_to_next_id() {
    let ctx = &mut tx_context::dummy();
    let mut book = order_queue::new_book(ctx);
    place_mint(&mut book, BASE, h::account(0), h::lower_tick(), h::higher_tick());
    place_mint(&mut book, BASE + 200, h::account(0), h::lower_tick(), h::higher_tick());

    book.settle_queue();

    assert_eq!(book.cohort_count(), 0);
    assert_eq!(book.resolve_head(), 2);
    destroy(book);
}

#[test]
fun the_payout_cursor_moves_forward_only_and_stops_at_next_id() {
    let ctx = &mut tx_context::dummy();
    let mut book = order_queue::new_book(ctx);
    place_mint(&mut book, BASE, h::account(0), h::lower_tick(), h::higher_tick());
    place_mint(&mut book, BASE, h::account(0), h::lower_tick(), h::higher_tick());
    place_mint(&mut book, BASE, h::account(0), h::lower_tick(), h::higher_tick());
    assert_eq!(book.payout_cursor(), 0);

    book.set_payout_cursor(2);
    assert_eq!(book.payout_cursor(), 2);
    book.set_payout_cursor(1);
    assert_eq!(book.payout_cursor(), 2);
    book.set_payout_cursor(10);
    assert_eq!(book.payout_cursor(), 3);
    destroy(book);
}

#[test]
fun remove_finished_record_deletes_finished_empty_records_only() {
    let ctx = &mut tx_context::dummy();
    let mut book = order_queue::new_book(ctx);
    let pending = place_mint(&mut book, BASE, h::account(0), h::lower_tick(), h::higher_tick());
    let open = place_mint(&mut book, BASE, h::account(0), h::lower_tick(), h::higher_tick());
    let closed = place_sell(&mut book, BASE);
    let refunded_with_funds = place_mint(
        &mut book,
        BASE,
        h::account(0),
        h::lower_tick(),
        h::higher_tick(),
    );
    fill_mint(&mut book, open);
    book.finish_order(
        closed,
        order_queue::status_closed(),
        option::none(),
        order_queue::empty_position(),
        0,
        SELL_QUANTITY,
        SELL_PROCEEDS,
        true,
        FILL_MS,
    );
    // A finished record that still escrows USDC is never deleted.
    book.commit_order(
        refunded_with_funds,
        order_queue::new_committed_price(COMMITTED_SPOT, TAU_0, TAU_0 * US_PER_MS),
        balance::create_for_testing(RESERVATION),
    );
    book.finish_order(
        refunded_with_funds,
        order_queue::status_refunded(),
        option::none(),
        order_queue::empty_position(),
        order_queue::reason_admin(),
        0,
        0,
        true,
        FILL_MS,
    );

    assert!(!book.remove_finished_record(pending));
    assert!(book.view(pending).is_some());
    assert!(!book.remove_finished_record(refunded_with_funds));
    assert!(book.view(refunded_with_funds).is_some());
    // An Open record holds a position and is never deleted.
    assert!(!book.remove_finished_record(open));
    assert!(book.remove_finished_record(closed));
    assert!(book.view(closed).is_none());
    assert!(!book.remove_finished_record(closed));
    let missing = book.next_id();
    assert!(!book.remove_finished_record(missing));
    destroy(book);
}

// === Helpers ===

fun place_mint(
    book: &mut OrderBook,
    now_ms: u64,
    account_id: ID,
    lower_tick: u64,
    higher_tick: u64,
): u64 {
    h::place_mint(
        book,
        &h::default_policy(),
        now_ms,
        account_id,
        lower_tick,
        higher_tick,
        BUDGET,
        ORDER_FEE,
        MINT_CASH_NEED,
    )
}

fun place_sell(book: &mut OrderBook, now_ms: u64): u64 {
    h::place_sell(
        book,
        &h::default_policy(),
        now_ms,
        h::account(0),
        SELL_QUANTITY,
        ORDER_FEE,
        SELL_CASH_NEED,
        SELL_ORDER_ID,
        SELL_ROOT_ID,
        SELL_OPENED_AT,
    )
}

/// Finish a mint Open the way a fill does.
fun fill_mint(book: &mut OrderBook, record_id: u64) {
    book.finish_order(
        record_id,
        order_queue::status_open(),
        option::none(),
        order_queue::new_held_position(FILLED_ORDER_ID, FILLED_ORDER_ID, TAU_0),
        0,
        FILLED_QUANTITY,
        FILLED_COST,
        true,
        FILL_MS,
    );
}
