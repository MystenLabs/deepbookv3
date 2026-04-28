// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Fee reserve accounting for Predict trade fees.
///
/// LP fees stay in the vault as LP-owned NAV. Protocol and insurance fee
/// balances are stored here so they are real reserved assets, not just counters.
module deepbook_predict::fee_reserve;

use deepbook::math;
use deepbook_predict::constants;
use std::type_name::{Self, TypeName};
use sui::{bag::{Self, Bag}, balance::{Self, Balance}, event};

const EInvalidFeeSplit: u64 = 0;

/// Dynamic bag key for storing a concrete asset balance by type.
public struct BalanceKey<phantom T> has copy, drop, store {}

/// Emitted whenever a charged trade accrues an official fee split.
public struct FeeAccrued has copy, drop, store {
    predict_id: ID,
    quote_asset: TypeName,
    total_fee: u64,
    lp_fee: u64,
    protocol_fee: u64,
    insurance_fee: u64,
}

/// Reserve state for protocol and insurance fee portions.
///
/// The LP share is counted here but returned to the caller so it can be
/// deposited into the vault and remain LP-owned NAV.
public struct FeeReserve has store {
    protocol_balances: Bag,
    insurance_balances: Bag,
    lp_fee_share: u64,
    protocol_fee_share: u64,
    insurance_fee_share: u64,
    total_fees_accrued: u64,
    lp_fees_accrued: u64,
    protocol_fees_accrued: u64,
    insurance_fees_accrued: u64,
}

// === Public Functions ===

/// Return the official total fee amount accrued across all charged trades.
public fun total_fees_accrued(reserve: &FeeReserve): u64 {
    reserve.total_fees_accrued
}

/// Return total LP fee share accrued across all charged trades.
public fun lp_fees_accrued(reserve: &FeeReserve): u64 {
    reserve.lp_fees_accrued
}

/// Return total protocol fee share accrued across all charged trades.
public fun protocol_fees_accrued(reserve: &FeeReserve): u64 {
    reserve.protocol_fees_accrued
}

/// Return total insurance fee share accrued across all charged trades.
public fun insurance_fees_accrued(reserve: &FeeReserve): u64 {
    reserve.insurance_fees_accrued
}

/// Return the LP fee share.
public fun lp_fee_share(reserve: &FeeReserve): u64 {
    reserve.lp_fee_share
}

/// Return the protocol fee share.
public fun protocol_fee_share(reserve: &FeeReserve): u64 {
    reserve.protocol_fee_share
}

/// Return the insurance fee share.
public fun insurance_fee_share(reserve: &FeeReserve): u64 {
    reserve.insurance_fee_share
}

/// Return concrete protocol reserve balance for asset type `T`, or zero if absent.
public fun protocol_asset_balance<T>(reserve: &FeeReserve): u64 {
    asset_balance<T>(&reserve.protocol_balances)
}

/// Return concrete insurance reserve balance for asset type `T`, or zero if absent.
public fun insurance_asset_balance<T>(reserve: &FeeReserve): u64 {
    asset_balance<T>(&reserve.insurance_balances)
}

// === Public-Package Functions ===

/// Create an empty fee reserve.
public(package) fun new(ctx: &mut TxContext): FeeReserve {
    FeeReserve {
        protocol_balances: bag::new(ctx),
        insurance_balances: bag::new(ctx),
        lp_fee_share: constants::default_lp_fee_share!(),
        protocol_fee_share: constants::default_protocol_fee_share!(),
        insurance_fee_share: constants::default_insurance_fee_share!(),
        total_fees_accrued: 0,
        lp_fees_accrued: 0,
        protocol_fees_accrued: 0,
        insurance_fees_accrued: 0,
    }
}

/// Set the fee distribution shares. Shares must sum to 100%.
public(package) fun set_fee_shares(
    reserve: &mut FeeReserve,
    lp_fee_share: u64,
    protocol_fee_share: u64,
    insurance_fee_share: u64,
) {
    let total_share = lp_fee_share + protocol_fee_share + insurance_fee_share;
    assert!(total_share == constants::float_scaling!(), EInvalidFeeSplit);
    reserve.lp_fee_share = lp_fee_share;
    reserve.protocol_fee_share = protocol_fee_share;
    reserve.insurance_fee_share = insurance_fee_share;
}

/// Split a full fee balance into `(lp_fee, protocol_fee, insurance_fee)`.
/// Protocol and insurance shares round down; dust remains in the LP balance.
public(package) fun split_fee<T>(
    reserve: &FeeReserve,
    fee: Balance<T>,
): (Balance<T>, Balance<T>, Balance<T>) {
    let mut lp_balance = fee;
    let protocol_fee = math::mul(lp_balance.value(), reserve.protocol_fee_share);
    let insurance_fee = math::mul(lp_balance.value(), reserve.insurance_fee_share);
    let protocol_balance = lp_balance.split(protocol_fee);
    let insurance_balance = lp_balance.split(insurance_fee);

    (lp_balance, protocol_balance, insurance_balance)
}

/// Accrue a full fee balance, returning the LP-owned portion to the caller.
/// Protocol and insurance shares are retained as concrete reserve balances.
public(package) fun accrue_fee<T>(
    reserve: &mut FeeReserve,
    fee: Balance<T>,
    predict_id: ID,
): Balance<T> {
    let total_fee = fee.value();
    if (total_fee == 0) return fee;

    let (lp_balance, protocol_balance, insurance_balance) = reserve.split_fee(fee);
    reserve.record_fee_accrual(
        protocol_balance,
        insurance_balance,
        lp_balance.value(),
        total_fee,
        predict_id,
    );

    lp_balance
}

// === Private Functions ===

fun record_fee_accrual<T>(
    reserve: &mut FeeReserve,
    protocol_balance: Balance<T>,
    insurance_balance: Balance<T>,
    lp_fee: u64,
    total_fee: u64,
    predict_id: ID,
) {
    let protocol_fee = protocol_balance.value();
    let insurance_fee = insurance_balance.value();
    reserve.total_fees_accrued = reserve.total_fees_accrued + total_fee;
    reserve.lp_fees_accrued = reserve.lp_fees_accrued + lp_fee;
    reserve.protocol_fees_accrued = reserve.protocol_fees_accrued + protocol_fee;
    reserve.insurance_fees_accrued = reserve.insurance_fees_accrued + insurance_fee;

    reserve.deposit_protocol_balance(protocol_balance);
    reserve.deposit_insurance_balance(insurance_balance);

    event::emit(FeeAccrued {
        predict_id,
        quote_asset: type_name::with_defining_ids<T>(),
        total_fee,
        lp_fee,
        protocol_fee,
        insurance_fee,
    });
}

fun deposit_protocol_balance<T>(reserve: &mut FeeReserve, payment: Balance<T>) {
    deposit_balance(&mut reserve.protocol_balances, payment);
}

fun deposit_insurance_balance<T>(reserve: &mut FeeReserve, payment: Balance<T>) {
    deposit_balance(&mut reserve.insurance_balances, payment);
}

fun asset_balance<T>(balances: &Bag): u64 {
    let key = BalanceKey<T> {};
    if (balances.contains(key)) {
        let balance: &Balance<T> = &balances[key];
        balance.value()
    } else {
        0
    }
}

fun deposit_balance<T>(balances: &mut Bag, payment: Balance<T>) {
    if (payment.value() == 0) {
        payment.destroy_zero();
        return
    };

    let key = BalanceKey<T> {};
    if (balances.contains(key)) {
        let balance: &mut Balance<T> = &mut balances[key];
        balance.join(payment);
    } else {
        balances.add(key, payment);
    }
}

// === Test-Only Functions ===

#[test_only]
public fun drain_protocol_for_testing<T>(reserve: &mut FeeReserve): Balance<T> {
    drain_balance_for_testing(&mut reserve.protocol_balances)
}

#[test_only]
public fun drain_insurance_for_testing<T>(reserve: &mut FeeReserve): Balance<T> {
    drain_balance_for_testing(&mut reserve.insurance_balances)
}

#[test_only]
public fun destroy_empty_for_testing(reserve: FeeReserve) {
    let FeeReserve {
        protocol_balances,
        insurance_balances,
        lp_fee_share: _,
        protocol_fee_share: _,
        insurance_fee_share: _,
        total_fees_accrued: _,
        lp_fees_accrued: _,
        protocol_fees_accrued: _,
        insurance_fees_accrued: _,
    } = reserve;
    protocol_balances.destroy_empty();
    insurance_balances.destroy_empty();
}

#[test_only]
fun drain_balance_for_testing<T>(balances: &mut Bag): Balance<T> {
    let key = BalanceKey<T> {};
    if (balances.contains(key)) {
        balances.remove(key)
    } else {
        balance::zero<T>()
    }
}
