// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Local expiry-cash conservation and rebate-basis accounting.
#[test_only]
module deepbook_predict::scope_mechanics__intent_accounting__expiry_cash_tests;

use deepbook_predict::{expiry_cash, expiry_cash_config};
use dusdc::dusdc::DUSDC;
use std::unit_test::{assert_eq, destroy};
use sui::coin;

const HALF_RATE: u64 = 500_000_000;
const FULL_CASH: u64 = 100;
const FIRST_PAYMENT: u64 = 40;
const REMAINING_CASH: u64 = 60;
const SMALL_TRADE_FEE: u64 = 2;
const SMALL_LIABILITY: u64 = 5;
const SMALL_REQUIRED_CASH: u64 = 6;
const SMALL_FREE_CASH: u64 = 1;
const UNDERWATER_TRADE_FEE: u64 = 40;
const UNDERWATER_PAYMENT: u64 = 30;
const UNDERWATER_BALANCE: u64 = 10;
const UNDERWATER_RESERVE: u64 = 20;
const REBATE_ELIGIBLE_FEE: u64 = 10;
const NONREBATE_FEE: u64 = 5;
const PARTIAL_RESOLUTION_BASIS: u64 = 4;
const FINAL_RESOLUTION_BASIS: u64 = 6;
const ZERO_AMOUNT: u64 = 0;
const FINAL_REMAINING_RESERVE: u64 = 3;

#[test]
fun receive_and_authorized_pay_conserve_cash() {
    let ctx = &mut tx_context::dummy();
    let mut config = expiry_cash_config::new();
    config.set_trading_loss_rebate_rate(HALF_RATE);
    let mut cash = expiry_cash::new(config);
    assert_eq!(cash.balance(), ZERO_AMOUNT);
    assert_eq!(cash.trading_loss_rebate_rate(), HALF_RATE);

    cash.receive(coin::mint_for_testing<DUSDC>(FULL_CASH, ctx).into_balance());
    let zero = cash.pay_authorized(ZERO_AMOUNT);
    assert_eq!(zero.value(), ZERO_AMOUNT);
    let paid = cash.pay_authorized(FIRST_PAYMENT);
    assert_eq!(paid.value(), FIRST_PAYMENT);
    assert_eq!(cash.balance(), REMAINING_CASH);
    let remaining = cash.pay_authorized(REMAINING_CASH);
    assert_eq!(remaining.value(), REMAINING_CASH);
    assert_eq!(cash.balance(), ZERO_AMOUNT);
    destroy(zero);
    destroy(paid);
    destroy(remaining);
    destroy(cash);
}

#[test]
fun reserve_required_and_free_cash_use_floor_arithmetic() {
    let ctx = &mut tx_context::dummy();
    let mut config = expiry_cash_config::new();
    config.set_trading_loss_rebate_rate(HALF_RATE);
    let mut cash = expiry_cash::new(config);

    cash.collect_trade_fee(
        coin::mint_for_testing<DUSDC>(SMALL_TRADE_FEE, ctx).into_balance(),
        SMALL_TRADE_FEE,
    );
    assert_eq!(cash.rebate_reserve(), SMALL_FREE_CASH);
    assert_eq!(cash.required_cash(SMALL_LIABILITY), SMALL_REQUIRED_CASH);
    assert_eq!(cash.free_cash(), SMALL_FREE_CASH);
    destroy(cash);
}

#[test]
fun free_cash_saturates_below_the_reserve() {
    let ctx = &mut tx_context::dummy();
    let mut config = expiry_cash_config::new();
    config.set_trading_loss_rebate_rate(HALF_RATE);
    let mut cash = expiry_cash::new(config);
    cash.collect_trade_fee(
        coin::mint_for_testing<DUSDC>(UNDERWATER_TRADE_FEE, ctx).into_balance(),
        UNDERWATER_TRADE_FEE,
    );
    let drained = cash.pay_authorized(UNDERWATER_PAYMENT);
    assert_eq!(cash.balance(), UNDERWATER_BALANCE);
    assert_eq!(cash.rebate_reserve(), UNDERWATER_RESERVE);
    assert_eq!(cash.free_cash(), ZERO_AMOUNT);
    destroy(drained);
    destroy(cash);
}

#[test]
fun release_zero_and_exact_surplus_preserve_backing() {
    let ctx = &mut tx_context::dummy();
    let mut cash = expiry_cash::new(expiry_cash_config::new());
    cash.receive(coin::mint_for_testing<DUSDC>(FULL_CASH, ctx).into_balance());

    let zero = cash.release_surplus(ZERO_AMOUNT, REMAINING_CASH);
    assert_eq!(zero.value(), ZERO_AMOUNT);
    let released = cash.release_surplus(FIRST_PAYMENT, REMAINING_CASH);
    assert_eq!(released.value(), FIRST_PAYMENT);
    assert_eq!(cash.balance(), REMAINING_CASH);
    cash.assert_backing(REMAINING_CASH);
    destroy(zero);
    destroy(released);
    destroy(cash);
}

#[test]
fun rebate_basis_resolves_partially_then_fully() {
    let ctx = &mut tx_context::dummy();
    let mut config = expiry_cash_config::new();
    config.set_trading_loss_rebate_rate(HALF_RATE);
    let mut cash = expiry_cash::new(config);
    cash.collect_trade_fee(
        coin::mint_for_testing<DUSDC>(REBATE_ELIGIBLE_FEE, ctx).into_balance(),
        REBATE_ELIGIBLE_FEE,
    );
    cash.collect_trade_fee(
        coin::mint_for_testing<DUSDC>(NONREBATE_FEE, ctx).into_balance(),
        ZERO_AMOUNT,
    );

    assert_eq!(cash.rebate_reserve(), NONREBATE_FEE);
    assert_eq!(
        cash.resolve_rebate_reserve_for_fee_basis(PARTIAL_RESOLUTION_BASIS),
        SMALL_TRADE_FEE,
    );
    assert_eq!(cash.rebate_reserve(), FINAL_REMAINING_RESERVE);
    assert_eq!(
        cash.resolve_rebate_reserve_for_fee_basis(FINAL_RESOLUTION_BASIS),
        FINAL_REMAINING_RESERVE,
    );
    assert_eq!(cash.rebate_reserve(), ZERO_AMOUNT);
    destroy(cash);
}
