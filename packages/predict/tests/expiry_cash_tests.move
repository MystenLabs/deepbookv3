// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::expiry_cash_tests;

use deepbook_predict::expiry_cash;
use std::unit_test::{assert_eq, destroy};
use sui::coin;
use usdc::usdc::USDC;

const CASH_AMOUNT: u64 = 100;
const REQUIRED_PAYOUT_LIABILITY: u64 = 101;
const FEE_AMOUNT: u64 = 40;
const INVENTORY_IMPACT_CHARGE: u64 = 30;
const INVENTORY_IMPACT_REBATE: u64 = 12;

#[test, expected_failure(abort_code = expiry_cash::EInsufficientCash)]
fun assert_backing_underfunded_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut cash = expiry_cash::new();
    cash.receive(coin::mint_for_testing<USDC>(CASH_AMOUNT, ctx).into_balance());

    cash.chk_backing(REQUIRED_PAYOUT_LIABILITY);
    abort 999
}

#[test, expected_failure(abort_code = expiry_cash::EInsufficientCash)]
fun pay_authorized_underfunded_aborts() {
    let mut cash = expiry_cash::new();

    let payout = cash.pay_out(CASH_AMOUNT);
    destroy(payout);
    abort 999
}

#[test]
fun receive_and_pay_authorized_updates_balance() {
    let ctx = &mut tx_context::dummy();
    let mut cash = expiry_cash::new();
    cash.receive(coin::mint_for_testing<USDC>(CASH_AMOUNT, ctx).into_balance());

    let payout = cash.pay_out(FEE_AMOUNT);

    assert_eq!(payout.value(), FEE_AMOUNT);
    assert_eq!(cash.balance(), CASH_AMOUNT - FEE_AMOUNT);
    destroy(payout);
    destroy(cash);
}

#[test]
fun inventory_impact_reserve_tracks_charges_and_rebates() {
    let ctx = &mut tx_context::dummy();
    let mut cash = expiry_cash::new();

    // The charge has already arrived in custody when the market earmarks it.
    cash.receive(coin::mint_for_testing<USDC>(CASH_AMOUNT, ctx).into_balance());
    cash.add_impact(INVENTORY_IMPACT_CHARGE);

    assert_eq!(cash.inventory_impact_reserve(), INVENTORY_IMPACT_CHARGE);
    assert_eq!(cash.required_cash(REQUIRED_PAYOUT_LIABILITY), 131);

    let rebate = cash.pay_rebate(INVENTORY_IMPACT_REBATE);
    assert_eq!(rebate.value(), INVENTORY_IMPACT_REBATE);
    assert_eq!(cash.inventory_impact_reserve(), INVENTORY_IMPACT_CHARGE - INVENTORY_IMPACT_REBATE);
    assert_eq!(cash.balance(), CASH_AMOUNT - INVENTORY_IMPACT_REBATE);

    destroy(rebate);
    let remaining = cash.pay_out(CASH_AMOUNT - INVENTORY_IMPACT_REBATE);
    destroy(remaining);
    destroy(cash);
}

#[test, expected_failure(abort_code = expiry_cash::EInventoryImpactRebateExceedsReserve)]
fun inventory_impact_rebate_cannot_spend_ordinary_cash() {
    let ctx = &mut tx_context::dummy();
    let mut cash = expiry_cash::new();
    cash.receive(coin::mint_for_testing<USDC>(CASH_AMOUNT, ctx).into_balance());
    cash.add_impact(INVENTORY_IMPACT_CHARGE);

    let unexpected = cash.pay_rebate(INVENTORY_IMPACT_CHARGE + 1);
    destroy(unexpected);
    abort 999
}

#[test]
fun settlement_release_turns_residual_escrow_into_surplus() {
    let ctx = &mut tx_context::dummy();
    let mut cash = expiry_cash::new();
    cash.receive(coin::mint_for_testing<USDC>(INVENTORY_IMPACT_CHARGE, ctx).into_balance());
    cash.add_impact(INVENTORY_IMPACT_CHARGE);

    cash.free_imp();

    assert_eq!(cash.inventory_impact_reserve(), 0);
    assert_eq!(cash.balance(), INVENTORY_IMPACT_CHARGE);
    let released = cash.free_sur(INVENTORY_IMPACT_CHARGE, 0);
    assert_eq!(released.value(), INVENTORY_IMPACT_CHARGE);
    destroy(released);
    destroy(cash);
}
