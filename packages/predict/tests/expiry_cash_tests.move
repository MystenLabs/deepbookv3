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
const SKEW_CHARGE: u64 = 20;
/// Cash left after paying out past the earmark (5 < escrow 20).
const CASH_BELOW_ESCROW: u64 = 5;

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
fun free_cash_nets_out_the_skew_escrow_and_floors_at_zero() {
    let ctx = &mut tx_context::dummy();
    let mut cash = expiry_cash::new();

    // Cash 40 with 20 earmarked leaves 20 free.
    cash.receive(coin::mint_for_testing<DUSDC>(FEE_AMOUNT, ctx).into_balance());
    cash.credit_inventory_reserve(SKEW_CHARGE);
    assert_eq!(cash.free_cash(), FEE_AMOUNT - SKEW_CHARGE);

    // Pay out past the earmark — 5 cash against a 20 escrow. Free cash floors at
    // zero instead of underflowing the subtraction.
    let drained = cash.pay_authorized(FEE_AMOUNT - CASH_BELOW_ESCROW);
    assert_eq!(cash.balance(), CASH_BELOW_ESCROW);
    assert_eq!(cash.free_cash(), 0);

    destroy(drained);
    destroy(cash);
}

#[test, expected_failure(abort_code = expiry_cash::EInventoryRebateExceedsReserve)]
fun skew_rebate_cannot_spend_ordinary_cash() {
    let ctx = &mut tx_context::dummy();
    let mut cash = expiry_cash::new();
    cash.receive(coin::mint_for_testing<DUSDC>(CASH_AMOUNT, ctx).into_balance());
    cash.credit_inventory_reserve(SKEW_CHARGE);

    let unexpected = cash.pay_inventory_rebate(SKEW_CHARGE + 1);
    destroy(unexpected);
    abort 999
}

/// The skew escrow folds into required cash and out of free cash.
#[test]
fun skew_reserve_folds_into_required_and_out_of_free_cash() {
    let ctx = &mut tx_context::dummy();
    let mut cash = expiry_cash::new();
    cash.receive(coin::mint_for_testing<DUSDC>(CASH_AMOUNT, ctx).into_balance());
    cash.credit_inventory_reserve(SKEW_CHARGE);

    // 1 liability + 20 skew = 21 required; 100 - 20 escrowed = 80 free.
    assert_eq!(cash.required_cash(1), 1 + SKEW_CHARGE);
    assert_eq!(cash.free_cash(), CASH_AMOUNT - SKEW_CHARGE);

    let rebate = cash.pay_inventory_rebate(SKEW_CHARGE);
    assert_eq!(rebate.value(), SKEW_CHARGE);
    assert_eq!(cash.inventory_reserve(), 0);
    destroy(rebate);
    destroy(cash);
}

#[test]
fun settlement_release_turns_residual_escrow_into_surplus() {
    let ctx = &mut tx_context::dummy();
    let mut cash = expiry_cash::new();
    cash.receive(coin::mint_for_testing<DUSDC>(SKEW_CHARGE, ctx).into_balance());
    cash.credit_inventory_reserve(SKEW_CHARGE);

    cash.release_inventory_reserve();

    assert_eq!(cash.inventory_reserve(), 0);
    assert_eq!(cash.free_cash(), SKEW_CHARGE);
    let released = cash.release_surplus(SKEW_CHARGE, 0);
    assert_eq!(released.value(), SKEW_CHARGE);
    destroy(released);
    destroy(cash);
}
