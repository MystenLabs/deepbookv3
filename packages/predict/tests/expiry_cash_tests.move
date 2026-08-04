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
/// Cash left after draining below the rebate reserve (10 < reserve 20).
const CASH_BELOW_RESERVE: u64 = 10;
/// A collected inventory-skew charge. Unlike the rebate reserve this is a direct
/// dollar total, so the escrow equals the credited amount at any rebate rate.
const SKEW_CHARGE: u64 = 30;
const PARTIAL_SKEW_REBATE: u64 = 12;

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
fun free_cash_nets_out_rebate_reserve_and_floors_at_zero() {
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

    // Drain cash below the reserve (pay 30 -> cash 10, reserve still 20): free cash
    // floors at zero rather than underflowing.
    let drained = cash.pay_authorized(FEE_AMOUNT - CASH_BELOW_RESERVE);
    assert_eq!(cash.balance(), CASH_BELOW_RESERVE);
    assert_eq!(cash.rebate_reserve(), EXPECTED_REBATE_RESERVE);
    assert_eq!(cash.free_cash(), 0);

    destroy(drained);
    destroy(cash);
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

// === Inventory-skew escrow ===

#[test]
fun skew_reserve_is_withheld_from_free_cash_and_added_to_required_cash() {
    let ctx = &mut tx_context::dummy();
    let mut config = expiry_cash_config::new();
    config.set_trading_loss_rebate_rate(REBATE_RATE);
    let mut cash = expiry_cash::new(config);

    // A mint pays 100 in and 30 of it was the skew charge. Cash rises by the whole
    // payment; only the charge is reserved, so LP-visible free cash rises by 70.
    cash.receive(coin::mint_for_testing<DUSDC>(CASH_AMOUNT, ctx).into_balance());
    cash.credit_skew_reserve(SKEW_CHARGE);

    assert_eq!(cash.balance(), CASH_AMOUNT); // 100
    assert_eq!(cash.skew_reserve(), SKEW_CHARGE); // 30
    assert_eq!(cash.free_cash(), CASH_AMOUNT - SKEW_CHARGE); // 100 - 30 = 70
    // No fee was collected, so the rebate reserve is 0 and required cash is the
    // payout liability plus the skew escrow alone.
    assert_eq!(cash.required_cash(FEE_AMOUNT), FEE_AMOUNT + SKEW_CHARGE); // 40 + 30 = 70

    destroy(cash);
}

#[test]
fun skew_reserve_stacks_with_the_rebate_reserve() {
    let ctx = &mut tx_context::dummy();
    let mut config = expiry_cash_config::new();
    config.set_trading_loss_rebate_rate(REBATE_RATE); // 0.5
    let mut cash = expiry_cash::new(config);

    // Fee 40 at rate 0.5 reserves 20; the skew charge reserves its own 30. Both are
    // withheld, so 70 of the 80 in cash is spoken for.
    cash.collect_trade_fee(
        coin::mint_for_testing<DUSDC>(FEE_AMOUNT, ctx).into_balance(),
        FEE_AMOUNT,
    );
    cash.receive(coin::mint_for_testing<DUSDC>(FEE_AMOUNT, ctx).into_balance());
    cash.credit_skew_reserve(SKEW_CHARGE);

    assert_eq!(cash.balance(), FEE_AMOUNT + FEE_AMOUNT); // 80
    assert_eq!(cash.free_cash(), 80 - EXPECTED_REBATE_RESERVE - SKEW_CHARGE); // 80 - 20 - 30 = 30
    assert_eq!(
        cash.required_cash(CASH_AMOUNT),
        CASH_AMOUNT + EXPECTED_REBATE_RESERVE + SKEW_CHARGE,
    ); // 100 + 20 + 30 = 150

    destroy(cash);
}

#[test]
fun paying_a_skew_rebate_draws_down_the_escrow_and_frees_the_rest() {
    let ctx = &mut tx_context::dummy();
    let mut config = expiry_cash_config::new();
    config.set_trading_loss_rebate_rate(REBATE_RATE);
    let mut cash = expiry_cash::new(config);
    cash.receive(coin::mint_for_testing<DUSDC>(CASH_AMOUNT, ctx).into_balance());
    cash.credit_skew_reserve(SKEW_CHARGE);

    let rebate = cash.pay_skew_rebate(PARTIAL_SKEW_REBATE);

    assert_eq!(rebate.value(), PARTIAL_SKEW_REBATE); // 12
    assert_eq!(cash.balance(), CASH_AMOUNT - PARTIAL_SKEW_REBATE); // 88
    assert_eq!(cash.skew_reserve(), SKEW_CHARGE - PARTIAL_SKEW_REBATE); // 18
    // The rebate leaves cash and the escrow together, so free cash is unchanged:
    // 100 - 30 = 70 before, 88 - 18 = 70 after.
    assert_eq!(cash.free_cash(), CASH_AMOUNT - SKEW_CHARGE); // 70

    // Releasing the residual at settlement moves it to free cash without moving
    // any coins.
    cash.release_skew_reserve();
    assert_eq!(cash.skew_reserve(), 0);
    assert_eq!(cash.balance(), CASH_AMOUNT - PARTIAL_SKEW_REBATE); // 88
    assert_eq!(cash.free_cash(), CASH_AMOUNT - PARTIAL_SKEW_REBATE); // 88

    destroy(rebate);
    destroy(cash);
}

#[test, expected_failure(abort_code = expiry_cash::ESkewRebateExceedsReserve)]
fun skew_rebate_above_the_escrow_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut config = expiry_cash_config::new();
    config.set_trading_loss_rebate_rate(REBATE_RATE);
    let mut cash = expiry_cash::new(config);
    // Cash alone cannot fund a rebate: the escrow is the whole budget, so a claim
    // above it aborts even though the balance would cover it.
    cash.receive(coin::mint_for_testing<DUSDC>(CASH_AMOUNT, ctx).into_balance());
    cash.credit_skew_reserve(SKEW_CHARGE);

    let rebate = cash.pay_skew_rebate(SKEW_CHARGE + 1);
    destroy(rebate);
    abort 999
}
