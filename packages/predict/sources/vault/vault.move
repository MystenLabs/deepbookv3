// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Vault module - counterparty for all trades.
///
/// The vault holds USDC and takes the opposite side of every trade:
/// - When user mints UP position, vault receives USDC and is short UP
/// - When user mints DOWN position, vault receives USDC and is short DOWN
/// - When user redeems, vault pays out and closes its short
///
/// Tracking:
/// - `positions` maps MarketKey to PositionData (quantity, premiums, payouts)
/// - `max_liability` / `min_liability` track worst/best case obligations
/// - `cumulative_premiums` and `cumulative_payouts` track all cash flows
/// - Profit = cumulative_premiums - cumulative_payouts
module deepbook_predict::vault;

use deepbook_predict::market_key::MarketKey;
use sui::{balance::{Self, Balance}, coin::Coin, table::{Self, Table}};

// === Errors ===
const ENoShortPosition: u64 = 0;
const EInsufficientBalance: u64 = 1;

// === Structs ===

public struct PositionData has copy, drop, store {
    quantity: u64,
    premiums: u64,
    payouts: u64,
}

public struct Vault<phantom Quote> has store {
    balance: Balance<Quote>,
    positions: Table<MarketKey, PositionData>,
    max_liability: u64,
    min_liability: u64,
    cumulative_premiums: u64,
    cumulative_payouts: u64,
}

// === Public Functions ===

public fun balance<Quote>(vault: &Vault<Quote>): u64 {
    vault.balance.value()
}

public fun max_liability<Quote>(vault: &Vault<Quote>): u64 {
    vault.max_liability
}

public fun min_liability<Quote>(vault: &Vault<Quote>): u64 {
    vault.min_liability
}

public fun cumulative_premiums<Quote>(vault: &Vault<Quote>): u64 {
    vault.cumulative_premiums
}

public fun cumulative_payouts<Quote>(vault: &Vault<Quote>): u64 {
    vault.cumulative_payouts
}

public fun position<Quote>(vault: &Vault<Quote>, key: MarketKey): u64 {
    if (vault.positions.contains(key)) { vault.positions[key].quantity } else { 0 }
}

public fun position_data<Quote>(vault: &Vault<Quote>, key: MarketKey): (u64, u64, u64) {
    if (vault.positions.contains(key)) {
        let data = vault.positions[key];
        (data.quantity, data.premiums, data.payouts)
    } else {
        (0, 0, 0)
    }
}

/// Returns (up_quantity, down_quantity) for the strike.
public fun pair_position<Quote>(vault: &Vault<Quote>, key: MarketKey): (u64, u64) {
    let up_key = if (key.is_up()) { key } else { key.opposite() };
    let down_key = up_key.opposite();
    (vault.position(up_key), vault.position(down_key))
}

/// Returns (max_exposure, min_exposure) for the strike.
public fun exposure<Quote>(vault: &Vault<Quote>, key: MarketKey): (u64, u64) {
    let (up, down) = vault.pair_position(key);
    if (up > down) { (up, down) } else { (down, up) }
}

// === Public-Package Functions ===

public(package) fun new<Quote>(ctx: &mut TxContext): Vault<Quote> {
    Vault {
        balance: balance::zero(),
        positions: table::new(ctx),
        max_liability: 0,
        min_liability: 0,
        cumulative_premiums: 0,
        cumulative_payouts: 0,
    }
}

public(package) fun increase_exposure<Quote>(
    vault: &mut Vault<Quote>,
    key: MarketKey,
    quantity: u64,
    payment: Coin<Quote>,
): u64 {
    let cost = payment.value();
    vault.balance.join(payment.into_balance());
    vault.cumulative_premiums = vault.cumulative_premiums + cost;

    let (old_max, old_min) = vault.exposure(key);
    vault.add_position(key, quantity, cost);
    let (new_max, new_min) = vault.exposure(key);
    vault.adjust_liability(old_max, new_max, old_min, new_min);

    cost
}

public(package) fun decrease_exposure<Quote>(
    vault: &mut Vault<Quote>,
    key: MarketKey,
    quantity: u64,
    payout: u64,
): Balance<Quote> {
    assert!(vault.balance.value() >= payout, EInsufficientBalance);
    vault.cumulative_payouts = vault.cumulative_payouts + payout;

    let (old_max, old_min) = vault.exposure(key);
    vault.remove_position(key, quantity, payout);
    let (new_max, new_min) = vault.exposure(key);
    vault.adjust_liability(old_max, new_max, old_min, new_min);

    vault.balance.split(payout)
}

// === Private Functions ===

fun add_position<Quote>(vault: &mut Vault<Quote>, key: MarketKey, quantity: u64, premium: u64) {
    if (vault.positions.contains(key)) {
        let data = &mut vault.positions[key];
        data.quantity = data.quantity + quantity;
        data.premiums = data.premiums + premium;
    } else {
        vault.positions.add(key, PositionData { quantity, premiums: premium, payouts: 0 });
    }
}

fun remove_position<Quote>(vault: &mut Vault<Quote>, key: MarketKey, quantity: u64, payout: u64) {
    assert!(vault.positions.contains(key), ENoShortPosition);
    let data = &mut vault.positions[key];
    data.quantity = data.quantity - quantity;
    data.payouts = data.payouts + payout;
}

fun adjust_liability<Quote>(
    vault: &mut Vault<Quote>,
    old_max: u64,
    new_max: u64,
    old_min: u64,
    new_min: u64,
) {
    vault.max_liability = vault.max_liability - old_max + new_max;
    vault.min_liability = vault.min_liability - old_min + new_min;
}
