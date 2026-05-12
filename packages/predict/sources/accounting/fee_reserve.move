// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Fee reserve accounting for Predict trade fees.
///
/// LP fees stay in the vault as LP-owned NAV. Protocol and insurance fee
/// balances are stored here so they are real reserved assets, not just counters.
module deepbook_predict::fee_reserve;

use deepbook::math;
use deepbook_predict::constants;
use dusdc::dusdc::DUSDC;
use sui::{balance::{Self, Balance}, event};

const EInvalidFeeSplit: u64 = 0;

/// Emitted whenever a charged trade accrues an official fee split.
public struct FeeAccrued has copy, drop, store {
    owner_id: ID,
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

/// Return concrete protocol reserve balance.
public fun protocol_asset_balance(reserve: &FeeReserve): u64 {
    reserve.protocol_balance.value()
}

/// Return concrete insurance reserve balance.
public fun insurance_asset_balance(reserve: &FeeReserve): u64 {
    reserve.insurance_balance.value()
}

// === Public-Package Functions ===

/// Create an empty fee reserve.
public(package) fun new(): FeeReserve {
    FeeReserve {
        protocol_balance: balance::zero(),
        insurance_balance: balance::zero(),
        lp_fee_share: constants::default_lp_fee_share!(),
        protocol_fee_share: constants::default_protocol_fee_share!(),
        insurance_fee_share: constants::default_insurance_fee_share!(),
        lp_fees_accrued: 0,
        protocol_fees_accrued: 0,
        insurance_fees_accrued: 0,
        total_fees_accrued: 0,
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

/// Accrue a full fee balance, returning the LP-owned portion to the caller.
/// Protocol and insurance shares are retained as concrete reserve balances.
public(package) fun accrue_fee(
    reserve: &mut FeeReserve,
    fee: Balance<DUSDC>,
    owner_id: ID,
): Balance<DUSDC> {
    let total_fee = fee.value();
    if (total_fee == 0) return fee;

    let (lp_balance, protocol_balance, insurance_balance) = reserve.split_fee(fee);
    reserve.record_fee_accrual(
        protocol_balance,
        insurance_balance,
        lp_balance.value(),
        total_fee,
        owner_id,
    );

    lp_balance
}

// === Private Functions ===

/// Split a full fee balance into `(lp_fee, protocol_fee, insurance_fee)`.
/// Protocol and insurance shares round down; dust remains in the LP balance.
fun split_fee(
    reserve: &FeeReserve,
    fee: Balance<DUSDC>,
): (Balance<DUSDC>, Balance<DUSDC>, Balance<DUSDC>) {
    let mut lp_balance = fee;
    let protocol_fee = math::mul(lp_balance.value(), reserve.protocol_fee_share);
    let insurance_fee = math::mul(lp_balance.value(), reserve.insurance_fee_share);
    let protocol_balance = lp_balance.split(protocol_fee);
    let insurance_balance = lp_balance.split(insurance_fee);

    (lp_balance, protocol_balance, insurance_balance)
}

fun record_fee_accrual(
    reserve: &mut FeeReserve,
    protocol_balance: Balance<DUSDC>,
    insurance_balance: Balance<DUSDC>,
    lp_fee: u64,
    total_fee: u64,
    owner_id: ID,
) {
    let protocol_fee = protocol_balance.value();
    let insurance_fee = insurance_balance.value();
    reserve.total_fees_accrued = reserve.total_fees_accrued + total_fee;
    reserve.lp_fees_accrued = reserve.lp_fees_accrued + lp_fee;
    reserve.protocol_fees_accrued = reserve.protocol_fees_accrued + protocol_fee;
    reserve.insurance_fees_accrued = reserve.insurance_fees_accrued + insurance_fee;

    reserve.protocol_balance.join(protocol_balance);
    reserve.insurance_balance.join(insurance_balance);

    event::emit(FeeAccrued {
        owner_id,
        total_fee,
        lp_fee,
        protocol_fee,
        insurance_fee,
    });
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
