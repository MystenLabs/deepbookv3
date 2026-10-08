// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Record, span, and counter bookkeeping: append, commit, fill, the B1 walker
/// resume, `advance_heads`, and the settlement and cleanup primitives. Orders are
/// placed with the default policy (delay 1_000 on 200 ms, stall 5_000): an order
/// at `BASE + k * 200` gets τ = `BASE + 1_000 + k * 200` and D = τ + 5_000.
#[test_only]
module deepbook_predict::cohort_span_tests;

use deepbook_predict::{constants, order_queue::{Self, OrderBook}, order_queue_test_helpers as h};
use std::unit_test::{assert_eq, destroy};

const BASE: u64 = 1_000_000_000;
const TAU_0: u64 = 1_000_001_000;
const DEADLINE_0: u64 = 1_000_006_000;
const TAU_1: u64 = 1_000_001_200;
const TAU_2: u64 = 1_000_001_400;
const FILL_MS: u64 = 1_000_001_500;
const US_PER_MS: u64 = 1_000;

const BUDGET: u64 = 1_000_000;
const ORDER_FEE: u64 = 20_000;
/// The exact-quantity cash need of 1_000_000 at p_min 0.01 (see cash_need_tests).
const MINT_CASH_NEED: u64 = 990_001;
/// 1_000_000 + 20_000 per mint.
const MINT_ESCROW: u64 = 1_020_000;
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
const SUBSIDY_RATE: u64 = 500_000_000;
const LOWER_SUBSIDY_RATE: u64 = 250_000_000;
const FIRST_RESERVATION: u64 = 300;
const SECOND_RESERVATION: u64 = 200;
const TOTAL_RESERVATION: u64 = 500;
const COMMITTED_SPOT: u64 = 50_000_000_000;
const OTHER_SPOT: u64 = 51_000_000_000;

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
    assert_eq!(book.waiting_cash_need(), MINT_CASH_NEED);
    assert_eq!(book.escrow_value(), MINT_ESCROW);
    assert_eq!(book.pins().length(), 2);
    assert_eq!(*book.pins().get(&h::lower_tick()), 1);
    assert_eq!(*book.pins().get(&h::higher_tick()), 1);
    let record = book.try_order(id).destroy_some();
    assert_eq!(record.status(), order_queue::status_pending());
    assert_eq!(record.kind(), order_queue::kind_exact_quantity());
    assert_eq!(record.timing().tau_ms(), TAU_0);
    assert_eq!(record.escrow().cash_need(), MINT_CASH_NEED);
    assert_eq!(record.result().reason(), 0);
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
    // Tick 100 is shared by both mints.
    assert_eq!(book.pins().length(), 3);
    assert_eq!(*book.pins().get(&h::lower_tick()), 2);
    assert_eq!(*book.pins().get(&h::higher_tick()), 1);
    let other_tick = OTHER_TICK;
    assert_eq!(*book.pins().get(&other_tick), 1);
    assert_eq!(book.waiting_cash_need(), 2 * MINT_CASH_NEED);

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
fun a_sell_counts_as_a_sell_holds_its_position_and_pins_nothing() {
    let ctx = &mut tx_context::dummy();
    let mut book = order_queue::new_book(ctx);

    let id = place_sell(&mut book, BASE);

    assert_eq!(book.pending_sells(), 1);
    assert_eq!(book.pending_mints(), 0);
    assert_eq!(book.pins().length(), 0);
    assert_eq!(book.waiting_cash_need(), SELL_CASH_NEED);
    assert_eq!(book.escrow_value(), ORDER_FEE);
    let record = book.try_order(id).destroy_some();
    assert_eq!(record.kind(), order_queue::kind_redeem_open());
    assert_eq!(record.position().order_id(), SELL_ORDER_ID);
    assert_eq!(record.position().root_id(), SELL_ROOT_ID);
    assert_eq!(record.position().opened_at_ms(), SELL_OPENED_AT);
    destroy(book);
}

#[test]
fun the_open_sentinel_ticks_are_never_pinned() {
    let ctx = &mut tx_context::dummy();
    let mut book = order_queue::new_book(ctx);

    // (-inf, 100] and (100, +inf): only tick 100 has a node to pin.
    let below = place_mint(&mut book, BASE, h::account(0), 0, h::lower_tick());
    let above = place_mint(
        &mut book,
        BASE,
        h::account(0),
        h::lower_tick(),
        constants::pos_inf_tick!(),
    );

    assert_eq!(book.pins().length(), 1);
    assert_eq!(*book.pins().get(&h::lower_tick()), 2);
    fill_mint(&mut book, below);
    assert_eq!(*book.pins().get(&h::lower_tick()), 1);
    fill_mint(&mut book, above);
    assert_eq!(book.pins().length(), 0);
    destroy(book);
}

// === Commit ===

#[test]
fun commit_order_commits_pending_records_only() {
    let ctx = &mut tx_context::dummy();
    let mut book = order_queue::new_book(ctx);
    let pending = place_mint(&mut book, BASE, h::account(0), h::lower_tick(), h::higher_tick());
    let filled = place_mint(&mut book, BASE, h::account(1), h::lower_tick(), h::higher_tick());
    fill_mint(&mut book, filled);

    let generation_us = TAU_0 * US_PER_MS;
    book.commit_order(
        pending,
        order_queue::new_committed_price(COMMITTED_SPOT, TAU_0, generation_us),
    );
    let record = book.try_order(pending).destroy_some();
    assert_eq!(record.status(), order_queue::status_committed());
    assert_eq!(record.price().spot(), COMMITTED_SPOT);
    assert_eq!(record.price().tick_ms(), TAU_0);
    assert_eq!(record.price().generation_us(), generation_us);

    // A second commit and a commit of a filled record change nothing.
    let other = order_queue::new_committed_price(OTHER_SPOT, TAU_1, TAU_1 * US_PER_MS);
    book.commit_order(pending, other);
    book.commit_order(filled, other);
    assert_eq!(book.try_order(pending).destroy_some().price().spot(), COMMITTED_SPOT);
    let filled_record = book.try_order(filled).destroy_some();
    assert_eq!(filled_record.status(), order_queue::status_open());
    assert_eq!(filled_record.price().spot(), 0);
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

    book.mark_cohort_committed(0);
    assert_eq!(book.last_committed_tau_ms(), TAU_1);
    assert!(book.cohort(0).span_committed());
    destroy(book);
}

#[test]
fun reserve_subsidy_adds_to_the_record_and_the_escrow() {
    let ctx = &mut tx_context::dummy();
    let mut book = order_queue::new_book(ctx);
    let id = place_mint(&mut book, BASE, h::account(0), h::lower_tick(), h::higher_tick());

    book.reserve_subsidy(id, SUBSIDY_RATE, sui::balance::create_for_testing(FIRST_RESERVATION));
    assert_eq!(book.escrow_value(), MINT_ESCROW + FIRST_RESERVATION);
    let escrow = book.try_order(id).destroy_some().escrow();
    assert_eq!(escrow.subsidy_rate(), SUBSIDY_RATE);
    assert_eq!(escrow.subsidy_reserved(), FIRST_RESERVATION);

    book.reserve_subsidy(
        id,
        LOWER_SUBSIDY_RATE,
        sui::balance::create_for_testing(SECOND_RESERVATION),
    );
    // 300 + 200 reserved in total.
    assert_eq!(book.escrow_value(), MINT_ESCROW + TOTAL_RESERVATION);
    let escrow = book.try_order(id).destroy_some().escrow();
    assert_eq!(escrow.subsidy_rate(), LOWER_SUBSIDY_RATE);
    assert_eq!(escrow.subsidy_reserved(), TOTAL_RESERVATION);
    destroy(book);
}

// === Fill ===

#[test]
fun withdraw_order_escrow_takes_one_records_budget_fee_and_subsidy() {
    let ctx = &mut tx_context::dummy();
    let mut book = order_queue::new_book(ctx);
    place_mint(&mut book, BASE, h::account(0), h::lower_tick(), h::higher_tick());
    let id = place_mint(&mut book, BASE, h::account(1), h::lower_tick(), h::higher_tick());
    book.reserve_subsidy(id, SUBSIDY_RATE, sui::balance::create_for_testing(FIRST_RESERVATION));

    let withdrawn = book.withdraw_order_escrow(id);

    // 1_000_000 + 20_000 + 300; the other mint's 1_020_000 stays.
    assert_eq!(withdrawn.value(), MINT_ESCROW + FIRST_RESERVATION);
    assert_eq!(book.escrow_value(), MINT_ESCROW);
    destroy(withdrawn);
    destroy(book);
}

#[test]
fun finish_fill_opens_a_mint_and_releases_it_exactly_once() {
    let ctx = &mut tx_context::dummy();
    let mut book = order_queue::new_book(ctx);
    let id = place_mint(&mut book, BASE, h::account(0), h::lower_tick(), h::higher_tick());
    place_mint(&mut book, BASE, h::account(1), h::lower_tick(), OTHER_TICK);
    let position = order_queue::new_held_position(FILLED_ORDER_ID, FILLED_ORDER_ID, TAU_0);

    book.finish_fill(
        id,
        order_queue::status_open(),
        position,
        FILLED_QUANTITY,
        FILLED_COST,
        FILL_MS,
    );

    let record = book.try_order(id).destroy_some();
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
    assert_eq!(book.waiting_cash_need(), MINT_CASH_NEED);
    assert_eq!(book.cohort(0).span_unfinished(), 1);
    assert_eq!(book.pins().length(), 2);
    assert_eq!(*book.pins().get(&h::lower_tick()), 1);
    assert!(!book.pins().contains(&h::higher_tick()));
    let other_tick = OTHER_TICK;
    assert_eq!(*book.pins().get(&other_tick), 1);
    destroy(book);
}

#[test]
fun finish_fill_closes_a_full_sell() {
    let ctx = &mut tx_context::dummy();
    let mut book = order_queue::new_book(ctx);
    let id = place_sell(&mut book, BASE);

    book.finish_fill(
        id,
        order_queue::status_closed(),
        order_queue::empty_position(),
        SELL_QUANTITY,
        SELL_PROCEEDS,
        FILL_MS,
    );

    let record = book.try_order(id).destroy_some();
    assert_eq!(record.status(), order_queue::status_closed());
    assert_eq!(record.position().order_id(), 0);
    assert_eq!(record.result().result_amount(), SELL_PROCEEDS);
    assert_eq!(book.pending_sells(), 0);
    assert_eq!(book.waiting_cash_need(), 0);
    assert_eq!(book.account_waiting(h::account(0)), 0);
    assert_eq!(book.cohort(0).span_unfinished(), 0);
    destroy(book);
}

#[test]
fun close_open_record_moves_the_position_out_without_touching_counters() {
    let ctx = &mut tx_context::dummy();
    let mut book = order_queue::new_book(ctx);
    let id = place_mint(&mut book, BASE, h::account(0), h::lower_tick(), h::higher_tick());
    place_mint(&mut book, BASE, h::account(1), h::lower_tick(), h::higher_tick());
    fill_mint(&mut book, id);

    let position = book.close_open_record(id);

    assert_eq!(position.order_id(), FILLED_ORDER_ID);
    assert_eq!(position.root_id(), FILLED_ORDER_ID);
    assert_eq!(position.opened_at_ms(), TAU_0);
    let record = book.try_order(id).destroy_some();
    assert_eq!(record.status(), order_queue::status_closed());
    assert_eq!(record.position().order_id(), 0);
    assert_eq!(record.position().opened_at_ms(), 0);
    assert_eq!(book.pending_mints(), 1);
    assert_eq!(book.waiting_cash_need(), MINT_CASH_NEED);
    assert_eq!(book.cohort(0).span_unfinished(), 1);
    destroy(book);
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

    fill_mint(&mut book, second);
    book.advance_heads();
    assert_eq!(book.cohort_count(), 0);
    assert_eq!(book.resolve_head(), 3);
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

    // A walker visits records 0 and 1, finishes both, and stops before 2 (B1).
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
fun remove_finished_record_deletes_closed_records_only() {
    let ctx = &mut tx_context::dummy();
    let mut book = order_queue::new_book(ctx);
    let pending = place_mint(&mut book, BASE, h::account(0), h::lower_tick(), h::higher_tick());
    let open = place_mint(&mut book, BASE, h::account(0), h::lower_tick(), h::higher_tick());
    let closed = place_sell(&mut book, BASE);
    fill_mint(&mut book, open);
    book.finish_fill(
        closed,
        order_queue::status_closed(),
        order_queue::empty_position(),
        SELL_QUANTITY,
        SELL_PROCEEDS,
        FILL_MS,
    );

    assert!(!book.remove_finished_record(pending));
    assert!(book.try_order(pending).is_some());
    assert!(!book.remove_finished_record(open));
    assert!(book.try_order(open).is_some());
    assert!(book.remove_finished_record(closed));
    assert!(book.try_order(closed).is_none());
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

/// Fill a mint the way resolve does: take its escrow, then finish it Open.
fun fill_mint(book: &mut OrderBook, record_id: u64) {
    let escrow = book.withdraw_order_escrow(record_id);
    destroy(escrow);
    book.finish_fill(
        record_id,
        order_queue::status_open(),
        order_queue::new_held_position(FILLED_ORDER_ID, FILLED_ORDER_ID, TAU_0),
        FILLED_QUANTITY,
        FILLED_COST,
        FILL_MS,
    );
}
