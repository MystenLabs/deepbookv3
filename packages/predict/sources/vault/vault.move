// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Vault module - pure state machine for trade execution.
///
/// The vault holds USDC and takes the opposite side of every trade.
/// All pricing logic is handled by the orchestrator (predict.move).
///
/// Tracks aggregate short exposure (total_up_short, total_down_short)
/// instead of per-market positions. LP share pricing uses conservative
/// formula: balance - max_liability.
///
/// Scaling conventions (aligned with DeepBook):
/// - Quantities are in Quote units (USDC): 1_000_000 = 1 contract = $1 at settlement
/// - All liabilities (max_liability) are in Quote units
module deepbook_predict::vault;

use deepbook::math;
use deepbook_predict::supply_manager::{Self, SupplyManager};
use sui::{balance::{Self, Balance}, clock::Clock, coin::Coin};

// === Errors ===
const EInsufficientBalance: u64 = 1;
const EExceedsMaxTotalExposure: u64 = 2;

// === Structs ===

public struct Vault<phantom Quote> has store {
    /// USDC balance held by the vault
    balance: Balance<Quote>,
    /// Tracks LP shares and supply timestamps
    supply_manager: SupplyManager,
    /// Total UP contracts the vault is short
    total_up_short: u64,
    /// Total DOWN contracts the vault is short
    total_down_short: u64,
    /// Σ(quantity × strike) for UP positions — used to derive weighted-average strike
    sum_up_strike_qty: u128,
    /// Σ(quantity × strike) for DOWN positions — used to derive weighted-average strike
    sum_down_strike_qty: u128,
    /// Total collateralized contracts (not backed by vault)
    total_collateralized: u64,
    /// Worst-case payout: total_up_short + total_down_short
    /// Conservative bound since both sides can win at intermediate settlements
    max_liability: u64,
    /// Total premiums collected from traders
    cumulative_premiums: u64,
    /// Total payouts made to traders
    cumulative_payouts: u64,
}

// === Public Functions ===

public fun balance<Quote>(vault: &Vault<Quote>): u64 {
    vault.balance.value()
}

public fun max_liability<Quote>(vault: &Vault<Quote>): u64 {
    vault.max_liability
}

public fun cumulative_premiums<Quote>(vault: &Vault<Quote>): u64 {
    vault.cumulative_premiums
}

public fun cumulative_payouts<Quote>(vault: &Vault<Quote>): u64 {
    vault.cumulative_payouts
}

public fun total_up_short<Quote>(vault: &Vault<Quote>): u64 {
    vault.total_up_short
}

public fun total_down_short<Quote>(vault: &Vault<Quote>): u64 {
    vault.total_down_short
}

public fun total_collateralized<Quote>(vault: &Vault<Quote>): u64 {
    vault.total_collateralized
}

public fun sum_up_strike_qty<Quote>(vault: &Vault<Quote>): u128 {
    vault.sum_up_strike_qty
}

public fun sum_down_strike_qty<Quote>(vault: &Vault<Quote>): u128 {
    vault.sum_down_strike_qty
}

/// Returns (shares, last_supply_ms) for an owner.
public fun supply_data<Quote>(vault: &Vault<Quote>, owner: address): (u64, u64) {
    vault.supply_manager.supply_data(owner)
}

public fun total_shares<Quote>(vault: &Vault<Quote>): u64 {
    vault.supply_manager.total_shares()
}

// === Public-Package Functions ===

public(package) fun new<Quote>(ctx: &mut TxContext): Vault<Quote> {
    Vault {
        balance: balance::zero(),
        supply_manager: supply_manager::new(ctx),
        total_up_short: 0,
        total_down_short: 0,
        sum_up_strike_qty: 0,
        sum_down_strike_qty: 0,
        total_collateralized: 0,
        max_liability: 0,
        cumulative_premiums: 0,
        cumulative_payouts: 0,
    }
}

/// Execute a mint trade. Updates aggregate exposure and strike-weighted sums.
/// Cost calculation is done by the orchestrator.
public(package) fun execute_mint<Quote>(
    vault: &mut Vault<Quote>,
    is_up: bool,
    quantity: u64,
    strike: u64,
    payment: Coin<Quote>,
) {
    let cost = payment.value();
    vault.balance.join(payment.into_balance());
    vault.cumulative_premiums = vault.cumulative_premiums + cost;
    let strike_qty = (quantity as u128) * (strike as u128);
    if (is_up) {
        vault.total_up_short = vault.total_up_short + quantity;
        vault.sum_up_strike_qty = vault.sum_up_strike_qty + strike_qty;
    } else {
        vault.total_down_short = vault.total_down_short + quantity;
        vault.sum_down_strike_qty = vault.sum_down_strike_qty + strike_qty;
    };
    vault.recompute_max_liability();
}

/// Execute a redeem trade. Updates aggregate exposure and strike-weighted sums.
/// Payout calculation is done by the orchestrator.
public(package) fun execute_redeem<Quote>(
    vault: &mut Vault<Quote>,
    is_up: bool,
    quantity: u64,
    strike: u64,
    payout: u64,
): Balance<Quote> {
    assert!(vault.balance.value() >= payout, EInsufficientBalance);
    vault.cumulative_payouts = vault.cumulative_payouts + payout;
    let strike_qty = (quantity as u128) * (strike as u128);
    if (is_up) {
        vault.total_up_short = vault.total_up_short - quantity;
        vault.sum_up_strike_qty = vault.sum_up_strike_qty - strike_qty;
    } else {
        vault.total_down_short = vault.total_down_short - quantity;
        vault.sum_down_strike_qty = vault.sum_down_strike_qty - strike_qty;
    };
    vault.recompute_max_liability();
    vault.balance.split(payout)
}

/// Execute a collateralized mint. Only updates total_collateralized.
/// Does not affect vault risk since position is backed by collateral.
public(package) fun execute_mint_collateralized<Quote>(vault: &mut Vault<Quote>, quantity: u64) {
    vault.total_collateralized = vault.total_collateralized + quantity;
}

/// Execute a collateralized redeem. Only updates total_collateralized.
/// Does not affect vault risk since position was backed by collateral.
public(package) fun execute_redeem_collateralized<Quote>(vault: &mut Vault<Quote>, quantity: u64) {
    vault.total_collateralized = vault.total_collateralized - quantity;
}

/// Assert that total vault exposure is within risk limits.
public(package) fun assert_total_exposure<Quote>(vault: &Vault<Quote>, max_total_pct: u64) {
    let balance = vault.balance.value();
    assert!(vault.max_liability <= math::mul(balance, max_total_pct), EExceedsMaxTotalExposure);
}

/// Supply USDC to the vault, receive shares.
public(package) fun supply<Quote>(
    vault: &mut Vault<Quote>,
    coin: Coin<Quote>,
    clock: &Clock,
    ctx: &TxContext,
): u64 {
    let amount = coin.value();
    let vault_value = vault.vault_value();
    let shares = vault.supply_manager.supply(amount, vault_value, clock, ctx);
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
    let vault_value = vault.vault_value();
    let amount = vault.supply_manager.withdraw(shares, vault_value, lockup_period_ms, clock, ctx);

    vault.balance.split(amount)
}

// === Private Functions ===

/// Conservative vault value: balance - max_liability, floored at 0.
fun vault_value<Quote>(vault: &Vault<Quote>): u64 {
    let bal = vault.balance.value();
    if (bal > vault.max_liability) { bal - vault.max_liability } else { 0 }
}

fun recompute_max_liability<Quote>(vault: &mut Vault<Quote>) {
    vault.max_liability = vault.total_up_short + vault.total_down_short;
}
