// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Vault module - counterparty for all trades.
///
/// Scaling conventions (aligned with DeepBook):
/// - Quantities are in Quote units (USDC): 1_000_000 = 1 contract = $1 at settlement
/// - All liabilities (max, min, unrealized) are in Quote units
/// - At settlement, winners receive `quantity` directly (no multiplication needed)
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

use deepbook_predict::{
    market_key::MarketKey,
    oracle::Oracle,
    pricing::Pricing,
    supply_manager::{Self, SupplyManager}
};
use sui::{balance::{Self, Balance}, clock::Clock, coin::Coin, table::{Self, Table}};

// === Errors ===
const ENoShortPosition: u64 = 0;
const EInsufficientBalance: u64 = 1;
const EInsufficientPayment: u64 = 2;
const EMarketNotSettled: u64 = 3;

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
    supply_manager: SupplyManager,
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

public fun shares<Quote>(vault: &Vault<Quote>, owner: address): u64 {
    vault.supply_manager.shares(owner)
}

public fun total_shares<Quote>(vault: &Vault<Quote>): u64 {
    vault.supply_manager.total_shares()
}

public fun position<Quote>(vault: &Vault<Quote>, key: MarketKey): u64 {
    if (vault.positions.contains(key)) {
        vault.positions[key].quantity
    } else {
        0
    }
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
    let (up_key, down_key) = key.up_down_pair();
    (vault.position(up_key), vault.position(down_key))
}

/// Get the cost to mint a position (for UI/preview).
public fun get_mint_cost<Underlying, Quote>(
    vault: &Vault<Quote>,
    pricing: &Pricing,
    oracle: &Oracle<Underlying>,
    key: MarketKey,
    quantity: u64,
    clock: &Clock,
): u64 {
    let (up_short, down_short) = vault.pair_position(key);
    pricing.get_mint_cost(oracle, key, quantity, up_short, down_short, clock)
}

/// Get the payout for redeeming a position (for UI/preview).
public fun get_redeem_payout<Underlying, Quote>(
    vault: &Vault<Quote>,
    pricing: &Pricing,
    oracle: &Oracle<Underlying>,
    key: MarketKey,
    quantity: u64,
    clock: &Clock,
): u64 {
    let (up_short, down_short) = vault.pair_position(key);
    pricing.get_redeem_payout(oracle, key, quantity, up_short, down_short, clock)
}

// === Public-Package Functions ===

public(package) fun new<Quote>(ctx: &mut TxContext): Vault<Quote> {
    Vault {
        balance: balance::zero(),
        positions: table::new(ctx),
        supply_manager: supply_manager::new(ctx),
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
    pricing: &Pricing,
    oracle: &Oracle<Underlying>,
    key: MarketKey,
    quantity: u64,
    payment: Coin<Quote>,
    clock: &Clock,
): u64 {
    // Step 1: Calculate cost using PRE-TRADE exposure
    let (up_short, down_short) = vault.pair_position(key);
    let cost = pricing.get_mint_cost(oracle, key, quantity, up_short, down_short, clock);
    assert!(payment.value() == cost, EInsufficientPayment);

    // Execute trade
    vault.balance.join(payment.into_balance());
    vault.cumulative_premiums = vault.cumulative_premiums + cost;

    // Update max/min liability
    let (old_max, old_min) = vault.exposure(key);
    vault.add_position(key, quantity, cost);
    let (new_max, new_min) = vault.exposure(key);
    vault.max_liability = vault.max_liability + new_max - old_max;
    vault.min_liability = vault.min_liability + new_min - old_min;

    // Step 2: Mark-to-market using POST-TRADE exposure
    vault.mark_to_market(pricing, oracle, key, clock);

    cost
}

/// Redeem a position. Two-step process:
/// 1. Calculate payout using pre-trade exposure, execute trade
/// 2. Mark-to-market using post-trade exposure
public(package) fun redeem<Underlying, Quote>(
    vault: &mut Vault<Quote>,
    pricing: &Pricing,
    oracle: &Oracle<Underlying>,
    key: MarketKey,
    quantity: u64,
    clock: &Clock,
): Balance<Quote> {
    // Step 1: Calculate payout using PRE-TRADE exposure
    let (up_short, down_short) = vault.pair_position(key);
    let payout = pricing.get_redeem_payout(oracle, key, quantity, up_short, down_short, clock);
    assert!(vault.balance.value() >= payout, EInsufficientBalance);

    // Execute trade
    vault.cumulative_payouts = vault.cumulative_payouts + payout;

    // Update max/min liability
    let (old_max, old_min) = vault.exposure(key);
    vault.remove_position(key, quantity, payout);
    let (new_max, new_min) = vault.exposure(key);
    vault.max_liability = vault.max_liability + new_max - old_max;
    vault.min_liability = vault.min_liability + new_min - old_min;

    // Step 2: Mark-to-market using POST-TRADE exposure
    vault.mark_to_market(pricing, oracle, key, clock);

    vault.balance.split(payout)
}

/// Settle a market after expiry. Updates vault accounting to reflect actual outcome.
/// Idempotent - calling multiple times has no effect after first call.
public(package) fun settle<Underlying, Quote>(
    vault: &mut Vault<Quote>,
    pricing: &Pricing,
    oracle: &Oracle<Underlying>,
    key: MarketKey,
    clock: &Clock,
) {
    assert!(oracle.is_settled(), EMarketNotSettled);

    // mark_to_market uses get_quote which returns settlement prices (100%/0%) when settled
    vault.mark_to_market(pricing, oracle, key, clock);

    let (up_qty, down_qty) = vault.pair_position(key);
    let (old_max, old_min) = if (up_qty > down_qty) { (up_qty, down_qty) } else {
        (down_qty, up_qty)
    };

    // Update max/min liability: after settlement, actual = winning side's quantity
    let settlement_price = oracle.settlement_price().destroy_some();
    let up_wins = settlement_price > key.strike();
    let actual_liability = if (up_wins) { up_qty } else { down_qty };

    vault.max_liability = vault.max_liability + actual_liability - old_max;
    vault.min_liability = vault.min_liability + actual_liability - old_min;
}

/// Supply USDC to the vault, receive shares.
public(package) fun supply<Quote>(
    vault: &mut Vault<Quote>,
    coin: Coin<Quote>,
    ctx: &TxContext,
): u64 {
    let amount = coin.value();
    let shares = vault
        .supply_manager
        .supply(amount, vault.balance.value(), vault.unrealized_liability, ctx);
    vault.balance.join(coin.into_balance());

    shares
}

/// Withdraw USDC from the vault by burning shares.
public(package) fun withdraw<Quote>(
    vault: &mut Vault<Quote>,
    shares: u64,
    ctx: &TxContext,
): Balance<Quote> {
    let amount = vault
        .supply_manager
        .withdraw(shares, vault.balance.value(), vault.unrealized_liability, ctx);

    vault.balance.split(amount)
}

// === Private Functions ===

/// Returns (max_exposure, min_exposure) for the strike.
fun exposure<Quote>(vault: &Vault<Quote>, key: MarketKey): (u64, u64) {
    let (up, down) = vault.pair_position(key);
    if (up > down) {
        (up, down)
    } else {
        (down, up)
    }
}

/// Mark-to-market: compute cost to close each position and update unrealized_liability.
fun mark_to_market<Underlying, Quote>(
    vault: &mut Vault<Quote>,
    pricing: &Pricing,
    oracle: &Oracle<Underlying>,
    key: MarketKey,
    clock: &Clock,
) {
    let (up_key, down_key) = key.up_down_pair();

    // New unrealized using get_mint_cost
    let (up_qty, down_qty) = vault.pair_position(key);
    let new_up = pricing.get_mint_cost(oracle, up_key, up_qty, up_qty, down_qty, clock);
    let new_down = pricing.get_mint_cost(oracle, down_key, down_qty, up_qty, down_qty, clock);

    // Update stored values
    vault.update_unrealized_liability(up_key, new_up);
    vault.update_unrealized_liability(down_key, new_down);
}

fun update_unrealized_liability<Quote>(
    vault: &mut Vault<Quote>,
    key: MarketKey,
    new_unrealized: u64,
) {
    vault.add_position_entry(key);
    let old_unrealized = vault.positions[key].unrealized_cost;
    vault.positions[key].unrealized_cost = new_unrealized;
    vault.unrealized_liability = vault.unrealized_liability + new_unrealized - old_unrealized;
}

fun add_position<Quote>(vault: &mut Vault<Quote>, key: MarketKey, quantity: u64, premium: u64) {
    vault.add_position_entry(key);
    let data = &mut vault.positions[key];
    data.quantity = data.quantity + quantity;
    data.premiums = data.premiums + premium;
}

fun remove_position<Quote>(vault: &mut Vault<Quote>, key: MarketKey, quantity: u64, payout: u64) {
    assert!(vault.positions.contains(key), ENoShortPosition);
    let data = &mut vault.positions[key];
    data.quantity = data.quantity - quantity;
    data.payouts = data.payouts + payout;
}

fun add_position_entry<Quote>(vault: &mut Vault<Quote>, key: MarketKey) {
    if (!vault.positions.contains(key)) {
        vault
            .positions
            .add(
                key,
                PositionData {
                    quantity: 0,
                    premiums: 0,
                    payouts: 0,
                    unrealized_cost: 0,
                },
            );
    };
}
