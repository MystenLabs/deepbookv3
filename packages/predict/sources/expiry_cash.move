// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Expiry-local DUSDC custody and unresolved rebate-reserve accounting.
///
/// This leaf owns cash balance arithmetic and the trading-fee basis used to
/// reserve cash for loss rebates. It does not decide payment eligibility, pool
/// allocation, or market phase sequencing; `ExpiryMarket` decides when each cash
/// operation is allowed and supplies the relevant payout liability.
module deepbook_predict::expiry_cash;

use deepbook::math;
use dusdc::dusdc::DUSDC;
use sui::balance::{Self, Balance};

const EInsufficientCash: u64 = 0;
const EUnresolvedTradingFeesUnderflow: u64 = 1;

/// Cash and unresolved rebate basis for one expiry market.
public struct ExpiryCash has store {
    cash_balance: Balance<DUSDC>,
    unresolved_trading_fees_paid: u64,
    trading_loss_rebate_rate: u64,
}

/// Create zero-cash expiry custody with a frozen rebate rate.
public(package) fun new(trading_loss_rebate_rate: u64): ExpiryCash {
    ExpiryCash {
        cash_balance: balance::zero(),
        unresolved_trading_fees_paid: 0,
        trading_loss_rebate_rate,
    }
}

public(package) fun balance(cash: &ExpiryCash): u64 {
    cash.cash_balance.value()
}

public(package) fun trading_loss_rebate_rate(cash: &ExpiryCash): u64 {
    cash.trading_loss_rebate_rate
}

public(package) fun rebate_reserve(cash: &ExpiryCash): u64 {
    math::mul(cash.unresolved_trading_fees_paid, cash.trading_loss_rebate_rate)
}

/// Return payout plus unresolved rebate reserve cash required to keep the expiry backed.
public(package) fun required_cash(cash: &ExpiryCash, payout_liability: u64): u64 {
    payout_liability + cash.rebate_reserve()
}

/// Abort unless current cash covers payout liability plus unresolved rebate reserve.
public(package) fun assert_backing(cash: &ExpiryCash, payout_liability: u64) {
    assert!(cash.balance() >= cash.required_cash(payout_liability), EInsufficientCash);
}

/// Join incoming expiry cash without interpreting why the caller is sending it.
public(package) fun receive(cash: &mut ExpiryCash, funds: Balance<DUSDC>) {
    cash.cash_balance.join(funds);
}

/// Release caller-approved surplus while preserving payout and rebate backing.
public(package) fun release_surplus(
    cash: &mut ExpiryCash,
    amount: u64,
    payout_liability: u64,
): Balance<DUSDC> {
    if (amount == 0) return balance::zero();
    assert!(cash.balance() >= cash.required_cash(payout_liability) + amount, EInsufficientCash);
    cash.cash_balance.split(amount)
}

/// Pay an already-authorized payout, rebate claim, or cash release.
///
/// The caller owns the surrounding liability or rebate-basis transition and the
/// post-payment backing check.
public(package) fun pay_authorized(cash: &mut ExpiryCash, amount: u64): Balance<DUSDC> {
    assert!(cash.balance() >= amount, EInsufficientCash);
    cash.cash_balance.split(amount)
}

/// Join trade-fee cash and add nonzero fees to unresolved rebate basis.
public(package) fun collect_trade_fee(cash: &mut ExpiryCash, fee: Balance<DUSDC>): u64 {
    let fee_amount = fee.value();
    cash.cash_balance.join(fee);
    if (fee_amount > 0) {
        cash.unresolved_trading_fees_paid = cash.unresolved_trading_fees_paid + fee_amount;
    };
    fee_amount
}

/// Decrement resolved fee basis and return the rebate reserve implied by that basis.
public(package) fun resolve_rebate_reserve_for_fee_basis(
    cash: &mut ExpiryCash,
    trading_fees_paid: u64,
): u64 {
    assert!(
        cash.unresolved_trading_fees_paid >= trading_fees_paid,
        EUnresolvedTradingFeesUnderflow,
    );
    cash.unresolved_trading_fees_paid = cash.unresolved_trading_fees_paid - trading_fees_paid;
    math::mul(trading_fees_paid, cash.trading_loss_rebate_rate)
}
