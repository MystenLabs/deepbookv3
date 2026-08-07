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
const INVENTORY_IMPACT_CHARGE: u64 = 30;
const INVENTORY_IMPACT_REBATE: u64 = 12;
/// Cash left after draining below the rebate reserve (10 < reserve 20).
const CASH_BELOW_RESERVE: u64 = 10;

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

#[test]
fun inventory_impact_reserve_isolated_from_fee_basis_and_free_cash() {
    let ctx = &mut tx_context::dummy();
    let mut config = expiry_cash_config::new();
    config.set_trading_loss_rebate_rate(REBATE_RATE);
    let mut cash = expiry_cash::new(config);

    // The charge has already arrived in custody when the market earmarks it.
    cash.receive(coin::mint_for_testing<DUSDC>(CASH_AMOUNT, ctx).into_balance());
    cash.credit_inventory_impact_reserve(INVENTORY_IMPACT_CHARGE);

    assert_eq!(cash.inventory_impact_reserve(), INVENTORY_IMPACT_CHARGE);
    assert_eq!(cash.rebate_reserve(), 0);
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
    let mut cash = expiry_cash::new(expiry_cash_config::new());
    cash.receive(coin::mint_for_testing<DUSDC>(CASH_AMOUNT, ctx).into_balance());
    cash.credit_inventory_impact_reserve(INVENTORY_IMPACT_CHARGE);

    let unexpected = cash.pay_inventory_impact_rebate(INVENTORY_IMPACT_CHARGE + 1);
    destroy(unexpected);
    abort 999
}

#[test]
fun settlement_release_turns_residual_escrow_into_surplus() {
    let ctx = &mut tx_context::dummy();
    let mut cash = expiry_cash::new(expiry_cash_config::new());
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
