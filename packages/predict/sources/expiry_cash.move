// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Expiry-local DUSDC custody and unresolved rebate-reserve accounting.
///
/// This leaf owns cash balance arithmetic and the trading-fee basis used to
/// reserve cash for loss rebates. It does not decide payment eligibility, pool
/// allocation, or market phase sequencing; `ExpiryMarket` decides when each cash
/// operation is allowed and supplies the relevant payout liability.
module deepbook_predict::expiry_cash;

use deepbook_predict::expiry_cash_config::ExpiryCashConfig;
use dusdc::dusdc::DUSDC;
use fixed_math::{interval::{Self, Interval}, math};
use sui::balance::{Self, Balance};

const EInsufficientCash: u64 = 0;
const EUnresolvedTradingFeesUnderflow: u64 = 1;
const ERebateBasisExceedsFee: u64 = 2;

/// Cash and unresolved rebate basis for one expiry market.
public struct ExpiryCash has store {
    cash_balance: Balance<DUSDC>,
    unresolved_trading_fees_paid: u64,
    config: ExpiryCashConfig,
}

/// Create zero-cash expiry custody with a frozen rebate rate.
public(package) fun new(config: ExpiryCashConfig): ExpiryCash {
    ExpiryCash {
        cash_balance: balance::zero(),
        unresolved_trading_fees_paid: 0,
        config,
    }
}

public(package) fun balance(cash: &ExpiryCash): u64 {
    cash.cash_balance.value()
}

public(package) fun trading_loss_rebate_rate(cash: &ExpiryCash): u64 {
    cash.config.trading_loss_rebate_rate()
}

public(package) fun rebate_reserve(cash: &ExpiryCash): u64 {
    cash.config.rebate_reserve_for_fee_basis(cash.unresolved_trading_fees_paid)
}

/// Envelope form of the unresolved rebate reserve: the fixed-point multiply's
/// single rounding ulp carried as width. Backing asserts consume the high side
/// (a hold is a liability: never understated).
public(package) fun rebate_reserve_interval(cash: &ExpiryCash): Interval {
    let rate = cash.config.trading_loss_rebate_rate();
    interval::new(
        math::mul(cash.unresolved_trading_fees_paid, rate),
        math::mul_up(cash.unresolved_trading_fees_paid, rate),
    )
}

/// Return the cash required to cover payout liability plus unresolved rebate reserve.
public(package) fun required_cash(cash: &ExpiryCash, payout_liability: u64): u64 {
    payout_liability + cash.rebate_reserve()
}

/// Return cash net of the unresolved rebate reserve, floored at zero. Pool NAV
/// values this amount separately from payout liability.
public(package) fun free_cash(cash: &ExpiryCash): u64 {
    cash.balance().saturating_sub(cash.rebate_reserve())
}

/// Return the definitely-required cash: the payout liability's high side plus
/// the rebate reserve's high side. The definite-backing anchor for asserts and
/// releases; the scalar `required_cash` read keeps today's floor-rounded view.
public(package) fun required_cash_hi(cash: &ExpiryCash, payout_liability_hi: u64): u64 {
    payout_liability_hi + cash.rebate_reserve_interval().hi()
}

/// Abort unless current cash DEFINITELY covers payout liability plus the
/// unresolved rebate reserve: both holds enter at their envelope high sides.
public(package) fun assert_backing(cash: &ExpiryCash, payout_liability_hi: u64) {
    assert!(cash.balance() >= cash.required_cash_hi(payout_liability_hi), EInsufficientCash);
}

/// Join incoming expiry cash without interpreting why the caller is sending it.
public(package) fun receive(cash: &mut ExpiryCash, funds: Balance<DUSDC>) {
    cash.cash_balance.join(funds);
}

/// Release caller-approved surplus while preserving payout and rebate backing;
/// only the DEFINITELY-surplus portion (above both holds' high sides) may leave.
public(package) fun release_surplus(
    cash: &mut ExpiryCash,
    amount: u64,
    payout_liability_hi: u64,
): Balance<DUSDC> {
    if (amount == 0) return balance::zero();
    assert!(
        cash.balance() >= cash.required_cash_hi(payout_liability_hi) + amount,
        EInsufficientCash,
    );
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

/// Join trade-fee cash and add the caller-designated amount to unresolved rebate basis.
public(package) fun collect_trade_fee(
    cash: &mut ExpiryCash,
    fee: Balance<DUSDC>,
    rebate_fee_basis: u64,
) {
    assert!(rebate_fee_basis <= fee.value(), ERebateBasisExceedsFee);
    cash.cash_balance.join(fee);
    cash.unresolved_trading_fees_paid = cash.unresolved_trading_fees_paid + rebate_fee_basis;
}

/// Decrement resolved fee basis and return the reserve implied by that basis.
public(package) fun resolve_rebate_reserve_for_fee_basis(
    cash: &mut ExpiryCash,
    trading_fees_paid: u64,
): u64 {
    assert!(
        cash.unresolved_trading_fees_paid >= trading_fees_paid,
        EUnresolvedTradingFeesUnderflow,
    );
    cash.unresolved_trading_fees_paid = cash.unresolved_trading_fees_paid - trading_fees_paid;
    cash.config.rebate_reserve_for_fee_basis(trading_fees_paid)
}
