// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Expiry-local DUSDC custody.
///
/// This leaf owns cash balance arithmetic for one expiry market. It does not
/// decide payment eligibility, pool allocation, or market phase sequencing;
/// `ExpiryMarket` owns those policies.
module deepbook_predict::expiry_cash;

use dusdc::dusdc::DUSDC;
use sui::balance::{Self, Balance};

const EInsufficientCash: u64 = 0;

/// Cash custody for one expiry market.
public struct ExpiryCash has store {
    cash_balance: Balance<DUSDC>,
}

/// Create zero-cash expiry custody.
public(package) fun new(): ExpiryCash {
    ExpiryCash { cash_balance: balance::zero() }
}

public(package) fun balance(cash: &ExpiryCash): u64 {
    cash.cash_balance.value()
}

/// Abort unless current cash covers payout liability.
public(package) fun assert_backing(cash: &ExpiryCash, payout_liability: u64) {
    assert!(cash.balance() >= payout_liability, EInsufficientCash);
}

/// Join incoming expiry cash without interpreting why the caller is sending it.
public(package) fun receive(cash: &mut ExpiryCash, funds: Balance<DUSDC>) {
    cash.cash_balance.join(funds);
}

/// Release caller-approved surplus while preserving payout backing.
public(package) fun release_surplus(
    cash: &mut ExpiryCash,
    amount: u64,
    payout_liability: u64,
): Balance<DUSDC> {
    if (amount == 0) return balance::zero();
    assert!(cash.balance() >= payout_liability + amount, EInsufficientCash);
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
