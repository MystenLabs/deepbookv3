// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Fee reserve accounting for Predict trade fees.
///
/// LP fees stay with expiry cash as LP-owned NAV. Protocol and insurance fee
/// balances are stored here so they are real reserved assets, not just counters.
module deepbook_predict::fee_reserve;

use deepbook::math;
use deepbook_predict::fee_config::FeeConfig;
use dusdc::dusdc::DUSDC;
use sui::balance::{Self, Balance};

const EInvalidFeeSplit: u64 = 2;

/// Reserve state for protocol and insurance fee portions.
///
/// The LP share is counted here but returned to the caller so it can be
/// deposited into LP-owned expiry cash.
public struct FeeReserve has store {
    protocol_balance: Balance<DUSDC>,
    insurance_balance: Balance<DUSDC>,
    lp_fee_share: u64,
    protocol_fee_share: u64,
    insurance_fee_share: u64,
    lp_fees_accrued: u64,
    protocol_fees_accrued: u64,
    insurance_fees_accrued: u64,
    total_fees_accrued: u64,
}

// === Public-Package Functions ===

public(package) fun total_fees_accrued(reserve: &FeeReserve): u64 {
    reserve.total_fees_accrued
}

public(package) fun lp_fees_accrued(reserve: &FeeReserve): u64 {
    reserve.lp_fees_accrued
}

public(package) fun protocol_fees_accrued(reserve: &FeeReserve): u64 {
    reserve.protocol_fees_accrued
}

public(package) fun insurance_fees_accrued(reserve: &FeeReserve): u64 {
    reserve.insurance_fees_accrued
}

public(package) fun lp_fee_share(reserve: &FeeReserve): u64 {
    reserve.lp_fee_share
}

public(package) fun protocol_fee_share(reserve: &FeeReserve): u64 {
    reserve.protocol_fee_share
}

public(package) fun insurance_fee_share(reserve: &FeeReserve): u64 {
    reserve.insurance_fee_share
}

public(package) fun protocol_asset_balance(reserve: &FeeReserve): u64 {
    reserve.protocol_balance.value()
}

public(package) fun insurance_asset_balance(reserve: &FeeReserve): u64 {
    reserve.insurance_balance.value()
}

/// Create an empty fee reserve with fee shares snapshotted from config.
public(package) fun new(config: &FeeConfig): FeeReserve {
    FeeReserve {
        protocol_balance: balance::zero(),
        insurance_balance: balance::zero(),
        lp_fee_share: config.lp_fee_share(),
        protocol_fee_share: config.protocol_fee_share(),
        insurance_fee_share: config.insurance_fee_share(),
        lp_fees_accrued: 0,
        protocol_fees_accrued: 0,
        insurance_fees_accrued: 0,
        total_fees_accrued: 0,
    }
}

/// Accrue a full fee balance, returning the LP-owned portion to the caller.
/// Protocol and insurance shares are retained as concrete reserve balances.
public(package) fun accrue_fee(
    reserve: &mut FeeReserve,
    fee: Balance<DUSDC>,
): (Balance<DUSDC>, u64, u64, u64, u64) {
    let total_fee = fee.value();
    if (total_fee == 0) return (fee, 0, 0, 0, 0);

    let (lp_fee, protocol_fee, insurance_fee) = reserve.split_fee_amounts(total_fee);
    let (lp_balance, protocol_balance, insurance_balance) = split_fee(
        fee,
        protocol_fee,
        insurance_fee,
    );
    reserve.record_fee_accrual(protocol_balance, insurance_balance, lp_fee, total_fee);

    (lp_balance, total_fee, lp_fee, protocol_fee, insurance_fee)
}

/// Extract concrete protocol and insurance fee balances for pool-level custody.
public(package) fun take_fee_balances(reserve: &mut FeeReserve): (Balance<DUSDC>, Balance<DUSDC>) {
    let protocol_amount = reserve.protocol_balance.value();
    let insurance_amount = reserve.insurance_balance.value();
    (
        reserve.protocol_balance.split(protocol_amount),
        reserve.insurance_balance.split(insurance_amount),
    )
}

// === Private Functions ===

/// Split a full fee balance into `(lp_fee, protocol_fee, insurance_fee)`.
/// Protocol and insurance shares round down; dust remains in the LP balance.
fun split_fee(
    fee: Balance<DUSDC>,
    protocol_fee: u64,
    insurance_fee: u64,
): (Balance<DUSDC>, Balance<DUSDC>, Balance<DUSDC>) {
    let mut lp_balance = fee;
    let protocol_balance = lp_balance.split(protocol_fee);
    let insurance_balance = lp_balance.split(insurance_fee);

    (lp_balance, protocol_balance, insurance_balance)
}

fun split_fee_amounts(reserve: &FeeReserve, total_fee: u64): (u64, u64, u64) {
    let protocol_fee = math::mul(total_fee, reserve.protocol_fee_share);
    let insurance_fee = math::mul(total_fee, reserve.insurance_fee_share);
    let non_lp_fee = protocol_fee + insurance_fee;
    assert!(non_lp_fee <= total_fee, EInvalidFeeSplit);
    (total_fee - non_lp_fee, protocol_fee, insurance_fee)
}

fun record_fee_accrual(
    reserve: &mut FeeReserve,
    protocol_balance: Balance<DUSDC>,
    insurance_balance: Balance<DUSDC>,
    lp_fee: u64,
    total_fee: u64,
) {
    let protocol_fee = protocol_balance.value();
    let insurance_fee = insurance_balance.value();
    reserve.total_fees_accrued = reserve.total_fees_accrued + total_fee;
    reserve.lp_fees_accrued = reserve.lp_fees_accrued + lp_fee;
    reserve.protocol_fees_accrued = reserve.protocol_fees_accrued + protocol_fee;
    reserve.insurance_fees_accrued = reserve.insurance_fees_accrued + insurance_fee;

    reserve.protocol_balance.join(protocol_balance);
    reserve.insurance_balance.join(insurance_balance);
}

// === Test-Only Functions ===

#[test_only]
public fun drain_protocol_for_testing(reserve: &mut FeeReserve): Balance<DUSDC> {
    let amount = reserve.protocol_balance.value();
    reserve.protocol_balance.split(amount)
}

#[test_only]
public fun drain_insurance_for_testing(reserve: &mut FeeReserve): Balance<DUSDC> {
    let amount = reserve.insurance_balance.value();
    reserve.insurance_balance.split(amount)
}

#[test_only]
public fun destroy_empty_for_testing(reserve: FeeReserve) {
    let FeeReserve {
        protocol_balance,
        insurance_balance,
        lp_fee_share: _,
        protocol_fee_share: _,
        insurance_fee_share: _,
        total_fees_accrued: _,
        lp_fees_accrued: _,
        protocol_fees_accrued: _,
        insurance_fees_accrued: _,
    } = reserve;
    protocol_balance.destroy_zero();
    insurance_balance.destroy_zero();
}
