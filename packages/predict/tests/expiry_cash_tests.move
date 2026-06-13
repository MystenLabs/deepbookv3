// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::expiry_cash_tests;

use deepbook_predict::{expiry_cash, expiry_cash_config};
use dusdc::dusdc::DUSDC;
use std::unit_test::{assert_eq, destroy};
use sui::coin;

const REBATE_RATE: u64 = 500_000_000;
const CASH_AMOUNT: u64 = 100;
const REQUIRED_PAYOUT_LIABILITY: u64 = 101;
const FEE_AMOUNT: u64 = 40;
const EXPECTED_REBATE_RESERVE: u64 = 20;

#[test, expected_failure(abort_code = expiry_cash::EInsufficientCash)]
fun assert_backing_underfunded_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut config = expiry_cash_config::new();
    config.set_trading_loss_rebate_rate(REBATE_RATE);
    let mut cash = expiry_cash::new(config);
    cash.receive(coin::mint_for_testing<DUSDC>(CASH_AMOUNT, ctx).into_balance());

    cash.assert_backing(REQUIRED_PAYOUT_LIABILITY);
    abort 999
}

#[test, expected_failure(abort_code = expiry_cash::EInsufficientCash)]
fun pay_authorized_underfunded_aborts() {
    let mut config = expiry_cash_config::new();
    config.set_trading_loss_rebate_rate(REBATE_RATE);
    let mut cash = expiry_cash::new(config);

    let payout = cash.pay_authorized(CASH_AMOUNT);
    destroy(payout);
    abort 999
}

#[test]
fun receive_and_pay_authorized_updates_balance() {
    let ctx = &mut tx_context::dummy();
    let mut config = expiry_cash_config::new();
    config.set_trading_loss_rebate_rate(REBATE_RATE);
    let mut cash = expiry_cash::new(config);
    cash.receive(coin::mint_for_testing<DUSDC>(CASH_AMOUNT, ctx).into_balance());

    let payout = cash.pay_authorized(FEE_AMOUNT);

    assert_eq!(payout.value(), FEE_AMOUNT);
    assert_eq!(cash.balance(), CASH_AMOUNT - FEE_AMOUNT);
    destroy(payout);
    destroy(cash);
}

#[test]
fun collecting_trade_fee_increases_cash_and_rebate_reserve() {
    let ctx = &mut tx_context::dummy();
    let mut config = expiry_cash_config::new();
    config.set_trading_loss_rebate_rate(REBATE_RATE);
    let mut cash = expiry_cash::new(config);

    let collected = cash.collect_trade_fee(coin::mint_for_testing<DUSDC>(
        FEE_AMOUNT,
        ctx,
    ).into_balance());

    assert_eq!(collected, FEE_AMOUNT);
    assert_eq!(cash.balance(), FEE_AMOUNT);
    assert_eq!(cash.rebate_reserve(), EXPECTED_REBATE_RESERVE);
    let remaining_cash = cash.pay_authorized(FEE_AMOUNT);
    assert_eq!(remaining_cash.value(), FEE_AMOUNT);

    destroy(remaining_cash);
    destroy(cash);
}
