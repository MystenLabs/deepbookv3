// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Vault module - counterparty for all trades.
///
/// The vault holds USDC and takes the opposite side of every trade:
/// - When user mints UP position, vault receives USDC and is short UP
/// - When user mints DOWN position, vault receives USDC and is short DOWN
/// - When user redeems, vault pays out and closes its short
///
/// Position tracking:
/// - `positions` maps MarketKey to vault's short quantity
/// - Net exposure is calculated by comparing UP vs DOWN shorts at the same strike
///
/// Invariant: balance >= max_liability (max of UP shorts vs DOWN shorts per strike * $1)
module deepbook_predict::vault;

use deepbook_predict::{constants, market_key::MarketKey};
use sui::{balance::{Self, Balance}, coin::Coin, table::{Self, Table}};

// === Errors ===
const ENoShortPosition: u64 = 0;

// === Structs ===

/// Vault holding USDC and tracking short positions.
public struct Vault<phantom Quote> has store {
    balance: Balance<Quote>,
    positions: Table<MarketKey, u64>,
    max_liability: u64,
}

// === Public Functions ===

public fun balance<Quote>(vault: &Vault<Quote>): u64 {
    vault.balance.value()
}

public fun max_liability<Quote>(vault: &Vault<Quote>): u64 {
    vault.max_liability
}

public fun available_balance<Quote>(vault: &Vault<Quote>): u64 {
    let balance = vault.balance.value();
    if (balance > vault.max_liability) { balance - vault.max_liability } else { 0 }
}

public fun position<Quote>(vault: &Vault<Quote>, key: MarketKey): u64 {
    if (vault.positions.contains(key)) { vault.positions[key] } else { 0 }
}

public fun pair_position<Quote>(vault: &Vault<Quote>, key: MarketKey): (u64, u64) {
    let up_key = if (key.is_up()) { key } else { key.opposite() };
    let down_key = up_key.opposite();
    (vault.position(up_key), vault.position(down_key))
}

public fun net_exposure<Quote>(vault: &Vault<Quote>, key: MarketKey): u64 {
    let (up, down) = vault.pair_position(key);
    abs_diff(up, down)
}

// === Public-Package Functions ===

public(package) fun new<Quote>(ctx: &mut TxContext): Vault<Quote> {
    Vault {
        balance: balance::zero(),
        positions: table::new(ctx),
        max_liability: 0,
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

    let old_net = vault.net_exposure(key);
    vault.add_position(key, quantity);
    let new_net = vault.net_exposure(key);
    vault.adjust_liability(old_net, new_net);

    cost
}

public(package) fun decrease_exposure<Quote>(
    vault: &mut Vault<Quote>,
    key: MarketKey,
    quantity: u64,
    quote_out: u64,
): Balance<Quote> {
    let old_net = vault.net_exposure(key);
    vault.remove_position(key, quantity);
    let new_net = vault.net_exposure(key);
    vault.adjust_liability(old_net, new_net);

    vault.balance.split(quote_out)
}

// === Private Functions ===

fun add_position<Quote>(vault: &mut Vault<Quote>, key: MarketKey, quantity: u64) {
    if (vault.positions.contains(key)) {
        let current = &mut vault.positions[key];
        *current = *current + quantity;
    } else {
        vault.positions.add(key, quantity);
    }
}

fun remove_position<Quote>(vault: &mut Vault<Quote>, key: MarketKey, quantity: u64) {
    assert!(vault.positions.contains(key), ENoShortPosition);
    let current = &mut vault.positions[key];
    *current = *current - quantity;
}

fun adjust_liability<Quote>(vault: &mut Vault<Quote>, old_net: u64, new_net: u64) {
    let price = constants::price_scaling();
    if (new_net > old_net) {
        vault.max_liability = vault.max_liability + ((new_net - old_net) * price);
    } else {
        vault.max_liability = vault.max_liability - ((old_net - new_net) * price);
    }
}

fun abs_diff(a: u64, b: u64): u64 {
    if (a > b) { a - b } else { b - a }
}
