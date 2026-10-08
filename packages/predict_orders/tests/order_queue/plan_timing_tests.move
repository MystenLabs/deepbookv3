// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// τ, deadline, and cutoff planning, worked by hand. `BASE` is a multiple of
/// both channel ticks, so every expected τ below is `BASE` plus a round offset.
#[test_only]
module deepbook_predict_orders::plan_timing_tests;

use deepbook_predict_orders::{
    delayed_execution_config::DelayedExecutionPolicy,
    order_queue::{Self, OrderBook},
    order_queue_test_helpers as h
};
use std::unit_test::{assert_eq, destroy};

const BASE: u64 = 1_000_000_000;
/// The enqueue clock most cases use: 130 ms past a 200 ms tick.
const T0: u64 = 1_000_030_130;
const EXPIRY: u64 = 1_100_000_000;
const NO_TRADE_WINDOW_ZERO: u64 = 0;

const DELAY_ZERO: u64 = 0;
const DELAY_800: u64 = 800;
const DELAY_DEFAULT: u64 = 1_000;
/// Above the fixture gap wait of 2_000, which the stall timeout must exceed.
const STALL_LOW: u64 = 3_000;
const STALL_DEFAULT: u64 = 5_000;
const STALL_HIGH: u64 = 8_000;
/// stall timeout + the 5 s deadline margin at the default stall timeout.
const DEFAULT_CUTOFF_MARGIN: u64 = 10_000;

const BUDGET: u64 = 1_000_000;
const ORDER_FEE: u64 = 20_000;
const CASH_NEED: u64 = 990_001;

// === Fresh book: rounding, deadline, cutoff ===

#[test]
fun tau_rounds_down_to_the_channel_tick() {
    let ctx = &mut tx_context::dummy();
    let book = order_queue::new_book(ctx);
    let policy = h::policy(DELAY_800, STALL_DEFAULT, h::channel_200ms());

    // t0 = BASE + 30_130; t0 + 800 = BASE + 30_930, the 200 ms tick at or before
    // it is BASE + 30_800.
    let timing = book.plan_timing(&policy, EXPIRY, NO_TRADE_WINDOW_ZERO, T0);

    assert_eq!(timing.tau_ms(), BASE + 30_800);
    assert_eq!(timing.earliest_price_ms(), BASE + 30_800);
    assert_eq!(timing.placed_at_ms(), T0);
    // τ + 5_000.
    assert_eq!(timing.deadline_ms(), BASE + 35_800);
    // expiry - max(0, 5_000 + 5_000).
    assert_eq!(timing.cutoff_ms(), EXPIRY - DEFAULT_CUTOFF_MARGIN);
    assert_eq!(timing.pyth_channel(), h::channel_200ms());
    destroy(book);
}

#[test]
fun tau_on_an_exact_tick_is_kept_and_one_ms_earlier_drops_a_tick() {
    let ctx = &mut tx_context::dummy();
    let book = order_queue::new_book(ctx);
    let policy = h::policy(DELAY_800, STALL_DEFAULT, h::channel_200ms());

    // BASE + 29_200 + 800 = BASE + 30_000, exactly on the grid.
    let on_tick = book.plan_timing(&policy, EXPIRY, NO_TRADE_WINDOW_ZERO, BASE + 29_200);
    assert_eq!(on_tick.tau_ms(), BASE + 30_000);
    // BASE + 29_199 + 800 = BASE + 29_999, which rounds down to BASE + 29_800.
    let below_tick = book.plan_timing(&policy, EXPIRY, NO_TRADE_WINDOW_ZERO, BASE + 29_199);
    assert_eq!(below_tick.tau_ms(), BASE + 29_800);
    destroy(book);
}

#[test]
fun zero_delay_prices_the_tick_at_or_before_now() {
    let ctx = &mut tx_context::dummy();
    let book = order_queue::new_book(ctx);
    let policy = h::policy(DELAY_ZERO, STALL_DEFAULT, h::channel_200ms());

    // BASE + 30_130 rounds down to BASE + 30_000, before t0.
    let timing = book.plan_timing(&policy, EXPIRY, NO_TRADE_WINDOW_ZERO, T0);

    assert_eq!(timing.tau_ms(), BASE + 30_000);
    assert_eq!(timing.deadline_ms(), BASE + 35_000);
    destroy(book);
}

#[test]
fun fifty_ms_channel_rounds_to_a_fifty_ms_grid() {
    let ctx = &mut tx_context::dummy();
    let book = order_queue::new_book(ctx);
    let policy = h::policy(DELAY_DEFAULT, STALL_DEFAULT, h::channel_50ms());

    // BASE + 30_130 + 1_000 = BASE + 31_130, rounds down to BASE + 31_100 on 50 ms.
    let timing = book.plan_timing(&policy, EXPIRY, NO_TRADE_WINDOW_ZERO, T0);

    assert_eq!(timing.tau_ms(), BASE + 31_100);
    assert_eq!(timing.pyth_channel(), h::channel_50ms());
    destroy(book);
}

#[test]
fun deadline_is_capped_at_expiry() {
    let ctx = &mut tx_context::dummy();
    let book = order_queue::new_book(ctx);
    let policy = h::default_policy();
    let near_expiry = BASE + 34_000;

    // τ = BASE + 31_000; τ + 5_000 = BASE + 36_000 is past expiry, so D = expiry.
    let timing = book.plan_timing(&policy, near_expiry, NO_TRADE_WINDOW_ZERO, T0);

    assert_eq!(timing.tau_ms(), BASE + 31_000);
    assert_eq!(timing.deadline_ms(), near_expiry);
    // expiry - 10_000 = BASE + 24_000: this τ would fail the caller's cutoff check.
    assert_eq!(timing.cutoff_ms(), BASE + 24_000);
    destroy(book);
}

#[test]
fun cutoff_takes_the_larger_of_the_no_trade_window_and_the_stall_margin() {
    let ctx = &mut tx_context::dummy();
    let book = order_queue::new_book(ctx);
    let policy = h::default_policy();
    let now = T0;

    // Stall margin 5_000 + 5_000 = 10_000 against windows of 9_999, 10_000, 10_001.
    assert_eq!(book.plan_timing(&policy, EXPIRY, 9_999, now).cutoff_ms(), EXPIRY - 10_000);
    assert_eq!(book.plan_timing(&policy, EXPIRY, 10_000, now).cutoff_ms(), EXPIRY - 10_000);
    assert_eq!(book.plan_timing(&policy, EXPIRY, 10_001, now).cutoff_ms(), EXPIRY - 10_001);

    // At stall 8_000 the margin is 13_000, above a 10_000 window.
    let high_stall = h::policy(DELAY_DEFAULT, STALL_HIGH, h::channel_200ms());
    assert_eq!(book.plan_timing(&high_stall, EXPIRY, 10_000, now).cutoff_ms(), EXPIRY - 13_000);
    destroy(book);
}

#[test]
fun cutoff_saturates_to_zero_when_expiry_is_inside_the_margin() {
    let ctx = &mut tx_context::dummy();
    let book = order_queue::new_book(ctx);
    let policy = h::default_policy();

    // expiry 9_000 - max(0, 10_000) would be negative: cutoff 0, which no τ passes.
    let timing = book.plan_timing(&policy, 9_000, NO_TRADE_WINDOW_ZERO, 0);

    assert_eq!(timing.cutoff_ms(), 0);
    destroy(book);
}

// === Against the book's last τ, channel, and committed τ ===

#[test]
fun tau_never_drops_below_last_tau_and_joins_that_cohort() {
    let ctx = &mut tx_context::dummy();
    let mut book = order_queue::new_book(ctx);
    let first_policy = h::default_policy();
    // τ = BASE + 31_000, D = BASE + 36_000.
    place(&mut book, &first_policy, T0);

    // Delay lowered to 0: the formula gives BASE + 30_000, below last τ.
    let zero_delay = h::policy(DELAY_ZERO, STALL_DEFAULT, h::channel_200ms());
    let timing = book.plan_timing(&zero_delay, EXPIRY, NO_TRADE_WINDOW_ZERO, T0);

    assert_eq!(timing.tau_ms(), BASE + 31_000);
    assert_eq!(timing.deadline_ms(), BASE + 36_000);
    place(&mut book, &zero_delay, T0);
    assert_eq!(book.cohort_count(), 1);
    assert_eq!(book.cohort(0).span_end_id(), 2);
    destroy(book);
}

#[test]
fun joining_a_cohort_keeps_its_deadline_after_the_stall_timeout_is_raised() {
    let ctx = &mut tx_context::dummy();
    let mut book = order_queue::new_book(ctx);
    // τ = BASE + 31_000, D = τ + 5_000 = BASE + 36_000.
    place(&mut book, &h::default_policy(), T0);

    // Stall raised to 8_000. BASE + 30_150 + 1_000 rounds to the same τ, so the
    // order joins the cohort and takes BASE + 36_000, not τ + 8_000.
    let raised = h::policy(DELAY_DEFAULT, STALL_HIGH, h::channel_200ms());
    let timing = book.plan_timing(&raised, EXPIRY, NO_TRADE_WINDOW_ZERO, BASE + 30_150);

    assert_eq!(timing.tau_ms(), BASE + 31_000);
    assert_eq!(timing.deadline_ms(), BASE + 36_000);
    // The cutoff still reads the current stall: expiry - (8_000 + 5_000).
    assert_eq!(timing.cutoff_ms(), EXPIRY - 13_000);
    destroy(book);
}

#[test]
fun a_new_cohort_deadline_never_drops_after_the_stall_timeout_is_lowered() {
    let ctx = &mut tx_context::dummy();
    let mut book = order_queue::new_book(ctx);
    // τ = BASE + 31_000, D = BASE + 36_000.
    place(&mut book, &h::default_policy(), T0);

    // Stall lowered to 3_000. BASE + 30_330 + 1_000 rounds to BASE + 31_200, a
    // new cohort: min(τ + 3_000, expiry) = BASE + 34_200, raised to last D.
    let lowered = h::policy(DELAY_DEFAULT, STALL_LOW, h::channel_200ms());
    let timing = book.plan_timing(&lowered, EXPIRY, NO_TRADE_WINDOW_ZERO, BASE + 30_330);

    assert_eq!(timing.tau_ms(), BASE + 31_200);
    assert_eq!(timing.deadline_ms(), BASE + 36_000);
    destroy(book);
}

#[test]
fun switching_from_50ms_to_200ms_moves_past_last_tau_onto_the_new_grid() {
    let ctx = &mut tx_context::dummy();
    let mut book = order_queue::new_book(ctx);
    let fifty = h::policy(DELAY_DEFAULT, STALL_DEFAULT, h::channel_50ms());
    // τ = BASE + 31_100 on the 50 ms channel.
    place(&mut book, &fifty, T0);

    // On 200 ms the formula gives BASE + 31_000 and max with last τ would give
    // BASE + 31_100, off the 200 ms grid. The switch takes the first 200 ms tick
    // after BASE + 31_100: BASE + 31_200.
    let two_hundred = h::default_policy();
    let timing = book.plan_timing(&two_hundred, EXPIRY, NO_TRADE_WINDOW_ZERO, T0);

    assert_eq!(timing.tau_ms(), BASE + 31_200);
    assert_eq!(timing.deadline_ms(), BASE + 36_200);
    assert_eq!(timing.pyth_channel(), h::channel_200ms());
    place(&mut book, &two_hundred, T0);
    assert_eq!(book.cohort_count(), 2);
    assert_eq!(book.cohort(1).span_pyth_channel(), h::channel_200ms());

    // Once the newest order is on 200 ms there is no push: BASE + 40_130 + 1_000
    // rounds to BASE + 41_000.
    let later = book.plan_timing(&two_hundred, EXPIRY, NO_TRADE_WINDOW_ZERO, BASE + 40_130);
    assert_eq!(later.tau_ms(), BASE + 41_000);
    destroy(book);
}

#[test]
fun switching_from_200ms_to_50ms_never_joins_the_old_cohort() {
    let ctx = &mut tx_context::dummy();
    let mut book = order_queue::new_book(ctx);
    // τ = BASE + 31_000 on 200 ms.
    place(&mut book, &h::default_policy(), T0);

    // On 50 ms with delay 800 the formula gives BASE + 30_900; max with last τ
    // would join the 200 ms cohort. The switch takes the first 50 ms tick after
    // BASE + 31_000: BASE + 31_050.
    let fifty = h::policy(DELAY_800, STALL_DEFAULT, h::channel_50ms());
    let timing = book.plan_timing(&fifty, EXPIRY, NO_TRADE_WINDOW_ZERO, T0);

    assert_eq!(timing.tau_ms(), BASE + 31_050);
    assert_eq!(timing.deadline_ms(), BASE + 36_050);
    place(&mut book, &fifty, T0);
    assert_eq!(book.cohort_count(), 2);
    assert_eq!(book.cohort(1).span_pyth_channel(), h::channel_50ms());
    destroy(book);
}

#[test]
fun a_committed_cohort_pushes_the_next_order_to_the_following_tick() {
    let ctx = &mut tx_context::dummy();
    let mut book = order_queue::new_book(ctx);
    let policy = h::default_policy();
    // τ = BASE + 31_000, then commit it.
    place(&mut book, &policy, T0);
    book.mark_cohort_committed(0);

    // The formula and last τ both give BASE + 31_000, at the committed τ, so the
    // order moves to the next 200 ms tick, BASE + 31_200, a new cohort.
    let timing = book.plan_timing(&policy, EXPIRY, NO_TRADE_WINDOW_ZERO, T0);

    assert_eq!(timing.tau_ms(), BASE + 31_200);
    assert_eq!(timing.deadline_ms(), BASE + 36_200);
    place(&mut book, &policy, T0);
    assert_eq!(book.cohort_count(), 2);
    assert_eq!(book.cohort(0).span_end_id(), 1);
    assert!(!book.cohort(1).span_committed());
    destroy(book);
}

fun place(book: &mut OrderBook, policy: &DelayedExecutionPolicy, now_ms: u64): u64 {
    h::place_mint(
        book,
        policy,
        now_ms,
        h::account(0),
        h::lower_tick(),
        h::higher_tick(),
        BUDGET,
        ORDER_FEE,
        CASH_NEED,
    )
}
