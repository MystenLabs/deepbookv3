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
const INVENTORY_IMPACT_CHARGE: u64 = 30;
const INVENTORY_IMPACT_REBATE: u64 = 12;
/// Cash left after paying out past the earmark (5 < escrow 30).
const CASH_BELOW_ESCROW: u64 = 5;
const SKEW_CHARGE: u64 = 25;

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
fun free_cash_nets_out_the_impact_escrow_and_floors_at_zero() {
    let ctx = &mut tx_context::dummy();
    let mut cash = expiry_cash::new();

    // Cash 40 with 30 earmarked leaves 10 free.
    cash.receive(coin::mint_for_testing<DUSDC>(FEE_AMOUNT, ctx).into_balance());
    cash.credit_inventory_impact_reserve(INVENTORY_IMPACT_CHARGE);
    assert_eq!(cash.free_cash(), FEE_AMOUNT - INVENTORY_IMPACT_CHARGE);

    // Pay out past the earmark — 5 cash against a 30 escrow. Free cash floors at
    // zero instead of underflowing the subtraction.
    let drained = cash.pay_authorized(FEE_AMOUNT - CASH_BELOW_ESCROW);
    assert_eq!(cash.balance(), CASH_BELOW_ESCROW);
    assert_eq!(cash.free_cash(), 0);

    destroy(drained);
    destroy(cash);
}

#[test]
fun inventory_impact_reserve_isolated_from_free_cash() {
    let ctx = &mut tx_context::dummy();
    let mut cash = expiry_cash::new();

    // The charge has already arrived in custody when the market earmarks it.
    cash.receive(coin::mint_for_testing<DUSDC>(CASH_AMOUNT, ctx).into_balance());
    cash.credit_inventory_impact_reserve(INVENTORY_IMPACT_CHARGE);

    assert_eq!(cash.inventory_impact_reserve(), INVENTORY_IMPACT_CHARGE);
    assert_eq!(cash.required_cash(REQUIRED_PAYOUT_LIABILITY), 131);
    assert_eq!(cash.free_cash(), CASH_AMOUNT - INVENTORY_IMPACT_CHARGE);

    let rebate = cash.pay_inventory_impact_rebate(INVENTORY_IMPACT_REBATE);
    assert_eq!(rebate.value(), INVENTORY_IMPACT_REBATE);
    assert_eq!(cash.inventory_impact_reserve(), INVENTORY_IMPACT_CHARGE - INVENTORY_IMPACT_REBATE);
    assert_eq!(cash.balance(), CASH_AMOUNT - INVENTORY_IMPACT_REBATE);
    assert_eq!(cash.free_cash(), CASH_AMOUNT - INVENTORY_IMPACT_CHARGE);

    destroy(rebate);
    let remaining = cash.pay_authorized(CASH_AMOUNT - INVENTORY_IMPACT_REBATE);
    destroy(remaining);
    destroy(cash);
}

#[test, expected_failure(abort_code = expiry_cash::EInventoryImpactRebateExceedsReserve)]
fun inventory_impact_rebate_cannot_spend_ordinary_cash() {
    let ctx = &mut tx_context::dummy();
    let mut cash = expiry_cash::new();
    cash.receive(coin::mint_for_testing<DUSDC>(CASH_AMOUNT, ctx).into_balance());
    cash.credit_inventory_impact_reserve(INVENTORY_IMPACT_CHARGE);

    let unexpected = cash.pay_inventory_impact_rebate(INVENTORY_IMPACT_CHARGE + 1);
    destroy(unexpected);
    abort 999
}

#[test]
fun settlement_release_turns_residual_escrow_into_surplus() {
    let ctx = &mut tx_context::dummy();
    let mut cash = expiry_cash::new();
    cash.receive(coin::mint_for_testing<DUSDC>(INVENTORY_IMPACT_CHARGE, ctx).into_balance());
    cash.credit_inventory_impact_reserve(INVENTORY_IMPACT_CHARGE);

    cash.release_inventory_impact_reserve();

    assert_eq!(cash.inventory_impact_reserve(), 0);
    assert_eq!(cash.free_cash(), INVENTORY_IMPACT_CHARGE);
    let released = cash.release_surplus(INVENTORY_IMPACT_CHARGE, 0);
    assert_eq!(released.value(), INVENTORY_IMPACT_CHARGE);
    destroy(released);
    destroy(cash);
}

#[test]
fun skew_escrow_is_isolated_from_free_cash_and_required_cash() {
    let ctx = &mut tx_context::dummy();
    let mut cash = expiry_cash::new();
    cash.receive(coin::mint_for_testing<DUSDC>(CASH_AMOUNT, ctx).into_balance());
    cash.credit_skew_reserve(SKEW_CHARGE);

    // Neither spendable nor visible in NAV while the market is live.
    assert_eq!(cash.skew_reserve(), SKEW_CHARGE);
    assert_eq!(cash.free_cash(), CASH_AMOUNT - SKEW_CHARGE);
    assert_eq!(cash.required_cash(FEE_AMOUNT), FEE_AMOUNT + SKEW_CHARGE);

    // Both escrows net out together.
    cash.credit_inventory_impact_reserve(INVENTORY_IMPACT_CHARGE);
    assert_eq!(cash.free_cash(), CASH_AMOUNT - SKEW_CHARGE - INVENTORY_IMPACT_CHARGE);
    assert_eq!(cash.required_cash(FEE_AMOUNT), FEE_AMOUNT + SKEW_CHARGE + INVENTORY_IMPACT_CHARGE);

    destroy(cash);
}

#[test]
fun skew_rebate_draws_only_on_its_own_escrow() {
    let ctx = &mut tx_context::dummy();
    let mut cash = expiry_cash::new();
    cash.receive(coin::mint_for_testing<DUSDC>(CASH_AMOUNT, ctx).into_balance());
    cash.credit_skew_reserve(SKEW_CHARGE);

    let paid = cash.pay_skew_rebate(SKEW_CHARGE);
    assert_eq!(paid.value(), SKEW_CHARGE);
    assert_eq!(cash.skew_reserve(), 0);
    assert_eq!(cash.balance(), CASH_AMOUNT - SKEW_CHARGE);

    destroy(paid);
    destroy(cash);
}

#[test, expected_failure(abort_code = expiry_cash::ESkewRebateExceedsReserve)]
fun skew_rebate_above_the_escrow_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut cash = expiry_cash::new();
    cash.receive(coin::mint_for_testing<DUSDC>(CASH_AMOUNT, ctx).into_balance());
    cash.credit_skew_reserve(SKEW_CHARGE);

    let payout = cash.pay_skew_rebate(SKEW_CHARGE + 1);
    destroy(payout);
    abort 999
}

/// Settlement turns the residual escrow into ordinary surplus without moving cash.
#[test]
fun settlement_release_frees_the_skew_escrow() {
    let ctx = &mut tx_context::dummy();
    let mut cash = expiry_cash::new();
    cash.receive(coin::mint_for_testing<DUSDC>(CASH_AMOUNT, ctx).into_balance());
    cash.credit_skew_reserve(SKEW_CHARGE);
    assert_eq!(cash.free_cash(), CASH_AMOUNT - SKEW_CHARGE);

    cash.release_skew_reserve();
    assert_eq!(cash.skew_reserve(), 0);
    assert_eq!(cash.balance(), CASH_AMOUNT);
    assert_eq!(cash.free_cash(), CASH_AMOUNT);

    destroy(cash);
}
