// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Observable page-link boundaries of the FIFO request queue.
#[test_only]
module deepbook_predict::scope_mechanics__intent_boundary__lp_book_tests;

use deepbook_predict::{constants, lp_book, lp_book_test_support};
use dusdc::dusdc::DUSDC;
use std::unit_test::{assert_eq, destroy};
use sui::coin;

const ALICE: address = @0xA;
const NO_MIN_OUTPUT: u64 = 0;
const ZERO_COUNT: u64 = 0;
const ONE_COUNT: u64 = 1;
const PAGE_CAPACITY: u64 = 64;
const TWO_PAGES_PLUS_ONE: u64 = 129;
const SECOND_PAGE_START: u64 = 64;
const SECOND_PAGE_END_EXCLUSIVE: u64 = 128;
const LAST_INDEX: u64 = 128;

#[test]
fun cancelling_lone_tail_page_entry_keeps_head_page_drainable() {
    let ctx = &mut tx_context::dummy();
    let (mut book, mut ledger) = lp_book_test_support::new_book_and_ledger(ctx);
    book.mint_locked_liquidity(constants::min_supply_request!());
    let total = PAGE_CAPACITY + ONE_COUNT;
    let mut count = ZERO_COUNT;
    let mut tail_index = ZERO_COUNT;
    while (count < total) {
        let payment = coin::mint_for_testing<DUSDC>(constants::min_supply_request!(), ctx);
        tail_index =
            book.request_supply(
                payment,
                lp_book_test_support::account_id(),
                ALICE,
                NO_MIN_OUTPUT,
            );
        count = count + ONE_COUNT;
    };
    let (_, _, refund) = book.cancel_supply_request(ALICE, tail_index);
    destroy(refund);
    assert_eq!(book.supply_requests_pending(), PAGE_CAPACITY);

    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(
            constants::min_supply_request!(),
            constants::min_supply_request!(),
        ),
        lp_book_test_support::vault_id(),
        option::none(),
        option::none(),
        ctx,
    );

    lp_book_test_support::assert_summary(&summary, PAGE_CAPACITY, ZERO_COUNT, PAGE_CAPACITY);
    assert_eq!(book.supply_requests_pending(), ZERO_COUNT);
    destroy(book);
    destroy(ledger);
}

#[test]
fun empty_middle_page_relinks_predecessor_to_successor_for_forward_drain() {
    let ctx = &mut tx_context::dummy();
    let (mut book, mut ledger) = lp_book_test_support::new_book_and_ledger(ctx);
    book.mint_locked_liquidity(constants::min_supply_request!());
    let mut count = ZERO_COUNT;
    while (count < TWO_PAGES_PLUS_ONE) {
        let payment = coin::mint_for_testing<DUSDC>(constants::min_supply_request!(), ctx);
        book.request_supply(
            payment,
            lp_book_test_support::account_id(),
            ALICE,
            NO_MIN_OUTPUT,
        );
        count = count + ONE_COUNT;
    };
    let mut index = SECOND_PAGE_START;
    while (index < SECOND_PAGE_END_EXCLUSIVE) {
        let (_, _, refund) = book.cancel_supply_request(ALICE, index);
        destroy(refund);
        index = index + ONE_COUNT;
    };
    assert_eq!(book.supply_requests_pending(), PAGE_CAPACITY + ONE_COUNT);

    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(
            constants::min_supply_request!(),
            constants::min_supply_request!(),
        ),
        lp_book_test_support::vault_id(),
        option::none(),
        option::none(),
        ctx,
    );

    lp_book_test_support::assert_summary(
        &summary,
        PAGE_CAPACITY + ONE_COUNT,
        ZERO_COUNT,
        PAGE_CAPACITY + ONE_COUNT,
    );
    assert_eq!(book.supply_requests_pending(), ZERO_COUNT);
    destroy(book);
    destroy(ledger);
}

#[test]
fun empty_middle_page_relinks_successor_back_to_predecessor() {
    let ctx = &mut tx_context::dummy();
    let (mut book, mut ledger) = lp_book_test_support::new_book_and_ledger(ctx);
    book.mint_locked_liquidity(constants::min_supply_request!());
    let mut count = ZERO_COUNT;
    while (count < TWO_PAGES_PLUS_ONE) {
        let payment = coin::mint_for_testing<DUSDC>(constants::min_supply_request!(), ctx);
        book.request_supply(
            payment,
            lp_book_test_support::account_id(),
            ALICE,
            NO_MIN_OUTPUT,
        );
        count = count + ONE_COUNT;
    };
    let mut index = SECOND_PAGE_START;
    while (index < SECOND_PAGE_END_EXCLUSIVE) {
        let (_, _, refund) = book.cancel_supply_request(ALICE, index);
        destroy(refund);
        index = index + ONE_COUNT;
    };
    let (_, _, tail_refund) = book.cancel_supply_request(ALICE, LAST_INDEX);
    destroy(tail_refund);
    assert_eq!(book.supply_requests_pending(), PAGE_CAPACITY);

    let summary = book.drain(
        &mut ledger,
        lp_book::new_flush_mark(
            constants::min_supply_request!(),
            constants::min_supply_request!(),
        ),
        lp_book_test_support::vault_id(),
        option::none(),
        option::none(),
        ctx,
    );

    lp_book_test_support::assert_summary(&summary, PAGE_CAPACITY, ZERO_COUNT, PAGE_CAPACITY);
    assert_eq!(book.supply_requests_pending(), ZERO_COUNT);
    destroy(book);
    destroy(ledger);
}
