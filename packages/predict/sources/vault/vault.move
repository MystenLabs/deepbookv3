// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Vault module - pure state machine for trade execution.
///
/// The vault holds USDC and takes the opposite side of every trade.
/// All pricing logic is handled by the orchestrator (predict.move).
///
/// Scaling conventions (aligned with DeepBook):
/// - Quantities are in Quote units (USDC): 1_000_000 = 1 contract = $1 at settlement
/// - All liabilities (max, min, unrealized) are in Quote units
module deepbook_predict::vault;

use deepbook_predict::{market_key::MarketKey, supply_manager::{Self, SupplyManager}};
use sui::{balance::{Self, Balance}, clock::Clock, coin::Coin, table::{Self, Table}};

// === Errors ===
const ENoShortPosition: u64 = 0;
const EInsufficientBalance: u64 = 1;

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

/// Returns (shares, last_supply_ms) for an owner.
public fun supply_data<Quote>(vault: &Vault<Quote>, owner: address): (u64, u64) {
    vault.supply_manager.supply_data(owner)
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

/// Execute a mint trade. Updates positions and liabilities.
/// Cost calculation is done by the orchestrator.
public(package) fun execute_mint<Quote>(
    vault: &mut Vault<Quote>,
    key: MarketKey,
    quantity: u64,
    payment: Coin<Quote>,
) {
    let cost = payment.value();

    // Execute trade
    vault.balance.join(payment.into_balance());
    vault.cumulative_premiums = vault.cumulative_premiums + cost;

    // Update max/min liability
    let (old_max, old_min) = vault.exposure(key);
    vault.add_position(key, quantity, cost);
    let (new_max, new_min) = vault.exposure(key);
    vault.max_liability = vault.max_liability + new_max - old_max;
    vault.min_liability = vault.min_liability + new_min - old_min;
}

/// Execute a redeem trade. Updates positions and liabilities.
/// Payout calculation is done by the orchestrator.
public(package) fun execute_redeem<Quote>(
    vault: &mut Vault<Quote>,
    key: MarketKey,
    quantity: u64,
    payout: u64,
): Balance<Quote> {
    assert!(vault.balance.value() >= payout, EInsufficientBalance);

    // Execute trade
    vault.cumulative_payouts = vault.cumulative_payouts + payout;

    // Update max/min liability
    let (old_max, old_min) = vault.exposure(key);
    vault.remove_position(key, quantity, payout);
    let (new_max, new_min) = vault.exposure(key);
    vault.max_liability = vault.max_liability + new_max - old_max;
    vault.min_liability = vault.min_liability + new_min - old_min;

    vault.balance.split(payout)
}

/// Update unrealized liability for a position.
/// Called by orchestrator after calculating new cost via pricing.
public(package) fun update_unrealized<Quote>(
    vault: &mut Vault<Quote>,
    key: MarketKey,
    new_unrealized: u64,
) {
    vault.add_position_entry(key);
    let old_unrealized = vault.positions[key].unrealized_cost;
    vault.positions[key].unrealized_cost = new_unrealized;
    vault.unrealized_liability = vault.unrealized_liability + new_unrealized - old_unrealized;
}

/// Finalize settlement by updating max/min liability to actual.
/// Called by orchestrator after mark-to-market.
public(package) fun finalize_settlement<Quote>(
    vault: &mut Vault<Quote>,
    key: MarketKey,
    up_wins: bool,
) {
    let (up_qty, down_qty) = vault.pair_position(key);
    let (old_max, old_min) = if (up_qty > down_qty) {
        (up_qty, down_qty)
    } else {
        (down_qty, up_qty)
    };

    let actual_liability = if (up_wins) { up_qty } else { down_qty };

    vault.max_liability = vault.max_liability + actual_liability - old_max;
    vault.min_liability = vault.min_liability + actual_liability - old_min;
}

/// Supply USDC to the vault, receive shares.
public(package) fun supply<Quote>(
    vault: &mut Vault<Quote>,
    coin: Coin<Quote>,
    clock: &Clock,
    ctx: &TxContext,
): u64 {
    let amount = coin.value();
    let shares = vault
        .supply_manager
        .supply(amount, vault.balance.value(), vault.unrealized_liability, clock, ctx);
    vault.balance.join(coin.into_balance());

    shares
}

/// Withdraw USDC from the vault by burning shares.
public(package) fun withdraw<Quote>(
    vault: &mut Vault<Quote>,
    shares: u64,
    lockup_period_ms: u64,
    clock: &Clock,
    ctx: &TxContext,
): Balance<Quote> {
    let amount = vault
        .supply_manager
        .withdraw(
            shares,
            vault.balance.value(),
            vault.unrealized_liability,
            lockup_period_ms,
            clock,
            ctx,
        );

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
