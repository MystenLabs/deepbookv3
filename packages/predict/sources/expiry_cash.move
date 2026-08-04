// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Expiry-local DUSDC custody, unresolved rebate-reserve accounting, and the
/// inventory-skew escrow.
///
/// This leaf owns cash balance arithmetic, the trading-fee basis used to reserve
/// cash for loss rebates, and the collected inventory-skew charges held back for
/// close-side rebates. Both reserves are withheld from free cash and added to
/// required cash; they differ in how they are measured — the loss rebate is
/// derived from a fee basis at the snapshotted rate, while the skew escrow is a
/// direct running dollar total. It does not decide payment eligibility, pool
/// allocation, or market phase sequencing; `ExpiryMarket` decides when each cash
/// operation is allowed and supplies the relevant payout liability.
module deepbook_predict::expiry_cash;

use deepbook_predict::expiry_cash_config::ExpiryCashConfig;
use dusdc::dusdc::DUSDC;
use sui::balance::{Self, Balance};

const EInsufficientCash: u64 = 0;
const EUnresolvedTradingFeesUnderflow: u64 = 1;
const ERebateBasisExceedsFee: u64 = 2;
const ESkewRebateExceedsReserve: u64 = 3;

/// Cash, unresolved rebate basis, and skew escrow for one expiry market.
public struct ExpiryCash has store {
    cash_balance: Balance<DUSDC>,
    unresolved_trading_fees_paid: u64,
    /// Collected inventory-skew charges still available for close-side rebates, in
    /// DUSDC base units. Held inside `cash_balance`, so it is reserved rather than
    /// segregated; whatever survives to settlement is released to LPs with the rest
    /// of the expiry's cash.
    skew_reserve: u64,
    config: ExpiryCashConfig,
}

/// Create zero-cash expiry custody with a frozen rebate rate.
public(package) fun new(config: ExpiryCashConfig): ExpiryCash {
    ExpiryCash {
        cash_balance: balance::zero(),
        unresolved_trading_fees_paid: 0,
        skew_reserve: 0,
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

public(package) fun skew_reserve(cash: &ExpiryCash): u64 {
    cash.skew_reserve
}

/// Return the cash required to cover payout liability plus both reserves.
public(package) fun required_cash(cash: &ExpiryCash, payout_liability: u64): u64 {
    payout_liability + cash.rebate_reserve() + cash.skew_reserve
}

/// Return cash net of both reserves, floored at zero. Pool NAV values this amount
/// separately from payout liability.
public(package) fun free_cash(cash: &ExpiryCash): u64 {
    cash.balance().saturating_sub(cash.rebate_reserve() + cash.skew_reserve)
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

/// Add a collected inventory-skew charge to the escrow. The cash itself arrives
/// through `receive` with the rest of the mint payment, so this only raises the
/// share of that cash reserved for close-side rebates.
public(package) fun credit_skew_reserve(cash: &mut ExpiryCash, amount: u64) {
    cash.skew_reserve = cash.skew_reserve + amount;
}

/// Pay an inventory-skew rebate out of the escrow. Rebates are paid ONLY from
/// collected skew charges, so the escrow is the whole budget; the caller owns the
/// decision to cap its claim at `skew_reserve`.
public(package) fun pay_skew_rebate(cash: &mut ExpiryCash, amount: u64): Balance<DUSDC> {
    assert!(amount <= cash.skew_reserve, ESkewRebateExceedsReserve);
    cash.skew_reserve = cash.skew_reserve - amount;
    cash.pay_authorized(amount)
}

/// Drop the skew escrow, leaving its cash unreserved. The caller owns the
/// judgement that no further close-side rebate can be claimed; after settlement the
/// residual belongs to LPs like any other expiry surplus.
public(package) fun release_skew_reserve(cash: &mut ExpiryCash) {
    cash.skew_reserve = 0;
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
