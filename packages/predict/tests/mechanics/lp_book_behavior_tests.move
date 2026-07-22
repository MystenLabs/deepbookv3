// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Permanent supply, queue indexing, and owner-cancel refund behavior.
#[test_only]
module deepbook_predict::scope_mechanics__intent_behavior__lp_book_tests;

use deepbook_predict::{constants, lp_book_test_support::{Self, LP_BOOK_TEST_SUPPORT}};
use dusdc::dusdc::DUSDC;
use std::unit_test::{assert_eq, destroy};
use sui::coin;

const ALICE: address = @0xA;
const NO_MIN_OUTPUT: u64 = 0;
const FIRST_INDEX: u64 = 0;
const SECOND_INDEX: u64 = 1;
const ZERO_PENDING: u64 = 0;
const ONE_PENDING: u64 = 1;

#[test]
fun locked_liquidity_increments_total_supply_exactly() {
    let ctx = &mut tx_context::dummy();
    let (mut book, ledger) = lp_book_test_support::new_book_and_ledger(ctx);

    book.mint_locked_liquidity(constants::min_supply_request!());

    assert_eq!(book.total_supply(), constants::min_supply_request!());
    assert_eq!(book.supply_requests_pending(), ZERO_PENDING);
    assert_eq!(book.withdraw_requests_pending(), ZERO_PENDING);
    destroy(book);
    destroy(ledger);
}

#[test]
fun supply_cancel_returns_full_escrow_and_indices_never_reuse() {
    let ctx = &mut tx_context::dummy();
    let (mut book, ledger) = lp_book_test_support::new_book_and_ledger(ctx);
    let first_payment = coin::mint_for_testing<DUSDC>(constants::min_supply_request!(), ctx);
    let first = book.request_supply(
        first_payment,
        lp_book_test_support::account_id(),
        ALICE,
        NO_MIN_OUTPUT,
    );
    assert_eq!(first, FIRST_INDEX);
    let (account_id, amount, refund) = book.cancel_supply_request(ALICE, first);
    assert_eq!(account_id, lp_book_test_support::account_id());
    assert_eq!(amount, constants::min_supply_request!());
    assert_eq!(refund.value(), constants::min_supply_request!());
    assert_eq!(book.supply_requests_pending(), ZERO_PENDING);

    let second_payment = coin::mint_for_testing<DUSDC>(constants::min_supply_request!(), ctx);
    let second = book.request_supply(
        second_payment,
        lp_book_test_support::account_id(),
        ALICE,
        NO_MIN_OUTPUT,
    );
    assert_eq!(second, SECOND_INDEX);
    assert_eq!(book.supply_requests_pending(), ONE_PENDING);
    let (_, _, second_refund) = book.cancel_supply_request(ALICE, second);
    destroy(refund);
    destroy(second_refund);
    destroy(book);
    destroy(ledger);
}

#[test]
fun withdraw_cancel_returns_full_lp_escrow() {
    let ctx = &mut tx_context::dummy();
    let (mut book, ledger) = lp_book_test_support::new_book_and_ledger(ctx);
    let lp = coin::mint_for_testing<LP_BOOK_TEST_SUPPORT>(
        constants::min_withdraw_request!(),
        ctx,
    );
    let index = book.request_withdraw(
        lp,
        lp_book_test_support::account_id(),
        ALICE,
        NO_MIN_OUTPUT,
    );

    let (account_id, amount, refund) = book.cancel_withdraw_request(ALICE, index);

    assert_eq!(index, FIRST_INDEX);
    assert_eq!(account_id, lp_book_test_support::account_id());
    assert_eq!(amount, constants::min_withdraw_request!());
    assert_eq!(refund.value(), constants::min_withdraw_request!());
    assert_eq!(book.withdraw_requests_pending(), ZERO_PENDING);
    destroy(refund);
    destroy(book);
    destroy(ledger);
}
