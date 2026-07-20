// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Frozen-mark share, payout, budget, and escrow-to-idle accounting.
#[test_only]
module deepbook_predict::scope_mechanics__intent_accounting__lp_book_tests;

use deepbook_predict::{lp_book, lp_book_test_support::{Self, LP_BOOK_TEST_SUPPORT}};
use dusdc::dusdc::DUSDC;
use std::unit_test::{assert_eq, destroy};
use sui::{balance, coin};

const ALICE: address = @0xA;
const NO_MIN_OUTPUT: u64 = 0;
const ZERO_COUNT: u64 = 0;
const ONE_COUNT: u64 = 1;
const TWO_COUNT: u64 = 2;
const THREE_COUNT: u64 = 3;
const LOCKED_SUPPLY: u64 = 30_000_000;
const POOL_VALUE_TWO_X: u64 = 60_000_000;
const SUPPLY_PAYMENT: u64 = 20_000_000;
const SUPPLY_SHARES: u64 = 10_000_000;
const TOTAL_AFTER_SUPPLY: u64 = 40_000_000;
const WITHDRAW_SHARES: u64 = 10_000_000;
const WITHDRAW_PAYOUT: u64 = 20_000_000;
const TOTAL_AFTER_WITHDRAW: u64 = 20_000_000;
const IDLE_AFTER_WITHDRAW: u64 = 40_000_000;
const FROZEN_IDLE: u64 = 50_000_000;
const FROZEN_PAYOUT: u64 = 16_666_666;
const IDLE_AFTER_TWO_FROZEN_PAYOUTS: u64 = 16_666_668;
const TOTAL_AFTER_TWO_WITHDRAWS: u64 = 10_000_000;
const UNIT_MARK_VALUE: u64 = 30_000_000;
const REQUEST_AMOUNT: u64 = 10_000_000;
const TWO_FILLED_TOTAL: u64 = 50_000_000;
const THREE_FILLED_TOTAL: u64 = 60_000_000;
const CANCELLED_REQUESTS: u64 = 2;

#[test]
fun priced_supply_mints_proportional_shares_and_joins_full_payment() {
    let ctx = &mut tx_context::dummy();
    let (mut book, mut ledger) = lp_book_test_support::new_book_and_ledger(ctx);
    book.mint_locked_liquidity(LOCKED_SUPPLY);
    let payment = coin::mint_for_testing<DUSDC>(SUPPLY_PAYMENT, ctx);
    book.request_supply(
        payment,
        lp_book_test_support::account_id(),
        ALICE,
        NO_MIN_OUTPUT,
    );

    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(POOL_VALUE_TWO_X, LOCKED_SUPPLY),
        lp_book_test_support::vault_id(),
        option::none(),
        option::none(),
        ctx,
    );

    lp_book_test_support::assert_summary(&summary, ONE_COUNT, ZERO_COUNT, ONE_COUNT);
    assert_eq!(book.total_supply(), TOTAL_AFTER_SUPPLY);
    assert_eq!(TOTAL_AFTER_SUPPLY - LOCKED_SUPPLY, SUPPLY_SHARES);
    assert_eq!(ledger.idle_balance(), SUPPLY_PAYMENT);
    assert_eq!(book.supply_requests_pending(), ZERO_COUNT);
    destroy(book);
    destroy(ledger);
}

#[test]
fun priced_withdraw_burns_shares_and_pays_from_idle() {
    let ctx = &mut tx_context::dummy();
    let (mut book, mut ledger) = lp_book_test_support::new_book_and_ledger(ctx);
    book.mint_locked_liquidity(LOCKED_SUPPLY);
    ledger.receive_idle(balance::create_for_testing<DUSDC>(POOL_VALUE_TWO_X));
    let lp = coin::mint_for_testing<LP_BOOK_TEST_SUPPORT>(WITHDRAW_SHARES, ctx);
    book.request_withdraw(
        lp,
        lp_book_test_support::account_id(),
        ALICE,
        NO_MIN_OUTPUT,
    );

    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(POOL_VALUE_TWO_X, LOCKED_SUPPLY),
        lp_book_test_support::vault_id(),
        option::none(),
        option::none(),
        ctx,
    );

    lp_book_test_support::assert_summary(&summary, ZERO_COUNT, ONE_COUNT, ONE_COUNT);
    assert_eq!(LOCKED_SUPPLY - WITHDRAW_SHARES, TOTAL_AFTER_WITHDRAW);
    assert_eq!(book.total_supply(), TOTAL_AFTER_WITHDRAW);
    assert_eq!(POOL_VALUE_TWO_X - WITHDRAW_PAYOUT, IDLE_AFTER_WITHDRAW);
    assert_eq!(ledger.idle_balance(), IDLE_AFTER_WITHDRAW);
    assert_eq!(book.withdraw_requests_pending(), ZERO_COUNT);
    destroy(book);
    destroy(ledger);
}

#[test]
fun two_withdrawals_use_one_frozen_mark_instead_of_repricing() {
    let ctx = &mut tx_context::dummy();
    let (mut book, mut ledger) = lp_book_test_support::new_book_and_ledger(ctx);
    book.mint_locked_liquidity(LOCKED_SUPPLY);
    ledger.receive_idle(balance::create_for_testing<DUSDC>(FROZEN_IDLE));
    let first = coin::mint_for_testing<LP_BOOK_TEST_SUPPORT>(WITHDRAW_SHARES, ctx);
    book.request_withdraw(
        first,
        lp_book_test_support::account_id(),
        ALICE,
        NO_MIN_OUTPUT,
    );
    let second = coin::mint_for_testing<LP_BOOK_TEST_SUPPORT>(WITHDRAW_SHARES, ctx);
    book.request_withdraw(
        second,
        lp_book_test_support::account_id(),
        ALICE,
        NO_MIN_OUTPUT,
    );

    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(FROZEN_IDLE, LOCKED_SUPPLY),
        lp_book_test_support::vault_id(),
        option::none(),
        option::none(),
        ctx,
    );

    lp_book_test_support::assert_summary(&summary, ZERO_COUNT, TWO_COUNT, TWO_COUNT);
    assert_eq!(FROZEN_IDLE - TWO_COUNT * FROZEN_PAYOUT, IDLE_AFTER_TWO_FROZEN_PAYOUTS);
    assert_eq!(ledger.idle_balance(), IDLE_AFTER_TWO_FROZEN_PAYOUTS);
    assert_eq!(book.total_supply(), TOTAL_AFTER_TWO_WITHDRAWS);
    destroy(book);
    destroy(ledger);
}

#[test]
fun bounded_supply_budget_fills_only_that_many_heads() {
    let ctx = &mut tx_context::dummy();
    let (mut book, mut ledger) = lp_book_test_support::new_book_and_ledger(ctx);
    book.mint_locked_liquidity(LOCKED_SUPPLY);
    let mut count = ZERO_COUNT;
    while (count < THREE_COUNT) {
        let payment = coin::mint_for_testing<DUSDC>(REQUEST_AMOUNT, ctx);
        book.request_supply(
            payment,
            lp_book_test_support::account_id(),
            ALICE,
            NO_MIN_OUTPUT,
        );
        count = count + ONE_COUNT;
    };

    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(UNIT_MARK_VALUE, LOCKED_SUPPLY),
        lp_book_test_support::vault_id(),
        option::some(TWO_COUNT),
        option::none(),
        ctx,
    );

    lp_book_test_support::assert_summary(&summary, TWO_COUNT, ZERO_COUNT, TWO_COUNT);
    assert_eq!(book.supply_requests_pending(), ONE_COUNT);
    assert_eq!(book.total_supply(), TWO_FILLED_TOTAL);
    assert_eq!(ledger.idle_balance(), TWO_COUNT * REQUEST_AMOUNT);
    destroy(book);
    destroy(ledger);
}

#[test]
fun unbounded_supply_budget_drains_every_queued_head() {
    let ctx = &mut tx_context::dummy();
    let (mut book, mut ledger) = lp_book_test_support::new_book_and_ledger(ctx);
    book.mint_locked_liquidity(LOCKED_SUPPLY);
    let mut count = ZERO_COUNT;
    while (count < THREE_COUNT) {
        let payment = coin::mint_for_testing<DUSDC>(REQUEST_AMOUNT, ctx);
        book.request_supply(
            payment,
            lp_book_test_support::account_id(),
            ALICE,
            NO_MIN_OUTPUT,
        );
        count = count + ONE_COUNT;
    };

    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(UNIT_MARK_VALUE, LOCKED_SUPPLY),
        lp_book_test_support::vault_id(),
        option::none(),
        option::none(),
        ctx,
    );

    lp_book_test_support::assert_summary(&summary, THREE_COUNT, ZERO_COUNT, THREE_COUNT);
    assert_eq!(book.supply_requests_pending(), ZERO_COUNT);
    assert_eq!(book.total_supply(), THREE_FILLED_TOTAL);
    assert_eq!(ledger.idle_balance(), THREE_COUNT * REQUEST_AMOUNT);
    destroy(book);
    destroy(ledger);
}

#[test]
fun independent_budgets_process_supply_then_funded_withdraw_under_pressure() {
    let ctx = &mut tx_context::dummy();
    let (mut book, mut ledger) = lp_book_test_support::new_book_and_ledger(ctx);
    book.mint_locked_liquidity(LOCKED_SUPPLY);
    let mut count = ZERO_COUNT;
    while (count < THREE_COUNT) {
        let supply = coin::mint_for_testing<DUSDC>(REQUEST_AMOUNT, ctx);
        book.request_supply(
            supply,
            lp_book_test_support::account_id(),
            ALICE,
            NO_MIN_OUTPUT,
        );
        count = count + ONE_COUNT;
    };
    let withdraw = coin::mint_for_testing<LP_BOOK_TEST_SUPPORT>(REQUEST_AMOUNT, ctx);
    book.request_withdraw(
        withdraw,
        lp_book_test_support::account_id(),
        ALICE,
        NO_MIN_OUTPUT,
    );

    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(UNIT_MARK_VALUE, LOCKED_SUPPLY),
        lp_book_test_support::vault_id(),
        option::some(ONE_COUNT),
        option::some(ONE_COUNT),
        ctx,
    );

    lp_book_test_support::assert_summary(&summary, ONE_COUNT, ONE_COUNT, TWO_COUNT);
    assert_eq!(book.supply_requests_pending(), TWO_COUNT);
    assert_eq!(book.withdraw_requests_pending(), ZERO_COUNT);
    assert_eq!(book.total_supply(), LOCKED_SUPPLY);
    assert_eq!(ledger.idle_balance(), ZERO_COUNT);
    destroy(book);
    destroy(ledger);
}

#[test]
fun zero_budgets_leave_both_queue_heads_unprocessed() {
    let ctx = &mut tx_context::dummy();
    let (mut book, mut ledger) = lp_book_test_support::new_book_and_ledger(ctx);
    book.mint_locked_liquidity(LOCKED_SUPPLY);
    ledger.receive_idle(balance::create_for_testing<DUSDC>(UNIT_MARK_VALUE));
    let supply = coin::mint_for_testing<DUSDC>(REQUEST_AMOUNT, ctx);
    book.request_supply(
        supply,
        lp_book_test_support::account_id(),
        ALICE,
        NO_MIN_OUTPUT,
    );
    let withdraw = coin::mint_for_testing<LP_BOOK_TEST_SUPPORT>(REQUEST_AMOUNT, ctx);
    book.request_withdraw(
        withdraw,
        lp_book_test_support::account_id(),
        ALICE,
        NO_MIN_OUTPUT,
    );

    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(UNIT_MARK_VALUE, LOCKED_SUPPLY),
        lp_book_test_support::vault_id(),
        option::some(ZERO_COUNT),
        option::some(ZERO_COUNT),
        ctx,
    );

    lp_book_test_support::assert_summary(&summary, ZERO_COUNT, ZERO_COUNT, ZERO_COUNT);
    assert_eq!(book.supply_requests_pending(), ONE_COUNT);
    assert_eq!(book.withdraw_requests_pending(), ONE_COUNT);
    assert_eq!(book.total_supply(), LOCKED_SUPPLY);
    assert_eq!(ledger.idle_balance(), UNIT_MARK_VALUE);
    destroy(book);
    destroy(ledger);
}

#[test]
fun user_cancelled_requests_do_not_spend_drain_budget() {
    let ctx = &mut tx_context::dummy();
    let (mut book, mut ledger) = lp_book_test_support::new_book_and_ledger(ctx);
    book.mint_locked_liquidity(LOCKED_SUPPLY);
    let mut count = ZERO_COUNT;
    while (count < CANCELLED_REQUESTS) {
        let payment = coin::mint_for_testing<DUSDC>(REQUEST_AMOUNT, ctx);
        let index = book.request_supply(
            payment,
            lp_book_test_support::account_id(),
            ALICE,
            NO_MIN_OUTPUT,
        );
        let (_, _, refund) = book.cancel_supply_request(ALICE, index);
        destroy(refund);
        count = count + ONE_COUNT;
    };
    let live = coin::mint_for_testing<DUSDC>(REQUEST_AMOUNT, ctx);
    let live_index = book.request_supply(
        live,
        lp_book_test_support::account_id(),
        ALICE,
        NO_MIN_OUTPUT,
    );
    assert_eq!(live_index, CANCELLED_REQUESTS);

    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(UNIT_MARK_VALUE, LOCKED_SUPPLY),
        lp_book_test_support::vault_id(),
        option::some(ONE_COUNT),
        option::none(),
        ctx,
    );

    lp_book_test_support::assert_summary(&summary, ONE_COUNT, ZERO_COUNT, ONE_COUNT);
    assert_eq!(book.supply_requests_pending(), ZERO_COUNT);
    assert_eq!(ledger.idle_balance(), REQUEST_AMOUNT);
    destroy(book);
    destroy(ledger);
}
