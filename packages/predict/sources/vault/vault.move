// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Vault module - counterparty for all trades.
///
/// The vault holds USDC and takes the opposite side of every trade:
/// - When user mints UP position, vault receives USDC and is short UP
/// - When user mints DOWN position, vault receives USDC and is short DOWN
/// - When user redeems, vault pays out and closes its short
///
/// Two-step process for each trade:
/// 1. Execute trade: calculate cost/payout using pre-trade exposure, update position
/// 2. Mark-to-market: get prices using post-trade exposure, update unrealized liability
module deepbook_predict::vault;

use deepbook_predict::{market_key::MarketKey, oracle::Oracle, pricing::{Self, Pricing}};
use sui::{balance::{Self, Balance}, clock::Clock, coin::Coin, table::{Self, Table}};

// === Errors ===
const ENoShortPosition: u64 = 0;
const EInsufficientBalance: u64 = 1;
const EInsufficientPayment: u64 = 2;

// === Structs ===

public struct PositionData has copy, drop, store {
    quantity: u64,
    premiums: u64,
    payouts: u64,
    unrealized_cost: u64,
}

public struct Vault<phantom Quote> has store {
    balance: Balance<Quote>,
    positions: Table<MarketKey, PositionData>,
    pricing: Pricing,
    max_liability: u64,
    min_liability: u64,
    unrealized_liability: u64,
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

public fun unrealized_liability<Quote>(vault: &Vault<Quote>): u64 {
    vault.unrealized_liability
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

public fun position_data<Quote>(vault: &Vault<Quote>, key: MarketKey): (u64, u64, u64, u64) {
    if (vault.positions.contains(key)) {
        let data = vault.positions[key];
        (data.quantity, data.premiums, data.payouts, data.unrealized_cost)
    } else {
        (0, 0, 0, 0)
    }
}

/// Returns (up_quantity, down_quantity) for the strike.
public fun pair_position<Quote>(vault: &Vault<Quote>, key: MarketKey): (u64, u64) {
    let up_key = if (key.is_up()) { key } else { key.opposite() };
    let down_key = up_key.opposite();
    (vault.position(up_key), vault.position(down_key))
}

/// Estimate the cost to mint a position (for UI/preview).
public fun estimate_mint_cost<Underlying, Quote>(
    vault: &Vault<Quote>,
    oracle: &Oracle<Underlying>,
    key: &MarketKey,
    quantity: u64,
    clock: &Clock,
): u64 {
    let (up_short, down_short) = vault.pair_position(*key);
    vault.pricing.get_mint_cost(oracle, key, quantity, up_short, down_short, clock)
}

/// Estimate the payout for redeeming a position (for UI/preview).
public fun estimate_redeem_payout<Underlying, Quote>(
    vault: &Vault<Quote>,
    oracle: &Oracle<Underlying>,
    key: &MarketKey,
    quantity: u64,
    clock: &Clock,
): u64 {
    let (up_short, down_short) = vault.pair_position(*key);
    vault.pricing.get_redeem_payout(oracle, key, quantity, up_short, down_short, clock)
}

// === Public-Package Functions ===

public(package) fun new<Quote>(ctx: &mut TxContext): Vault<Quote> {
    Vault {
        balance: balance::zero(),
        positions: table::new(ctx),
        pricing: pricing::new(),
        max_liability: 0,
        min_liability: 0,
        unrealized_liability: 0,
        cumulative_premiums: 0,
        cumulative_payouts: 0,
    }
}

/// Mint a position. Two-step process:
/// 1. Calculate cost using pre-trade exposure, execute trade
/// 2. Mark-to-market using post-trade exposure
public(package) fun mint<Underlying, Quote>(
    vault: &mut Vault<Quote>,
    oracle: &Oracle<Underlying>,
    key: MarketKey,
    quantity: u64,
    payment: Coin<Quote>,
    clock: &Clock,
): u64 {
    // Step 1: Calculate cost using PRE-TRADE exposure
    let (up_short, down_short) = vault.pair_position(key);
    let cost = vault.pricing.get_mint_cost(oracle, &key, quantity, up_short, down_short, clock);
    assert!(payment.value() == cost, EInsufficientPayment);

    // Execute trade
    vault.balance.join(payment.into_balance());
    vault.cumulative_premiums = vault.cumulative_premiums + cost;

    // Update max/min liability
    let (old_max, old_min) = vault.exposure(key);
    vault.add_position(key, quantity, cost);
    let (new_max, new_min) = vault.exposure(key);
    vault.max_liability = vault.max_liability - old_max + new_max;
    vault.min_liability = vault.min_liability - old_min + new_min;

    // Step 2: Mark-to-market using POST-TRADE exposure
    vault.mark_to_market(oracle, key, clock);

    cost
}

/// Redeem a position. Two-step process:
/// 1. Calculate payout using pre-trade exposure, execute trade
/// 2. Mark-to-market using post-trade exposure
public(package) fun redeem<Underlying, Quote>(
    vault: &mut Vault<Quote>,
    oracle: &Oracle<Underlying>,
    key: MarketKey,
    quantity: u64,
    clock: &Clock,
): Balance<Quote> {
    // Step 1: Calculate payout using PRE-TRADE exposure
    let (up_short, down_short) = vault.pair_position(key);
    let payout = vault
        .pricing
        .get_redeem_payout(oracle, &key, quantity, up_short, down_short, clock);
    assert!(vault.balance.value() >= payout, EInsufficientBalance);

    // Execute trade
    vault.cumulative_payouts = vault.cumulative_payouts + payout;

    // Update max/min liability
    let (old_max, old_min) = vault.exposure(key);
    vault.remove_position(key, quantity, payout);
    let (new_max, new_min) = vault.exposure(key);
    vault.max_liability = vault.max_liability - old_max + new_max;
    vault.min_liability = vault.min_liability - old_min + new_min;

    // Step 2: Mark-to-market using POST-TRADE exposure
    vault.mark_to_market(oracle, key, clock);

    vault.balance.split(payout)
}

// === Private Functions ===

/// Returns (max_exposure, min_exposure) for the strike.
fun exposure<Quote>(vault: &Vault<Quote>, key: MarketKey): (u64, u64) {
    let (up, down) = vault.pair_position(key);
    if (up > down) { (up, down) } else { (down, up) }
}

/// Mark-to-market: compute cost to close each position and update unrealized_liability.
fun mark_to_market<Underlying, Quote>(
    vault: &mut Vault<Quote>,
    oracle: &Oracle<Underlying>,
    key: MarketKey,
    clock: &Clock,
) {
    let up_key = if (key.is_up()) { key } else { key.opposite() };
    let down_key = up_key.opposite();

    // Old unrealized from stored values
    let old_up = if (vault.positions.contains(up_key)) { vault.positions[up_key].unrealized_cost }
    else { 0 };
    let old_down = if (vault.positions.contains(down_key)) {
        vault.positions[down_key].unrealized_cost
    } else { 0 };

    // New unrealized using get_mint_cost
    let (up_qty, down_qty) = vault.pair_position(key);
    let new_up = vault.pricing.get_mint_cost(oracle, &up_key, up_qty, up_qty, down_qty, clock);
    let new_down = vault
        .pricing
        .get_mint_cost(oracle, &down_key, down_qty, up_qty, down_qty, clock);

    // Update stored values
    if (vault.positions.contains(up_key)) { vault.positions[up_key].unrealized_cost = new_up; };
    if (vault.positions.contains(down_key)) {
        vault.positions[down_key].unrealized_cost = new_down;
    };

    // Update aggregate
    vault.unrealized_liability = vault.unrealized_liability - old_up - old_down + new_up + new_down;
}

fun add_position<Quote>(vault: &mut Vault<Quote>, key: MarketKey, quantity: u64, premium: u64) {
    if (vault.positions.contains(key)) {
        let data = &mut vault.positions[key];
        data.quantity = data.quantity + quantity;
        data.premiums = data.premiums + premium;
    } else {
        vault
            .positions
            .add(
                key,
                PositionData {
                    quantity,
                    premiums: premium,
                    payouts: 0,
                    unrealized_cost: 0,
                },
            );
    }
}

fun remove_position<Quote>(vault: &mut Vault<Quote>, key: MarketKey, quantity: u64, payout: u64) {
    assert!(vault.positions.contains(key), ENoShortPosition);
    let data = &mut vault.positions[key];
    data.quantity = data.quantity - quantity;
    data.payouts = data.payouts + payout;
}
