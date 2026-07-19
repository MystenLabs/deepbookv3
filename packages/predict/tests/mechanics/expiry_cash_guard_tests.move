// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Reachable expiry-cash backing, payment, and rebate-basis guards.
#[test_only]
module deepbook_predict::scope_mechanics__intent_guard__expiry_cash_tests;

use deepbook_predict::{expiry_cash, expiry_cash_config};
use dusdc::dusdc::DUSDC;
use std::unit_test::destroy;
use sui::coin;

const CASH: u64 = 100;
const REQUIRED_BACKING: u64 = 2;
const TRADE_FEE: u64 = 10;
const ONE_ABOVE_TRADE_FEE: u64 = 11;
const RETAINED_BACKING: u64 = 60;
const ONE_ABOVE_SURPLUS: u64 = 41;
const ONE_ABOVE_CASH: u64 = 101;

#[test, expected_failure(abort_code = expiry_cash::EInsufficientCash)]
fun backing_one_below_required_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut cash = expiry_cash::new(expiry_cash_config::new());
    cash.collect_trade_fee(
        coin::mint_for_testing<DUSDC>(REQUIRED_BACKING, ctx).into_balance(),
        REQUIRED_BACKING,
    );
    cash.assert_backing(REQUIRED_BACKING);
    abort 999
}

#[test, expected_failure(abort_code = expiry_cash::EInsufficientCash)]
fun release_one_above_surplus_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut cash = expiry_cash::new(expiry_cash_config::new());
    cash.receive(coin::mint_for_testing<DUSDC>(CASH, ctx).into_balance());
    let released = cash.release_surplus(ONE_ABOVE_SURPLUS, RETAINED_BACKING);
    destroy(released);
    abort 999
}

#[test, expected_failure(abort_code = expiry_cash::EInsufficientCash)]
fun authorized_payment_one_above_cash_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut cash = expiry_cash::new(expiry_cash_config::new());
    cash.receive(coin::mint_for_testing<DUSDC>(CASH, ctx).into_balance());
    let paid = cash.pay_authorized(ONE_ABOVE_CASH);
    destroy(paid);
    abort 999
}

#[test, expected_failure(abort_code = expiry_cash::ERebateBasisExceedsFee)]
fun rebate_basis_one_above_fee_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut cash = expiry_cash::new(expiry_cash_config::new());
    cash.collect_trade_fee(
        coin::mint_for_testing<DUSDC>(TRADE_FEE, ctx).into_balance(),
        ONE_ABOVE_TRADE_FEE,
    );
    abort 999
}

#[test, expected_failure(abort_code = expiry_cash::EUnresolvedTradingFeesUnderflow)]
fun resolution_one_above_unresolved_basis_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut cash = expiry_cash::new(expiry_cash_config::new());
    cash.collect_trade_fee(
        coin::mint_for_testing<DUSDC>(TRADE_FEE, ctx).into_balance(),
        TRADE_FEE,
    );
    cash.resolve_rebate_reserve_for_fee_basis(ONE_ABOVE_TRADE_FEE);
    abort 999
}
