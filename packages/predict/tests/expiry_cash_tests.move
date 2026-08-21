// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::expiry_cash_tests;

use deepbook_predict::expiry_cash;
use dusdc::dusdc::DUSDC;
use std::unit_test::{assert_eq, destroy};
use sui::coin;

const CASH_AMOUNT: u64 = 100;
const REQUIRED_PAYOUT_LIABILITY: u64 = 101;
const FEE_AMOUNT: u64 = 40;
/// Payout liability leaving exactly `FEE_AMOUNT` of `CASH_AMOUNT` releasable.
const BACKED_LIABILITY: u64 = 60;

#[test, expected_failure(abort_code = expiry_cash::EInsufficientCash)]
fun assert_backing_underfunded_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut cash = expiry_cash::new();
    cash.receive(coin::mint_for_testing<DUSDC>(CASH_AMOUNT, ctx).into_balance());

    cash.assert_backing(REQUIRED_PAYOUT_LIABILITY);
    abort 999
}

#[test, expected_failure(abort_code = expiry_cash::EInsufficientCash)]
fun pay_authorized_underfunded_aborts() {
    let mut cash = expiry_cash::new();

    let payout = cash.pay_authorized(CASH_AMOUNT);
    destroy(payout);
    abort 999
}

#[test]
fun receive_and_pay_authorized_updates_balance() {
    let ctx = &mut tx_context::dummy();
    let mut cash = expiry_cash::new();
    cash.receive(coin::mint_for_testing<DUSDC>(CASH_AMOUNT, ctx).into_balance());

    let payout = cash.pay_authorized(FEE_AMOUNT);

    assert_eq!(payout.value(), FEE_AMOUNT);
    assert_eq!(cash.balance(), CASH_AMOUNT - FEE_AMOUNT);
    destroy(payout);
    destroy(cash);
}

#[test]
fun release_surplus_pays_only_cash_above_payout_backing() {
    let ctx = &mut tx_context::dummy();
    let mut cash = expiry_cash::new();
    cash.receive(coin::mint_for_testing<DUSDC>(CASH_AMOUNT, ctx).into_balance());

    // 100 cash against a 60 liability leaves exactly 40 releasable.
    let released = cash.release_surplus(FEE_AMOUNT, BACKED_LIABILITY);

    assert_eq!(released.value(), FEE_AMOUNT);
    assert_eq!(cash.balance(), BACKED_LIABILITY);
    destroy(released);
    destroy(cash);
}

#[test, expected_failure(abort_code = expiry_cash::EInsufficientCash)]
fun release_surplus_that_breaks_payout_backing_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut cash = expiry_cash::new();
    cash.receive(coin::mint_for_testing<DUSDC>(CASH_AMOUNT, ctx).into_balance());

    let released = cash.release_surplus(FEE_AMOUNT + 1, BACKED_LIABILITY);
    destroy(released);
    abort 999
}
