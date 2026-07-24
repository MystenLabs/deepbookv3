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
const NON_REBATE_FEE_AMOUNT: u64 = 10;
const TOTAL_FEE_AMOUNT: u64 = 50;
const EXPECTED_REBATE_RESERVE: u64 = 20;
const CASH_AT_REBATE_RESERVE: u64 = 20;
const CASH_BELOW_REBATE_RESERVE: u64 = 19;
const EXTRA_SURPLUS_CASH: u64 = 60;
const SURPLUS_PAYOUT_LIABILITY: u64 = 30;
const EXACT_SURPLUS_AMOUNT: u64 = 50;
const EXPECTED_REQUIRED_CASH: u64 = 50;

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

    cash.collect_trade_fee(
        coin::mint_for_testing<DUSDC>(
            FEE_AMOUNT,
            ctx,
        ).into_balance(),
        FEE_AMOUNT,
    );

    assert_eq!(cash.balance(), FEE_AMOUNT);
    assert_eq!(cash.rebate_reserve(), EXPECTED_REBATE_RESERVE);
    let remaining_cash = cash.pay_authorized(FEE_AMOUNT);
    assert_eq!(remaining_cash.value(), FEE_AMOUNT);

    destroy(remaining_cash);
    destroy(cash);
}

#[test]
fun free_cash_nets_out_rebate_reserve() {
    let ctx = &mut tx_context::dummy();
    let mut config = expiry_cash_config::new();
    config.set_trading_loss_rebate_rate(REBATE_RATE); // 0.5
    let mut cash = expiry_cash::new(config);

    // Collect a fee: cash = 40, rebate_reserve = floor(40 * 0.5) = 20.
    cash.collect_trade_fee(
        coin::mint_for_testing<DUSDC>(
            FEE_AMOUNT,
            ctx,
        ).into_balance(),
        FEE_AMOUNT,
    );
    assert_eq!(cash.free_cash(), FEE_AMOUNT - EXPECTED_REBATE_RESERVE); // 40 - 20 = 20

    destroy(cash);
}

#[test]
fun free_cash_at_rebate_reserve_is_zero() {
    let ctx = &mut tx_context::dummy();
    let mut config = expiry_cash_config::new();
    config.set_trading_loss_rebate_rate(REBATE_RATE);
    let mut cash = expiry_cash::new(config);
    cash.collect_trade_fee(
        coin::mint_for_testing<DUSDC>(
            FEE_AMOUNT,
            ctx,
        ).into_balance(),
        FEE_AMOUNT,
    );

    let drained = cash.pay_authorized(CASH_AT_REBATE_RESERVE);
    assert_eq!(cash.balance(), CASH_AT_REBATE_RESERVE);
    assert_eq!(cash.rebate_reserve(), EXPECTED_REBATE_RESERVE);
    assert_eq!(cash.free_cash(), 0);

    destroy(drained);
    destroy(cash);
}

#[test, expected_failure(arithmetic_error, location = expiry_cash)]
fun free_cash_below_rebate_reserve_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut config = expiry_cash_config::new();
    config.set_trading_loss_rebate_rate(REBATE_RATE);
    let mut cash = expiry_cash::new(config);
    cash.collect_trade_fee(
        coin::mint_for_testing<DUSDC>(
            FEE_AMOUNT,
            ctx,
        ).into_balance(),
        FEE_AMOUNT,
    );

    let drained = cash.pay_authorized(FEE_AMOUNT - CASH_BELOW_REBATE_RESERVE);
    assert_eq!(cash.balance(), CASH_BELOW_REBATE_RESERVE);
    assert_eq!(cash.rebate_reserve(), EXPECTED_REBATE_RESERVE);
    cash.free_cash();

    destroy(drained);
    destroy(cash);
}

#[test]
fun release_exact_surplus_preserves_payout_and_rebate_backing() {
    let ctx = &mut tx_context::dummy();
    let mut config = expiry_cash_config::new();
    config.set_trading_loss_rebate_rate(REBATE_RATE);
    let mut cash = expiry_cash::new(config);
    cash.collect_trade_fee(
        coin::mint_for_testing<DUSDC>(
            FEE_AMOUNT,
            ctx,
        ).into_balance(),
        FEE_AMOUNT,
    );
    cash.receive(coin::mint_for_testing<DUSDC>(EXTRA_SURPLUS_CASH, ctx).into_balance());

    let released = cash.release_surplus(EXACT_SURPLUS_AMOUNT, SURPLUS_PAYOUT_LIABILITY);

    assert_eq!(released.value(), EXACT_SURPLUS_AMOUNT);
    assert_eq!(cash.balance(), EXPECTED_REQUIRED_CASH);
    assert_eq!(cash.required_cash(SURPLUS_PAYOUT_LIABILITY), EXPECTED_REQUIRED_CASH);
    assert_eq!(cash.rebate_reserve(), EXPECTED_REBATE_RESERVE);

    destroy(released);
    destroy(cash);
}

#[test]
fun release_all_surplus_leaves_exact_required_cash() {
    let ctx = &mut tx_context::dummy();
    let mut config = expiry_cash_config::new();
    config.set_trading_loss_rebate_rate(REBATE_RATE);
    let mut cash = expiry_cash::new(config);
    cash.collect_trade_fee(
        coin::mint_for_testing<DUSDC>(
            FEE_AMOUNT,
            ctx,
        ).into_balance(),
        FEE_AMOUNT,
    );
    cash.receive(coin::mint_for_testing<DUSDC>(EXTRA_SURPLUS_CASH, ctx).into_balance());

    let released = cash.release_all_surplus(SURPLUS_PAYOUT_LIABILITY);

    assert_eq!(released.value(), EXACT_SURPLUS_AMOUNT);
    assert_eq!(cash.balance(), EXPECTED_REQUIRED_CASH);
    assert_eq!(cash.required_cash(SURPLUS_PAYOUT_LIABILITY), EXPECTED_REQUIRED_CASH);

    destroy(released);
    destroy(cash);
}

#[test]
fun release_all_surplus_at_exact_backing_returns_zero() {
    let ctx = &mut tx_context::dummy();
    let mut config = expiry_cash_config::new();
    config.set_trading_loss_rebate_rate(REBATE_RATE);
    let mut cash = expiry_cash::new(config);
    cash.collect_trade_fee(
        coin::mint_for_testing<DUSDC>(
            FEE_AMOUNT,
            ctx,
        ).into_balance(),
        FEE_AMOUNT,
    );
    let released = cash.release_all_surplus(EXPECTED_REBATE_RESERVE);

    assert_eq!(released.value(), 0);
    assert_eq!(cash.balance(), FEE_AMOUNT);

    destroy(released);
    destroy(cash);
}

#[test, expected_failure(abort_code = expiry_cash::EInsufficientCash)]
fun release_all_surplus_underfunded_aborts() {
    let ctx = &mut tx_context::dummy();
    let config = expiry_cash_config::new();
    let mut cash = expiry_cash::new(config);
    cash.receive(coin::mint_for_testing<DUSDC>(CASH_AMOUNT, ctx).into_balance());

    let released = cash.release_all_surplus(REQUIRED_PAYOUT_LIABILITY);
    destroy(released);
    abort 999
}

#[test]
fun collect_trade_fee_tracks_rebate_basis_separately_from_cash() {
    let ctx = &mut tx_context::dummy();
    let mut config = expiry_cash_config::new();
    config.set_trading_loss_rebate_rate(REBATE_RATE);
    let mut cash = expiry_cash::new(config);

    cash.collect_trade_fee(
        coin::mint_for_testing<DUSDC>(
            TOTAL_FEE_AMOUNT,
            ctx,
        ).into_balance(),
        FEE_AMOUNT,
    );

    assert_eq!(cash.balance(), TOTAL_FEE_AMOUNT);
    assert_eq!(cash.rebate_reserve(), EXPECTED_REBATE_RESERVE);
    assert_eq!(cash.resolve_rebate_reserve_for_fee_basis(FEE_AMOUNT), EXPECTED_REBATE_RESERVE);
    assert_eq!(cash.rebate_reserve(), 0);

    let remaining_cash = cash.pay_authorized(TOTAL_FEE_AMOUNT);
    assert_eq!(remaining_cash.value(), TOTAL_FEE_AMOUNT);

    destroy(remaining_cash);
    destroy(cash);
}

#[test, expected_failure(abort_code = expiry_cash::ERebateBasisExceedsFee)]
fun collect_trade_fee_rebate_basis_above_fee_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut config = expiry_cash_config::new();
    config.set_trading_loss_rebate_rate(REBATE_RATE);
    let mut cash = expiry_cash::new(config);

    cash.collect_trade_fee(
        coin::mint_for_testing<DUSDC>(
            FEE_AMOUNT,
            ctx,
        ).into_balance(),
        FEE_AMOUNT + NON_REBATE_FEE_AMOUNT,
    );
    abort 999
}

#[test, expected_failure(abort_code = expiry_cash::EUnresolvedTradingFeesUnderflow)]
fun resolve_rebate_reserve_above_unresolved_basis_aborts() {
    let mut config = expiry_cash_config::new();
    config.set_trading_loss_rebate_rate(REBATE_RATE);
    let mut cash = expiry_cash::new(config);

    cash.resolve_rebate_reserve_for_fee_basis(FEE_AMOUNT);
    abort 999
}
