// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The shared refund routine: where each part of the escrow goes per reason,
/// the seniority order under an escrow shortfall, a sell returning to Open, and
/// every counter dropping exactly once. These run with `prune = false`; the
/// prune path is in `refund_prune_tests`.
///
/// The trader's payout leaves through `balance::send_funds`, which a unit test
/// cannot read back, so the trader's share is checked through the returned
/// amounts plus conservation: escrow goes to zero while market cash and the
/// incentive balance receive exactly the rest.
///
/// A RefundDue record keeps its stored reason, but nothing produces RefundDue
/// at launch (D7.10), so that branch has no production-valid fixture here.
#[test_only]
module deepbook_predict::refund_order_tests;

use deepbook_predict::{
    expiry_cash::{Self, ExpiryCash},
    order_queue::{Self, OrderBook},
    order_queue_test_helpers as h,
    strike_exposure::StrikeExposure
};
use std::unit_test::{assert_eq, destroy};
use sui::balance::{Self, Balance};
use usdc::usdc::USDC;

const BASE: u64 = 1_000_000_000;
/// After the default-policy deadline τ + 5_000 = BASE + 6_000.
const REFUND_MS: u64 = 1_000_006_000;
const FILL_MS: u64 = 1_000_001_500;
const TAU_0: u64 = 1_000_001_000;

const BUDGET: u64 = 1_000_000;
const ORDER_FEE: u64 = 20_000;
const MINT_CASH_NEED: u64 = 990_001;
/// Budget plus order fee, deposited at enqueue.
const MINT_ESCROW: u64 = 1_020_000;
const SUBSIDY_RATE: u64 = 500_000_000;
const RESERVED_SUBSIDY: u64 = 3_000;
const INCENTIVES: u64 = 10_000;
/// Budget plus order fee plus reserved subsidy.
const MINT_OWED: u64 = 1_023_000;

/// Escrow staged below what one subsidized mint is owed.
const SHORT_ESCROW: u64 = 1_010_000;
/// 1_023_000 owed - 1_010_000 held.
const SHORTFALL: u64 = 13_000;
/// 1_010_000 - 1_000_000 budget, left for the fee refund.
const PARTIAL_FEE_REFUND: u64 = 10_000;
/// 1_010_000 - 1_000_000 budget - 3_000 subsidy, left for the kept fee.
const PARTIAL_KEPT_FEE: u64 = 7_000;
const BELOW_BUDGET_ESCROW: u64 = 600_000;
/// 1_023_000 owed - 600_000 held.
const BELOW_BUDGET_SHORTFALL: u64 = 423_000;
/// 3 * 990_001 for three mints + 3_450_001 for one sell.
const MIXED_CASH_NEED: u64 = 6_420_004;

const SELL_QUANTITY: u64 = 5_000_000;
const SELL_CASH_NEED: u64 = 3_450_001;
const SELL_ORDER_ID: u256 = 555;
const SELL_ROOT_ID: u256 = 444;
const SELL_OPENED_AT: u64 = 12_345;

const FILLED_ORDER_ID: u256 = 777;
const FILLED_QUANTITY: u64 = 5_000_000;
const FILLED_COST: u64 = 980_000;

/// The routine's parts of one market, held together for the test's lifetime.
public struct Parts {
    book: OrderBook,
    exposure: StrikeExposure,
    cash: ExpiryCash,
    incentives: Balance<USDC>,
}

// === Fee destination per reason (mint) ===

#[test]
fun limits_refund_keeps_the_fee_in_market_cash() {
    refund_mint_and_check(order_queue::reason_limits(), true);
}

#[test]
fun admission_refund_keeps_the_fee_in_market_cash() {
    refund_mint_and_check(order_queue::reason_admission(), true);
}

#[test]
fun reserved_no_price_reason_returns_the_fee() {
    refund_mint_and_check(order_queue::reason_no_price(), false);
}

#[test]
fun missing_node_refund_returns_the_fee() {
    refund_mint_and_check(order_queue::reason_missing_node(), false);
}

#[test]
fun deadline_refund_returns_the_fee() {
    refund_mint_and_check(order_queue::reason_deadline(), false);
}

#[test]
fun reserved_freeze_reason_returns_the_fee() {
    refund_mint_and_check(order_queue::reason_freeze(), false);
}

#[test]
fun admin_refund_returns_the_fee() {
    refund_mint_and_check(order_queue::reason_admin(), false);
}

#[test]
fun no_cash_refund_returns_the_fee() {
    refund_mint_and_check(order_queue::reason_no_cash(), false);
}

// === Sells ===

#[test]
fun a_refunded_sell_returns_to_open_holding_its_position() {
    let mut parts = new_parts();
    let id = place_sell(&mut parts.book);

    let outcome = refund(&mut parts, id, order_queue::reason_deadline());

    assert_eq!(outcome.escrow_returned(), 0);
    assert_eq!(outcome.order_fee_returned(), ORDER_FEE);
    assert_eq!(outcome.subsidy_returned(), 0);
    assert!(outcome.position_returned());
    assert_eq!(outcome.owed(), ORDER_FEE);
    assert_eq!(outcome.shortfall(), 0);
    let record = parts.book.try_order(id).destroy_some();
    assert_eq!(record.status(), order_queue::status_open());
    assert_eq!(record.position().order_id(), SELL_ORDER_ID);
    assert_eq!(record.position().root_id(), SELL_ROOT_ID);
    assert_eq!(record.position().opened_at_ms(), SELL_OPENED_AT);
    assert_eq!(record.result().reason(), order_queue::reason_deadline());
    assert_eq!(record.result().finished_at_ms(), REFUND_MS);
    assert_eq!(parts.book.pending_sells(), 0);
    assert_eq!(parts.book.waiting_cash_need(), 0);
    assert_eq!(parts.book.account_waiting(h::account(0)), 0);
    assert_eq!(parts.book.cohort(0).span_unfinished(), 0);
    assert_eq!(parts.book.escrow_value(), 0);
    assert_eq!(parts.cash.balance(), 0);
    destroy(parts);
}

#[test]
fun a_sell_refunded_for_its_limits_keeps_the_fee_and_still_reopens() {
    let mut parts = new_parts();
    let id = place_sell(&mut parts.book);

    let outcome = refund(&mut parts, id, order_queue::reason_limits());

    assert_eq!(outcome.order_fee_returned(), 0);
    assert!(outcome.position_returned());
    assert_eq!(outcome.shortfall(), 0);
    assert_eq!(parts.cash.balance(), ORDER_FEE);
    assert_eq!(parts.book.escrow_value(), 0);
    let record = parts.book.try_order(id).destroy_some();
    assert_eq!(record.status(), order_queue::status_open());
    assert_eq!(record.position().order_id(), SELL_ORDER_ID);
    destroy(parts);
}

// === Escrow shortfall ===

#[test]
fun a_short_escrow_pays_the_budget_then_the_fee_refund_before_the_subsidy() {
    let mut parts = new_parts();
    let id = place_mint_with_subsidy(&mut parts);
    // Escrow holds 1_010_000 of the 1_023_000 owed.
    set_escrow(&mut parts.book, SHORT_ESCROW);

    let outcome = refund(&mut parts, id, order_queue::reason_deadline());

    // Budget 1_000_000 in full, then 10_000 of the 20_000 fee, nothing left
    // for the 3_000 subsidy: 13_000 short.
    assert_eq!(outcome.escrow_returned(), BUDGET);
    assert_eq!(outcome.order_fee_returned(), PARTIAL_FEE_REFUND);
    assert_eq!(outcome.subsidy_returned(), 0);
    assert_eq!(outcome.owed(), MINT_OWED);
    assert_eq!(outcome.shortfall(), SHORTFALL);
    assert_eq!(parts.book.escrow_value(), 0);
    assert_eq!(parts.incentives.value(), INCENTIVES - RESERVED_SUBSIDY);
    assert_eq!(parts.cash.balance(), 0);
    assert_eq!(parts.book.try_order(id).destroy_some().status(), order_queue::status_refunded());
    destroy(parts);
}

#[test]
fun a_short_escrow_pays_the_subsidy_before_a_kept_fee() {
    let mut parts = new_parts();
    let id = place_mint_with_subsidy(&mut parts);
    set_escrow(&mut parts.book, SHORT_ESCROW);

    let outcome = refund(&mut parts, id, order_queue::reason_limits());

    // Budget 1_000_000, the 3_000 subsidy back to incentives, then 7_000 of the
    // kept 20_000 fee to market cash: 13_000 short.
    assert_eq!(outcome.escrow_returned(), BUDGET);
    assert_eq!(outcome.order_fee_returned(), 0);
    assert_eq!(outcome.subsidy_returned(), RESERVED_SUBSIDY);
    assert_eq!(outcome.shortfall(), SHORTFALL);
    assert_eq!(parts.incentives.value(), INCENTIVES);
    assert_eq!(parts.cash.balance(), PARTIAL_KEPT_FEE);
    assert_eq!(parts.book.escrow_value(), 0);
    destroy(parts);
}

#[test]
fun a_short_escrow_below_the_budget_pays_only_the_trader_and_still_finishes() {
    let mut parts = new_parts();
    let id = place_mint_with_subsidy(&mut parts);
    set_escrow(&mut parts.book, BELOW_BUDGET_ESCROW);

    let outcome = refund(&mut parts, id, order_queue::reason_limits());

    // 600_000 of the budget; fee, subsidy, and the rest of the budget are short:
    // 1_023_000 - 600_000 = 423_000.
    assert_eq!(outcome.escrow_returned(), BELOW_BUDGET_ESCROW);
    assert_eq!(outcome.subsidy_returned(), 0);
    assert_eq!(outcome.shortfall(), BELOW_BUDGET_SHORTFALL);
    assert_eq!(parts.cash.balance(), 0);
    assert_eq!(parts.incentives.value(), INCENTIVES - RESERVED_SUBSIDY);
    // The order still finishes and releases everything once.
    assert_eq!(parts.book.try_order(id).destroy_some().status(), order_queue::status_refunded());
    assert_eq!(parts.book.pending_mints(), 0);
    assert_eq!(parts.book.waiting_cash_need(), 0);
    assert_eq!(parts.book.cohort(0).span_unfinished(), 0);
    destroy(parts);
}

// === Missing and finished records ===

#[test]
fun a_missing_record_is_skipped() {
    let mut parts = new_parts();
    place_mint(&mut parts.book, h::account(0));
    let missing = parts.book.next_id();

    let outcome = refund_option(&mut parts, missing, order_queue::reason_admin());

    assert!(outcome.is_none());
    assert_eq!(parts.book.pending_mints(), 1);
    assert_eq!(parts.book.escrow_value(), MINT_ESCROW);
    destroy(parts);
}

#[test]
fun a_second_refund_is_skipped_and_drops_nothing_again() {
    let mut parts = new_parts();
    let id = place_mint(&mut parts.book, h::account(0));
    place_mint(&mut parts.book, h::account(0));
    refund(&mut parts, id, order_queue::reason_deadline());
    assert_eq!(parts.book.pending_mints(), 1);
    assert_eq!(parts.book.account_waiting(h::account(0)), 1);

    let again = refund_option(&mut parts, id, order_queue::reason_admin());

    assert!(again.is_none());
    assert_eq!(parts.book.pending_mints(), 1);
    assert_eq!(parts.book.account_waiting(h::account(0)), 1);
    assert_eq!(parts.book.waiting_cash_need(), MINT_CASH_NEED);
    assert_eq!(parts.book.cohort(0).span_unfinished(), 1);
    assert_eq!(parts.book.escrow_value(), MINT_ESCROW);
    // The first refund's reason stays on the record.
    assert_eq!(
        parts.book.try_order(id).destroy_some().result().reason(),
        order_queue::reason_deadline(),
    );
    destroy(parts);
}

#[test]
fun filled_and_reopened_records_are_skipped() {
    let mut parts = new_parts();
    let filled = place_mint(&mut parts.book, h::account(0));
    let sell = place_sell(&mut parts.book);
    let escrow = parts.book.withdraw_order_escrow(filled);
    destroy(escrow);
    parts
        .book
        .finish_fill(
            filled,
            order_queue::status_open(),
            order_queue::new_held_position(FILLED_ORDER_ID, FILLED_ORDER_ID, TAU_0),
            FILLED_QUANTITY,
            FILLED_COST,
            FILL_MS,
        );
    refund(&mut parts, sell, order_queue::reason_deadline());

    // Both are Open now: finished, so neither is refunded.
    assert!(refund_option(&mut parts, filled, order_queue::reason_admin()).is_none());
    assert!(refund_option(&mut parts, sell, order_queue::reason_admin()).is_none());
    assert_eq!(parts.book.try_order(filled).destroy_some().status(), order_queue::status_open());
    assert_eq!(parts.book.escrow_value(), 0);
    destroy(parts);
}

#[test]
fun a_refunded_record_can_then_be_cleaned_up() {
    let mut parts = new_parts();
    let id = place_mint(&mut parts.book, h::account(0));
    refund(&mut parts, id, order_queue::reason_deadline());

    assert!(parts.book.remove_finished_record(id));
    assert!(parts.book.try_order(id).is_none());
    destroy(parts);
}

// === Counters across mixed finishes ===

#[test]
fun counters_and_escrow_track_exactly_the_unfinished_orders() {
    let mut parts = new_parts();
    let x = h::account(0);
    let y = h::account(1);
    // Cohort 0: mints 0 (x) and 1 (y). Cohort 1: sell 2 (x) and mint 3 (y).
    let filled = place_mint(&mut parts.book, x);
    let refunded = place_mint(&mut parts.book, y);
    let sell = place_sell_at(&mut parts.book, BASE + 200);
    let waiting = h::place_mint(
        &mut parts.book,
        &h::default_policy(),
        BASE + 200,
        y,
        h::lower_tick(),
        h::higher_tick(),
        BUDGET,
        ORDER_FEE,
        MINT_CASH_NEED,
    );
    let reserved = parts.incentives.split(RESERVED_SUBSIDY);
    parts.book.reserve_subsidy(refunded, SUBSIDY_RATE, reserved);
    assert_eq!(parts.book.pending_mints(), 3);
    assert_eq!(parts.book.pending_sells(), 1);
    assert_eq!(parts.book.waiting_cash_need(), MIXED_CASH_NEED);

    let escrow = parts.book.withdraw_order_escrow(filled);
    destroy(escrow);
    parts
        .book
        .finish_fill(
            filled,
            order_queue::status_open(),
            order_queue::new_held_position(FILLED_ORDER_ID, FILLED_ORDER_ID, TAU_0),
            FILLED_QUANTITY,
            FILLED_COST,
            FILL_MS,
        );
    refund(&mut parts, refunded, order_queue::reason_no_cash());
    refund(&mut parts, sell, order_queue::reason_deadline());

    // Only mint 3 (y) is left.
    assert_eq!(parts.book.pending_mints(), 1);
    assert_eq!(parts.book.pending_sells(), 0);
    assert_eq!(parts.book.account_waiting(x), 0);
    assert_eq!(parts.book.account_waiting(y), 1);
    assert_eq!(parts.book.waiting_cash_need(), MINT_CASH_NEED);
    // Escrow is exactly mint 3's budget and fee.
    assert_eq!(parts.book.escrow_value(), MINT_ESCROW);
    assert_eq!(parts.incentives.value(), INCENTIVES);
    assert_eq!(parts.book.pins().length(), 2);
    assert_eq!(*parts.book.pins().get(&h::lower_tick()), 1);
    assert_eq!(*parts.book.pins().get(&h::higher_tick()), 1);
    assert_eq!(parts.book.cohort(0).span_unfinished(), 0);
    assert_eq!(parts.book.cohort(1).span_unfinished(), 1);
    assert_eq!(
        parts.book.try_order(waiting).destroy_some().status(),
        order_queue::status_pending(),
    );

    parts.book.advance_heads();
    assert_eq!(parts.book.cohort_count(), 1);
    assert_eq!(parts.book.resolve_head(), 2);
    destroy(parts);
}

// === Helpers ===

/// Place one mint with a reserved subsidy, refund it for `reason`, and check
/// where every part of its escrow went and that it released everything once.
fun refund_mint_and_check(reason: u8, fee_kept: bool) {
    let mut parts = new_parts();
    let id = place_mint_with_subsidy(&mut parts);

    let outcome = refund(&mut parts, id, reason);

    let fee_to_cash = if (fee_kept) ORDER_FEE else 0;
    assert_eq!(outcome.escrow_returned(), BUDGET);
    assert_eq!(outcome.order_fee_returned(), ORDER_FEE - fee_to_cash);
    assert_eq!(outcome.subsidy_returned(), RESERVED_SUBSIDY);
    assert!(!outcome.position_returned());
    assert_eq!(outcome.owed(), MINT_OWED);
    assert_eq!(outcome.shortfall(), 0);
    assert_eq!(parts.book.escrow_value(), 0);
    assert_eq!(parts.cash.balance(), fee_to_cash);
    assert_eq!(parts.incentives.value(), INCENTIVES);
    let record = parts.book.try_order(id).destroy_some();
    assert_eq!(record.status(), order_queue::status_refunded());
    assert_eq!(record.result().reason(), reason);
    assert_eq!(record.result().result_quantity(), 0);
    assert_eq!(record.result().result_amount(), 0);
    assert_eq!(record.result().finished_at_ms(), REFUND_MS);
    assert_eq!(record.position().order_id(), 0);
    assert_eq!(parts.book.pending_mints(), 0);
    assert_eq!(parts.book.account_waiting(h::account(0)), 0);
    assert_eq!(parts.book.waiting_cash_need(), 0);
    assert_eq!(parts.book.pins().length(), 0);
    assert_eq!(parts.book.cohort(0).span_unfinished(), 0);
    destroy(parts);
}

fun new_parts(): Parts {
    let ctx = &mut tx_context::dummy();
    Parts {
        book: order_queue::new_book(ctx),
        exposure: h::new_exposure(ctx),
        cash: expiry_cash::new(),
        incentives: balance::create_for_testing(INCENTIVES),
    }
}

fun refund(parts: &mut Parts, record_id: u64, reason: u8): order_queue::RefundOutcome {
    refund_option(parts, record_id, reason).destroy_some()
}

fun refund_option(
    parts: &mut Parts,
    record_id: u64,
    reason: u8,
): Option<order_queue::RefundOutcome> {
    parts
        .book
        .refund_order(
            &mut parts.exposure,
            &mut parts.cash,
            &mut parts.incentives,
            record_id,
            reason,
            false,
            REFUND_MS,
        )
}

fun place_mint(book: &mut OrderBook, account_id: ID): u64 {
    h::place_mint(
        book,
        &h::default_policy(),
        BASE,
        account_id,
        h::lower_tick(),
        h::higher_tick(),
        BUDGET,
        ORDER_FEE,
        MINT_CASH_NEED,
    )
}

/// A mint whose commit reserved `RESERVED_SUBSIDY` from the incentive balance.
fun place_mint_with_subsidy(parts: &mut Parts): u64 {
    let id = place_mint(&mut parts.book, h::account(0));
    let reserved = parts.incentives.split(RESERVED_SUBSIDY);
    parts.book.reserve_subsidy(id, SUBSIDY_RATE, reserved);
    id
}

fun place_sell(book: &mut OrderBook): u64 {
    place_sell_at(book, BASE)
}

fun place_sell_at(book: &mut OrderBook, now_ms: u64): u64 {
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

/// Replace the book's escrow with `amount`, to stage a shortfall.
fun set_escrow(book: &mut OrderBook, amount: u64) {
    let all = book.withdraw_all_escrow();
    destroy(all);
    book.deposit_escrow(balance::create_for_testing(amount));
}
