// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// RP-2 non-executable refund and RP-12 bounded limit-miss response policies.
#[test_only]
module deepbook_predict::scope_mechanics__intent_policy__lp_book_response_tests;

use deepbook_predict::{constants, lp_book, lp_book_test_support::{Self, LP_BOOK_TEST_SUPPORT}};
use dusdc::dusdc::DUSDC;
use std::unit_test::{assert_eq, destroy};
use sui::{balance, coin};

const ALICE: address = @0xA;
const NO_MIN_OUTPUT: u64 = 0;
const ZERO_COUNT: u64 = 0;
const ONE_COUNT: u64 = 1;
const TWO_COUNT: u64 = 2;
const THREE_COUNT: u64 = 3;
const FIRST_INDEX: u64 = 0;
const SECOND_INDEX: u64 = 1;
const NON_EXECUTABLE_REASON: u8 = 1;
const LIMIT_EXPIRED_REASON: u8 = 2;
const RAW_UNIT: u64 = 1;
const ONE_PLP: u64 = 1_000_000;
const MIN_EXECUTABLE_POOL_VALUE: u64 = 10_000;
const MAX_EXECUTABLE_POOL_VALUE: u64 = 100_000_000;
const MIN_REQUEST_MAX_EXECUTABLE_POOL_VALUE: u64 = 1_000_000_000;
const SHARES_AT_MIN_EXECUTABLE_PRICE: u64 = 1_000_000_000;
const TOTAL_AFTER_MIN_PRICE_SUPPLY: u64 = 1_001_000_000;
const SHARES_AT_MAX_EXECUTABLE_PRICE: u64 = 100_000;
const TOTAL_AFTER_MAX_PRICE_SUPPLY: u64 = 1_100_000;
const ZERO_SHARE_RATIO_POOL_VALUE: u64 = 100_000_000_000_001;
const ZERO_PAYOUT_RATIO_TOTAL_SUPPLY: u64 = 1_000_001;
const FIRST_POSITIVE_WITHDRAW_POOL_VALUE: u64 = 10_001;
const FIRST_POSITIVE_WITHDRAW_PAYOUT: u64 = 10_000;
const NEAR_MAX_SUPPLY_HEADROOM: u64 = 5_000_000;
const SUPPLY_BUDGET: u64 = 2;
const WITHDRAW_BUDGET: u64 = 1;
const DRY_MARK_VALUE: u64 = 30_000_000;
const DRY_WITHDRAW_AMOUNT: u64 = 20_000_000;
const DRY_IDLE_AFTER_FIRST: u64 = 10_000_000;
const DRY_TOTAL_AFTER_FIRST: u64 = 10_000_000;
const LIMIT_TOTAL_SUPPLY: u64 = 30_000_000;
const LIMIT_MISS_POOL_VALUE: u64 = 60_000_000;
const LIMIT_PASS_SUPPLY_POOL_VALUE: u64 = 30_000_000;
const LIMIT_SUPPLY_AMOUNT: u64 = 20_000_000;
const LIMIT_SUPPLY_MISS_QUOTE: u64 = 10_000_000;
const LIMIT_SUPPLY_MIN_OUT: u64 = 11_000_000;
const LIMIT_SUPPLY_PASS_QUOTE: u64 = 20_000_000;
const LIMIT_WITHDRAW_AMOUNT: u64 = 10_000_000;
const LIMIT_WITHDRAW_MISS_QUOTE: u64 = 20_000_000;
const LIMIT_WITHDRAW_MIN_OUT: u64 = 21_000_000;
const LIMIT_WITHDRAW_PASS_POOL_VALUE: u64 = 63_000_000;
const LIMIT_WITHDRAW_IDLE: u64 = 60_000_000;
const LIMIT_WITHDRAW_IDLE_AFTER_FILL: u64 = 39_000_000;
const LIMIT_WITHDRAW_TOTAL_AFTER_FILL: u64 = 20_000_000;

#[test]
fun priced_supply_with_zero_pool_value_refunds() {
    let ctx = &mut tx_context::dummy();
    let (mut book, mut ledger) = lp_book_test_support::new_book_and_ledger(ctx);
    book.mint_locked_liquidity(constants::min_supply_request!());
    let payment = coin::mint_for_testing<DUSDC>(constants::min_supply_request!(), ctx);
    book.request_supply(
        payment,
        lp_book_test_support::account_id(),
        ALICE,
        NO_MIN_OUTPUT,
    );

    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(ZERO_COUNT, constants::min_supply_request!()),
        lp_book_test_support::vault_id(),
        option::none(),
        option::none(),
        ctx,
    );

    lp_book_test_support::assert_summary(&summary, ZERO_COUNT, ZERO_COUNT, ONE_COUNT);
    assert_eq!(book.supply_requests_pending(), ZERO_COUNT);
    assert_eq!(book.total_supply(), constants::min_supply_request!());
    assert_eq!(ledger.idle_balance(), ZERO_COUNT);
    lp_book_test_support::assert_cancelled_event(
        ONE_COUNT,
        FIRST_INDEX,
        ALICE,
        FIRST_INDEX,
        constants::min_supply_request!(),
        true,
        NON_EXECUTABLE_REASON,
        ZERO_COUNT,
    );
    destroy(book);
    destroy(ledger);
}

#[test]
fun priced_supply_that_rounds_to_zero_shares_refunds() {
    let ctx = &mut tx_context::dummy();
    let (mut book, mut ledger) = lp_book_test_support::new_book_and_ledger(ctx);
    book.mint_locked_liquidity(constants::min_supply_request!());
    let zero_side = coin::mint_for_testing<DUSDC>(constants::min_supply_request!(), ctx);
    book.request_supply(
        zero_side,
        lp_book_test_support::account_id(),
        ALICE,
        NO_MIN_OUTPUT,
    );

    let zero_summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(
            ZERO_SHARE_RATIO_POOL_VALUE,
            constants::min_supply_request!(),
        ),
        lp_book_test_support::vault_id(),
        option::none(),
        option::none(),
        ctx,
    );
    lp_book_test_support::assert_summary(&zero_summary, ZERO_COUNT, ZERO_COUNT, ONE_COUNT);
    assert_eq!(book.total_supply(), constants::min_supply_request!());
    assert_eq!(ledger.idle_balance(), ZERO_COUNT);
    lp_book_test_support::assert_cancelled_event(
        ONE_COUNT,
        FIRST_INDEX,
        ALICE,
        FIRST_INDEX,
        constants::min_supply_request!(),
        true,
        NON_EXECUTABLE_REASON,
        ZERO_COUNT,
    );

    // The arithmetic-zero ratio is already outside the executable band. The
    // band edge below proves every admitted minimum request has positive output.
    let positive_side = coin::mint_for_testing<DUSDC>(constants::min_supply_request!(), ctx);
    book.request_supply(
        positive_side,
        lp_book_test_support::account_id(),
        ALICE,
        NO_MIN_OUTPUT,
    );
    let positive_summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(
            MIN_REQUEST_MAX_EXECUTABLE_POOL_VALUE,
            constants::min_supply_request!(),
        ),
        lp_book_test_support::vault_id(),
        option::none(),
        option::none(),
        ctx,
    );
    lp_book_test_support::assert_summary(&positive_summary, ONE_COUNT, ZERO_COUNT, ONE_COUNT);
    assert_eq!(
        book.total_supply(),
        constants::min_supply_request!() + SHARES_AT_MAX_EXECUTABLE_PRICE,
    );
    assert_eq!(ledger.idle_balance(), constants::min_supply_request!());
    destroy(book);
    destroy(ledger);
}

#[test]
fun priced_withdraw_that_rounds_to_zero_payout_refunds() {
    let ctx = &mut tx_context::dummy();
    let (mut book, mut ledger) = lp_book_test_support::new_book_and_ledger(ctx);
    book.mint_locked_liquidity(ZERO_PAYOUT_RATIO_TOTAL_SUPPLY);
    let zero_side = coin::mint_for_testing<LP_BOOK_TEST_SUPPORT>(
        constants::min_withdraw_request!(),
        ctx,
    );
    book.request_withdraw(
        zero_side,
        lp_book_test_support::account_id(),
        ALICE,
        NO_MIN_OUTPUT,
    );

    let zero_summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(RAW_UNIT, ZERO_PAYOUT_RATIO_TOTAL_SUPPLY),
        lp_book_test_support::vault_id(),
        option::none(),
        option::none(),
        ctx,
    );
    lp_book_test_support::assert_summary(&zero_summary, ZERO_COUNT, ZERO_COUNT, ONE_COUNT);
    assert_eq!(book.total_supply(), ZERO_PAYOUT_RATIO_TOTAL_SUPPLY);
    assert_eq!(book.withdraw_requests_pending(), ZERO_COUNT);
    lp_book_test_support::assert_cancelled_event(
        ONE_COUNT,
        FIRST_INDEX,
        ALICE,
        FIRST_INDEX,
        constants::min_withdraw_request!(),
        false,
        NON_EXECUTABLE_REASON,
        ZERO_COUNT,
    );

    // The arithmetic-zero ratio is below the executable band. Its first band
    // edge pays a positive amount and exercises the receiving side of H-7.
    ledger.receive_idle(
        balance::create_for_testing<DUSDC>(FIRST_POSITIVE_WITHDRAW_PAYOUT),
    );
    let positive_side = coin::mint_for_testing<LP_BOOK_TEST_SUPPORT>(
        constants::min_withdraw_request!(),
        ctx,
    );
    book.request_withdraw(
        positive_side,
        lp_book_test_support::account_id(),
        ALICE,
        NO_MIN_OUTPUT,
    );
    let positive_summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(
            FIRST_POSITIVE_WITHDRAW_POOL_VALUE,
            ZERO_PAYOUT_RATIO_TOTAL_SUPPLY,
        ),
        lp_book_test_support::vault_id(),
        option::none(),
        option::none(),
        ctx,
    );
    lp_book_test_support::assert_summary(&positive_summary, ZERO_COUNT, ONE_COUNT, ONE_COUNT);
    assert_eq!(book.total_supply(), RAW_UNIT);
    assert_eq!(ledger.idle_balance(), ZERO_COUNT);
    destroy(book);
    destroy(ledger);
}

#[test]
fun supply_at_min_executable_plp_price_fills() {
    let ctx = &mut tx_context::dummy();
    let (mut book, mut ledger) = lp_book_test_support::new_book_and_ledger(ctx);
    book.mint_locked_liquidity(ONE_PLP);
    let payment = coin::mint_for_testing<DUSDC>(constants::min_supply_request!(), ctx);
    book.request_supply(
        payment,
        lp_book_test_support::account_id(),
        ALICE,
        NO_MIN_OUTPUT,
    );

    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(MIN_EXECUTABLE_POOL_VALUE, ONE_PLP),
        lp_book_test_support::vault_id(),
        option::none(),
        option::none(),
        ctx,
    );

    lp_book_test_support::assert_summary(&summary, ONE_COUNT, ZERO_COUNT, ONE_COUNT);
    assert_eq!(book.total_supply(), TOTAL_AFTER_MIN_PRICE_SUPPLY);
    assert_eq!(TOTAL_AFTER_MIN_PRICE_SUPPLY - ONE_PLP, SHARES_AT_MIN_EXECUTABLE_PRICE);
    assert_eq!(ledger.idle_balance(), constants::min_supply_request!());
    destroy(book);
    destroy(ledger);
}

#[test]
fun supply_below_min_executable_plp_price_refunds() {
    let ctx = &mut tx_context::dummy();
    let (mut book, mut ledger) = lp_book_test_support::new_book_and_ledger(ctx);
    book.mint_locked_liquidity(ONE_PLP);
    let payment = coin::mint_for_testing<DUSDC>(constants::min_supply_request!(), ctx);
    book.request_supply(
        payment,
        lp_book_test_support::account_id(),
        ALICE,
        NO_MIN_OUTPUT,
    );

    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(MIN_EXECUTABLE_POOL_VALUE - RAW_UNIT, ONE_PLP),
        lp_book_test_support::vault_id(),
        option::none(),
        option::none(),
        ctx,
    );

    lp_book_test_support::assert_summary(&summary, ZERO_COUNT, ZERO_COUNT, ONE_COUNT);
    assert_eq!(book.total_supply(), ONE_PLP);
    assert_eq!(book.supply_requests_pending(), ZERO_COUNT);
    assert_eq!(ledger.idle_balance(), ZERO_COUNT);
    lp_book_test_support::assert_cancelled_event(
        ONE_COUNT,
        FIRST_INDEX,
        ALICE,
        FIRST_INDEX,
        constants::min_supply_request!(),
        true,
        NON_EXECUTABLE_REASON,
        ZERO_COUNT,
    );
    destroy(book);
    destroy(ledger);
}

#[test]
fun supply_at_max_executable_plp_price_fills() {
    let ctx = &mut tx_context::dummy();
    let (mut book, mut ledger) = lp_book_test_support::new_book_and_ledger(ctx);
    book.mint_locked_liquidity(ONE_PLP);
    let payment = coin::mint_for_testing<DUSDC>(constants::min_supply_request!(), ctx);
    book.request_supply(
        payment,
        lp_book_test_support::account_id(),
        ALICE,
        NO_MIN_OUTPUT,
    );

    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(MAX_EXECUTABLE_POOL_VALUE, ONE_PLP),
        lp_book_test_support::vault_id(),
        option::none(),
        option::none(),
        ctx,
    );

    lp_book_test_support::assert_summary(&summary, ONE_COUNT, ZERO_COUNT, ONE_COUNT);
    assert_eq!(book.total_supply(), TOTAL_AFTER_MAX_PRICE_SUPPLY);
    assert_eq!(TOTAL_AFTER_MAX_PRICE_SUPPLY - ONE_PLP, SHARES_AT_MAX_EXECUTABLE_PRICE);
    assert_eq!(ledger.idle_balance(), constants::min_supply_request!());
    destroy(book);
    destroy(ledger);
}

#[test]
fun supply_above_max_executable_plp_price_refunds() {
    let ctx = &mut tx_context::dummy();
    let (mut book, mut ledger) = lp_book_test_support::new_book_and_ledger(ctx);
    book.mint_locked_liquidity(ONE_PLP);
    let payment = coin::mint_for_testing<DUSDC>(constants::min_supply_request!(), ctx);
    book.request_supply(
        payment,
        lp_book_test_support::account_id(),
        ALICE,
        NO_MIN_OUTPUT,
    );

    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(MAX_EXECUTABLE_POOL_VALUE + RAW_UNIT, ONE_PLP),
        lp_book_test_support::vault_id(),
        option::none(),
        option::none(),
        ctx,
    );

    lp_book_test_support::assert_summary(&summary, ZERO_COUNT, ZERO_COUNT, ONE_COUNT);
    assert_eq!(book.total_supply(), ONE_PLP);
    assert_eq!(book.supply_requests_pending(), ZERO_COUNT);
    assert_eq!(ledger.idle_balance(), ZERO_COUNT);
    lp_book_test_support::assert_cancelled_event(
        ONE_COUNT,
        FIRST_INDEX,
        ALICE,
        FIRST_INDEX,
        constants::min_supply_request!(),
        true,
        NON_EXECUTABLE_REASON,
        ZERO_COUNT,
    );
    destroy(book);
    destroy(ledger);
}

#[test]
fun oversized_supply_that_exceeds_u64_shares_refunds() {
    let ctx = &mut tx_context::dummy();
    let (mut book, mut ledger) = lp_book_test_support::new_book_and_ledger(ctx);
    book.mint_locked_liquidity(ONE_PLP);
    let payment = coin::mint_for_testing<DUSDC>(std::u64::max_value!(), ctx);
    book.request_supply(
        payment,
        lp_book_test_support::account_id(),
        ALICE,
        NO_MIN_OUTPUT,
    );

    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(MIN_EXECUTABLE_POOL_VALUE, ONE_PLP),
        lp_book_test_support::vault_id(),
        option::none(),
        option::none(),
        ctx,
    );

    lp_book_test_support::assert_summary(&summary, ZERO_COUNT, ZERO_COUNT, ONE_COUNT);
    assert_eq!(book.total_supply(), ONE_PLP);
    assert_eq!(book.supply_requests_pending(), ZERO_COUNT);
    assert_eq!(ledger.idle_balance(), ZERO_COUNT);
    lp_book_test_support::assert_cancelled_event(
        ONE_COUNT,
        FIRST_INDEX,
        ALICE,
        FIRST_INDEX,
        std::u64::max_value!(),
        true,
        NON_EXECUTABLE_REASON,
        ZERO_COUNT,
    );
    destroy(book);
    destroy(ledger);
}

#[test]
fun supply_that_exceeds_remaining_total_supply_headroom_refunds() {
    let ctx = &mut tx_context::dummy();
    let (mut book, mut ledger) = lp_book_test_support::new_book_and_ledger(ctx);
    let near_max_supply = std::u64::max_value!() - NEAR_MAX_SUPPLY_HEADROOM;
    book.mint_locked_liquidity(near_max_supply);
    let payment = coin::mint_for_testing<DUSDC>(constants::min_supply_request!(), ctx);
    book.request_supply(
        payment,
        lp_book_test_support::account_id(),
        ALICE,
        NO_MIN_OUTPUT,
    );

    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(near_max_supply, near_max_supply),
        lp_book_test_support::vault_id(),
        option::none(),
        option::none(),
        ctx,
    );

    lp_book_test_support::assert_summary(&summary, ZERO_COUNT, ZERO_COUNT, ONE_COUNT);
    assert_eq!(book.total_supply(), near_max_supply);
    assert_eq!(book.supply_requests_pending(), ZERO_COUNT);
    assert_eq!(ledger.idle_balance(), ZERO_COUNT);
    destroy(book);
    destroy(ledger);
}

#[test]
fun non_executable_supply_refunds_spend_supply_budget() {
    let ctx = &mut tx_context::dummy();
    let (mut book, mut ledger) = lp_book_test_support::new_book_and_ledger(ctx);
    book.mint_locked_liquidity(ONE_PLP);
    let mut count = ZERO_COUNT;
    while (count < THREE_COUNT) {
        let payment = coin::mint_for_testing<DUSDC>(constants::min_supply_request!(), ctx);
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
        lp_book::new_flush_mark(MIN_EXECUTABLE_POOL_VALUE - RAW_UNIT, ONE_PLP),
        lp_book_test_support::vault_id(),
        option::some(SUPPLY_BUDGET),
        option::none(),
        ctx,
    );

    lp_book_test_support::assert_summary(&summary, ZERO_COUNT, ZERO_COUNT, SUPPLY_BUDGET);
    assert_eq!(book.supply_requests_pending(), ONE_COUNT);
    assert_eq!(book.total_supply(), ONE_PLP);
    assert_eq!(ledger.idle_balance(), ZERO_COUNT);
    lp_book_test_support::assert_cancelled_event(
        TWO_COUNT,
        FIRST_INDEX,
        ALICE,
        FIRST_INDEX,
        constants::min_supply_request!(),
        true,
        NON_EXECUTABLE_REASON,
        TWO_COUNT,
    );
    lp_book_test_support::assert_cancelled_event(
        TWO_COUNT,
        SECOND_INDEX,
        ALICE,
        SECOND_INDEX,
        constants::min_supply_request!(),
        true,
        NON_EXECUTABLE_REASON,
        ONE_COUNT,
    );
    destroy(book);
    destroy(ledger);
}

#[test]
fun non_executable_withdraw_refunds_spend_withdraw_budget() {
    let ctx = &mut tx_context::dummy();
    let (mut book, mut ledger) = lp_book_test_support::new_book_and_ledger(ctx);
    book.mint_locked_liquidity(ZERO_PAYOUT_RATIO_TOTAL_SUPPLY);
    let first = coin::mint_for_testing<LP_BOOK_TEST_SUPPORT>(
        constants::min_withdraw_request!(),
        ctx,
    );
    book.request_withdraw(
        first,
        lp_book_test_support::account_id(),
        ALICE,
        NO_MIN_OUTPUT,
    );
    let second = coin::mint_for_testing<LP_BOOK_TEST_SUPPORT>(
        constants::min_withdraw_request!(),
        ctx,
    );
    book.request_withdraw(
        second,
        lp_book_test_support::account_id(),
        ALICE,
        NO_MIN_OUTPUT,
    );

    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(RAW_UNIT, ZERO_PAYOUT_RATIO_TOTAL_SUPPLY),
        lp_book_test_support::vault_id(),
        option::none(),
        option::some(WITHDRAW_BUDGET),
        ctx,
    );

    lp_book_test_support::assert_summary(&summary, ZERO_COUNT, ZERO_COUNT, WITHDRAW_BUDGET);
    assert_eq!(book.withdraw_requests_pending(), ONE_COUNT);
    assert_eq!(book.total_supply(), ZERO_PAYOUT_RATIO_TOTAL_SUPPLY);
    assert_eq!(ledger.idle_balance(), ZERO_COUNT);
    lp_book_test_support::assert_cancelled_event(
        ONE_COUNT,
        FIRST_INDEX,
        ALICE,
        FIRST_INDEX,
        constants::min_withdraw_request!(),
        false,
        NON_EXECUTABLE_REASON,
        ONE_COUNT,
    );
    destroy(book);
    destroy(ledger);
}

#[test]
fun withdrawals_stop_when_idle_is_dry_and_carry() {
    let ctx = &mut tx_context::dummy();
    let (mut book, mut ledger) = lp_book_test_support::new_book_and_ledger(ctx);
    book.mint_locked_liquidity(DRY_MARK_VALUE);
    ledger.receive_idle(balance::create_for_testing<DUSDC>(DRY_MARK_VALUE));
    let first = coin::mint_for_testing<LP_BOOK_TEST_SUPPORT>(DRY_WITHDRAW_AMOUNT, ctx);
    book.request_withdraw(
        first,
        lp_book_test_support::account_id(),
        ALICE,
        NO_MIN_OUTPUT,
    );
    let second = coin::mint_for_testing<LP_BOOK_TEST_SUPPORT>(DRY_WITHDRAW_AMOUNT, ctx);
    book.request_withdraw(
        second,
        lp_book_test_support::account_id(),
        ALICE,
        NO_MIN_OUTPUT,
    );

    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(DRY_MARK_VALUE, DRY_MARK_VALUE),
        lp_book_test_support::vault_id(),
        option::none(),
        option::none(),
        ctx,
    );

    lp_book_test_support::assert_summary(&summary, ZERO_COUNT, ONE_COUNT, ONE_COUNT);
    assert_eq!(book.withdraw_requests_pending(), ONE_COUNT);
    assert_eq!(book.total_supply(), DRY_TOTAL_AFTER_FIRST);
    assert_eq!(ledger.idle_balance(), DRY_IDLE_AFTER_FIRST);
    destroy(book);
    destroy(ledger);
}

#[test]
fun supply_limit_miss_carries_then_fills_when_mark_improves() {
    let ctx = &mut tx_context::dummy();
    let (mut book, mut ledger) = lp_book_test_support::new_book_and_ledger(ctx);
    book.mint_locked_liquidity(LIMIT_TOTAL_SUPPLY);
    let payment = coin::mint_for_testing<DUSDC>(LIMIT_SUPPLY_AMOUNT, ctx);
    book.request_supply(
        payment,
        lp_book_test_support::account_id(),
        ALICE,
        LIMIT_SUPPLY_MIN_OUT,
    );

    let miss = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(LIMIT_MISS_POOL_VALUE, LIMIT_TOTAL_SUPPLY),
        lp_book_test_support::vault_id(),
        option::none(),
        option::none(),
        ctx,
    );
    lp_book_test_support::assert_summary(&miss, ZERO_COUNT, ZERO_COUNT, ONE_COUNT);
    assert_eq!(book.supply_requests_pending(), ONE_COUNT);
    assert_eq!(book.total_supply(), LIMIT_TOTAL_SUPPLY);
    assert_eq!(ledger.idle_balance(), ZERO_COUNT);
    assert_eq!(LIMIT_SUPPLY_MISS_QUOTE + ONE_PLP, LIMIT_SUPPLY_MIN_OUT);
    lp_book_test_support::assert_limit_missed_event(
        ONE_COUNT,
        FIRST_INDEX,
        ALICE,
        FIRST_INDEX,
        LIMIT_SUPPLY_AMOUNT,
        true,
        LIMIT_SUPPLY_MISS_QUOTE,
        LIMIT_SUPPLY_MIN_OUT,
        ONE_COUNT,
        THREE_COUNT,
    );

    let fill = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(LIMIT_PASS_SUPPLY_POOL_VALUE, LIMIT_TOTAL_SUPPLY),
        lp_book_test_support::vault_id(),
        option::none(),
        option::none(),
        ctx,
    );
    lp_book_test_support::assert_summary(&fill, ONE_COUNT, ZERO_COUNT, ONE_COUNT);
    assert_eq!(book.supply_requests_pending(), ZERO_COUNT);
    assert_eq!(book.total_supply(), LIMIT_TOTAL_SUPPLY + LIMIT_SUPPLY_PASS_QUOTE);
    assert_eq!(ledger.idle_balance(), LIMIT_SUPPLY_AMOUNT);
    destroy(book);
    destroy(ledger);
}

#[test]
fun supply_limit_expires_after_three_misses() {
    let ctx = &mut tx_context::dummy();
    let (mut book, mut ledger) = lp_book_test_support::new_book_and_ledger(ctx);
    book.mint_locked_liquidity(LIMIT_TOTAL_SUPPLY);
    let payment = coin::mint_for_testing<DUSDC>(LIMIT_SUPPLY_AMOUNT, ctx);
    book.request_supply(
        payment,
        lp_book_test_support::account_id(),
        ALICE,
        LIMIT_SUPPLY_MIN_OUT,
    );
    let attempts = constants::lp_request_limit_flush_attempts!();
    let mut count = ZERO_COUNT;
    while (count < attempts - RAW_UNIT) {
        let miss = book.drain(
            &mut ledger,
            lp_book::new_flush_mark(LIMIT_MISS_POOL_VALUE, LIMIT_TOTAL_SUPPLY),
            lp_book_test_support::vault_id(),
            option::none(),
            option::none(),
            ctx,
        );
        lp_book_test_support::assert_summary(&miss, ZERO_COUNT, ZERO_COUNT, ONE_COUNT);
        assert_eq!(book.supply_requests_pending(), ONE_COUNT);
        count = count + ONE_COUNT;
    };

    let expired = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(LIMIT_MISS_POOL_VALUE, LIMIT_TOTAL_SUPPLY),
        lp_book_test_support::vault_id(),
        option::none(),
        option::none(),
        ctx,
    );

    lp_book_test_support::assert_summary(&expired, ZERO_COUNT, ZERO_COUNT, ONE_COUNT);
    assert_eq!(attempts, THREE_COUNT);
    assert_eq!(book.supply_requests_pending(), ZERO_COUNT);
    assert_eq!(book.total_supply(), LIMIT_TOTAL_SUPPLY);
    assert_eq!(ledger.idle_balance(), ZERO_COUNT);
    lp_book_test_support::assert_cancelled_event(
        ONE_COUNT,
        FIRST_INDEX,
        ALICE,
        FIRST_INDEX,
        LIMIT_SUPPLY_AMOUNT,
        true,
        LIMIT_EXPIRED_REASON,
        ZERO_COUNT,
    );
    lp_book_test_support::assert_limit_missed_event(
        TWO_COUNT,
        FIRST_INDEX,
        ALICE,
        FIRST_INDEX,
        LIMIT_SUPPLY_AMOUNT,
        true,
        LIMIT_SUPPLY_MISS_QUOTE,
        LIMIT_SUPPLY_MIN_OUT,
        ONE_COUNT,
        THREE_COUNT,
    );
    lp_book_test_support::assert_limit_missed_event(
        TWO_COUNT,
        SECOND_INDEX,
        ALICE,
        FIRST_INDEX,
        LIMIT_SUPPLY_AMOUNT,
        true,
        LIMIT_SUPPLY_MISS_QUOTE,
        LIMIT_SUPPLY_MIN_OUT,
        TWO_COUNT,
        THREE_COUNT,
    );
    destroy(book);
    destroy(ledger);
}

#[test]
fun withdraw_limit_miss_carries_then_fills_when_mark_improves() {
    let ctx = &mut tx_context::dummy();
    let (mut book, mut ledger) = lp_book_test_support::new_book_and_ledger(ctx);
    book.mint_locked_liquidity(LIMIT_TOTAL_SUPPLY);
    ledger.receive_idle(balance::create_for_testing<DUSDC>(LIMIT_WITHDRAW_IDLE));
    let lp = coin::mint_for_testing<LP_BOOK_TEST_SUPPORT>(LIMIT_WITHDRAW_AMOUNT, ctx);
    book.request_withdraw(
        lp,
        lp_book_test_support::account_id(),
        ALICE,
        LIMIT_WITHDRAW_MIN_OUT,
    );

    let miss = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(LIMIT_MISS_POOL_VALUE, LIMIT_TOTAL_SUPPLY),
        lp_book_test_support::vault_id(),
        option::none(),
        option::none(),
        ctx,
    );
    lp_book_test_support::assert_summary(&miss, ZERO_COUNT, ZERO_COUNT, ONE_COUNT);
    assert_eq!(book.withdraw_requests_pending(), ONE_COUNT);
    assert_eq!(book.total_supply(), LIMIT_TOTAL_SUPPLY);
    assert_eq!(ledger.idle_balance(), LIMIT_WITHDRAW_IDLE);
    assert_eq!(LIMIT_WITHDRAW_MISS_QUOTE + ONE_PLP, LIMIT_WITHDRAW_MIN_OUT);
    lp_book_test_support::assert_limit_missed_event(
        ONE_COUNT,
        FIRST_INDEX,
        ALICE,
        FIRST_INDEX,
        LIMIT_WITHDRAW_AMOUNT,
        false,
        LIMIT_WITHDRAW_MISS_QUOTE,
        LIMIT_WITHDRAW_MIN_OUT,
        ONE_COUNT,
        THREE_COUNT,
    );

    let fill = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(LIMIT_WITHDRAW_PASS_POOL_VALUE, LIMIT_TOTAL_SUPPLY),
        lp_book_test_support::vault_id(),
        option::none(),
        option::none(),
        ctx,
    );
    lp_book_test_support::assert_summary(&fill, ZERO_COUNT, ONE_COUNT, ONE_COUNT);
    assert_eq!(book.withdraw_requests_pending(), ZERO_COUNT);
    assert_eq!(book.total_supply(), LIMIT_WITHDRAW_TOTAL_AFTER_FILL);
    assert_eq!(ledger.idle_balance(), LIMIT_WITHDRAW_IDLE_AFTER_FILL);
    destroy(book);
    destroy(ledger);
}

#[test]
fun withdraw_limit_expires_after_three_misses() {
    let ctx = &mut tx_context::dummy();
    let (mut book, mut ledger) = lp_book_test_support::new_book_and_ledger(ctx);
    book.mint_locked_liquidity(LIMIT_TOTAL_SUPPLY);
    ledger.receive_idle(balance::create_for_testing<DUSDC>(LIMIT_WITHDRAW_IDLE));
    let lp = coin::mint_for_testing<LP_BOOK_TEST_SUPPORT>(LIMIT_WITHDRAW_AMOUNT, ctx);
    book.request_withdraw(
        lp,
        lp_book_test_support::account_id(),
        ALICE,
        LIMIT_WITHDRAW_MIN_OUT,
    );
    let attempts = constants::lp_request_limit_flush_attempts!();
    let mut count = ZERO_COUNT;
    while (count < attempts - RAW_UNIT) {
        let miss = book.drain(
            &mut ledger,
            lp_book::new_flush_mark(LIMIT_MISS_POOL_VALUE, LIMIT_TOTAL_SUPPLY),
            lp_book_test_support::vault_id(),
            option::none(),
            option::none(),
            ctx,
        );
        lp_book_test_support::assert_summary(&miss, ZERO_COUNT, ZERO_COUNT, ONE_COUNT);
        assert_eq!(book.withdraw_requests_pending(), ONE_COUNT);
        count = count + ONE_COUNT;
    };

    let expired = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(LIMIT_MISS_POOL_VALUE, LIMIT_TOTAL_SUPPLY),
        lp_book_test_support::vault_id(),
        option::none(),
        option::none(),
        ctx,
    );

    lp_book_test_support::assert_summary(&expired, ZERO_COUNT, ZERO_COUNT, ONE_COUNT);
    assert_eq!(attempts, THREE_COUNT);
    assert_eq!(book.withdraw_requests_pending(), ZERO_COUNT);
    assert_eq!(book.total_supply(), LIMIT_TOTAL_SUPPLY);
    assert_eq!(ledger.idle_balance(), LIMIT_WITHDRAW_IDLE);
    lp_book_test_support::assert_cancelled_event(
        ONE_COUNT,
        FIRST_INDEX,
        ALICE,
        FIRST_INDEX,
        LIMIT_WITHDRAW_AMOUNT,
        false,
        LIMIT_EXPIRED_REASON,
        ZERO_COUNT,
    );
    lp_book_test_support::assert_limit_missed_event(
        TWO_COUNT,
        FIRST_INDEX,
        ALICE,
        FIRST_INDEX,
        LIMIT_WITHDRAW_AMOUNT,
        false,
        LIMIT_WITHDRAW_MISS_QUOTE,
        LIMIT_WITHDRAW_MIN_OUT,
        ONE_COUNT,
        THREE_COUNT,
    );
    lp_book_test_support::assert_limit_missed_event(
        TWO_COUNT,
        SECOND_INDEX,
        ALICE,
        FIRST_INDEX,
        LIMIT_WITHDRAW_AMOUNT,
        false,
        LIMIT_WITHDRAW_MISS_QUOTE,
        LIMIT_WITHDRAW_MIN_OUT,
        TWO_COUNT,
        THREE_COUNT,
    );
    destroy(book);
    destroy(ledger);
}
