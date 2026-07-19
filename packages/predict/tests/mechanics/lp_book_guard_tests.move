// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Request minimum, lookup, and recipient-ownership guards.
#[test_only]
module deepbook_predict::scope_mechanics__intent_guard__lp_book_tests;

use deepbook_predict::{constants, lp_book, lp_book_test_support::{Self, LP_BOOK_TEST_SUPPORT}};
use dusdc::dusdc::DUSDC;
use std::unit_test::destroy;
use sui::coin;

const ALICE: address = @0xA;
const BOB: address = @0xB0B;
const NO_MIN_OUTPUT: u64 = 0;
const UNKNOWN_INDEX: u64 = 0;
const RAW_UNIT: u64 = 1;

#[test, expected_failure(abort_code = lp_book::EBelowMinSupplyRequest)]
fun supply_request_one_below_minimum_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut book, ledger) = lp_book_test_support::new_book_and_ledger(ctx);
    let payment = coin::mint_for_testing<DUSDC>(
        constants::min_supply_request!() - RAW_UNIT,
        ctx,
    );
    book.request_supply(
        payment,
        lp_book_test_support::account_id(),
        ALICE,
        NO_MIN_OUTPUT,
    );
    destroy(book);
    destroy(ledger);
    abort 999
}

#[test, expected_failure(abort_code = lp_book::EBelowMinWithdrawRequest)]
fun withdraw_request_one_below_minimum_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut book, ledger) = lp_book_test_support::new_book_and_ledger(ctx);
    let lp = coin::mint_for_testing<LP_BOOK_TEST_SUPPORT>(
        constants::min_withdraw_request!() - RAW_UNIT,
        ctx,
    );
    book.request_withdraw(
        lp,
        lp_book_test_support::account_id(),
        ALICE,
        NO_MIN_OUTPUT,
    );
    destroy(book);
    destroy(ledger);
    abort 999
}

#[test, expected_failure(abort_code = lp_book::ERequestNotFound)]
fun cancelling_unknown_supply_index_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut book, ledger) = lp_book_test_support::new_book_and_ledger(ctx);
    let (_, _, refund) = book.cancel_supply_request(ALICE, UNKNOWN_INDEX);
    destroy(refund);
    destroy(book);
    destroy(ledger);
    abort 999
}

#[test, expected_failure(abort_code = lp_book::ENotRequestOwner)]
fun non_recipient_cannot_cancel_supply() {
    let ctx = &mut tx_context::dummy();
    let (mut book, ledger) = lp_book_test_support::new_book_and_ledger(ctx);
    let payment = coin::mint_for_testing<DUSDC>(constants::min_supply_request!(), ctx);
    let index = book.request_supply(
        payment,
        lp_book_test_support::account_id(),
        ALICE,
        NO_MIN_OUTPUT,
    );
    let (_, _, refund) = book.cancel_supply_request(BOB, index);
    destroy(refund);
    destroy(book);
    destroy(ledger);
    abort 999
}
