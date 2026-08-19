// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Expiry-local DUSDC custody and isolated reserve accounting.
///
/// This leaf owns cash balance arithmetic and the inventory-impact escrow used
/// only for live-close rebates. It does not decide payment eligibility, pool
/// allocation, or market phase sequencing; `ExpiryMarket` owns those policies.
module deepbook_predict::expiry_cash;

use dusdc::dusdc::DUSDC;
use sui::balance::{Self, Balance};

const EInsufficientCash: u64 = 0;
const EInventoryImpactRebateExceedsReserve: u64 = 1;

/// Cash custody for one expiry market.
public struct ExpiryCash has store {
    cash_balance: Balance<DUSDC>,
    /// Collected inventory-impact charges still reserved for live-close rebates.
    inventory_impact_reserve: u64,
}

/// Create zero-cash expiry custody.
public(package) fun new(): ExpiryCash {
    ExpiryCash {
        cash_balance: balance::zero(),
        inventory_impact_reserve: 0,
    }
}

public(package) fun balance(cash: &ExpiryCash): u64 {
    cash.cash_balance.value()
}

public(package) fun inventory_impact_reserve(cash: &ExpiryCash): u64 {
    cash.inventory_impact_reserve
}

/// Return the cash required to cover payout liability plus the impact escrow.
public(package) fun required_cash(cash: &ExpiryCash, payout_liability: u64): u64 {
    payout_liability + cash.inventory_impact_reserve
}

/// Return cash net of the inventory-impact escrow, floored at zero. Pool NAV
/// values this amount separately from payout liability.
public(package) fun free_cash(cash: &ExpiryCash): u64 {
    cash.balance().saturating_sub(cash.inventory_impact_reserve)
}

/// Abort unless current cash covers payout liability plus the impact escrow.
public(package) fun assert_backing(cash: &ExpiryCash, payout_liability: u64) {
    assert!(cash.balance() >= cash.required_cash(payout_liability), EInsufficientCash);
}

/// Join incoming expiry cash without interpreting why the caller is sending it.
public(package) fun receive(cash: &mut ExpiryCash, funds: Balance<DUSDC>) {
    cash.cash_balance.join(funds);
}

/// Release caller-approved surplus while preserving payout and escrow backing.
public(package) fun release_surplus(
    cash: &mut ExpiryCash,
    amount: u64,
    payout_liability: u64,
): Balance<DUSDC> {
    if (amount == 0) return balance::zero();
    assert!(cash.balance() >= cash.required_cash(payout_liability) + amount, EInsufficientCash);
    cash.cash_balance.split(amount)
}

/// Pay an already-authorized payout or cash release.
///
/// The caller owns the surrounding liability transition and the post-payment
/// backing check.
public(package) fun pay_authorized(cash: &mut ExpiryCash, amount: u64): Balance<DUSDC> {
    assert!(cash.balance() >= amount, EInsufficientCash);
    cash.cash_balance.split(amount)
}

/// Reserve a charge already received with the mint payment. It remains part of
/// `cash_balance`, but cannot be swept or counted in NAV while live.
public(package) fun credit_inventory_impact_reserve(cash: &mut ExpiryCash, amount: u64) {
    cash.inventory_impact_reserve = cash.inventory_impact_reserve + amount;
}

/// Pay an inventory-impact rebate exclusively from its isolated escrow.
public(package) fun pay_inventory_impact_rebate(
    cash: &mut ExpiryCash,
    amount: u64,
): Balance<DUSDC> {
    assert!(amount <= cash.inventory_impact_reserve, EInventoryImpactRebateExceedsReserve);
    cash.inventory_impact_reserve = cash.inventory_impact_reserve - amount;
    cash.pay_authorized(amount)
}

/// Release the residual inventory-impact escrow after settlement, when no live
/// close can earn another rebate. Its cash then becomes normal expiry surplus.
public(package) fun release_inventory_impact_reserve(cash: &mut ExpiryCash) {
    cash.inventory_impact_reserve = 0;
}
