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
use deepbook_predict::{math as predict_math, supply_manager::{Self, SupplyManager}};
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
    /// Σ(quantity × strike) for UP positions — used to derive weighted-average strike (signed)
    sum_up_strike_qty: u64,
    sum_up_strike_qty_negative: bool,
    /// Σ(quantity × strike) for DOWN positions — used to derive weighted-average strike (signed)
    sum_down_strike_qty: u64,
    sum_down_strike_qty_negative: bool,
    /// Total collateralized contracts (not backed by vault)
    total_collateralized: u64,
}

// === Public Functions ===

public fun balance<Quote>(vault: &Vault<Quote>): u64 {
    vault.balance.value()
}

public fun max_liability<Quote>(vault: &Vault<Quote>): u64 {
    vault.total_up_short + vault.total_down_short
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

public fun sum_up_strike_qty<Quote>(vault: &Vault<Quote>): (u64, bool) {
    (vault.sum_up_strike_qty, vault.sum_up_strike_qty_negative)
}

public fun sum_down_strike_qty<Quote>(vault: &Vault<Quote>): (u64, bool) {
    (vault.sum_down_strike_qty, vault.sum_down_strike_qty_negative)
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
        sum_up_strike_qty_negative: false,
        sum_down_strike_qty: 0,
        sum_down_strike_qty_negative: false,
        total_collateralized: 0,
    }
}

/// Execute a mint trade. Updates aggregate exposure and strike-weighted sums.
/// Cost calculation is done by the orchestrator.
public(package) fun execute_mint<Quote>(
    vault: &mut Vault<Quote>,
    is_up: bool,
    strike: u64,
    quantity: u64,
    payment: Coin<Quote>,
) {
    vault.balance.join(payment.into_balance());
    let strike_qty = math::mul(quantity, strike);
    if (is_up) {
        vault.total_up_short = vault.total_up_short + quantity;
        let (new_sum, new_neg) = predict_math::add_signed_u64(
            vault.sum_up_strike_qty,
            vault.sum_up_strike_qty_negative,
            strike_qty,
            false,
        );
        vault.sum_up_strike_qty = new_sum;
        vault.sum_up_strike_qty_negative = new_neg;
    } else {
        vault.total_down_short = vault.total_down_short + quantity;
        let (new_sum, new_neg) = predict_math::add_signed_u64(
            vault.sum_down_strike_qty,
            vault.sum_down_strike_qty_negative,
            strike_qty,
            false,
        );
        vault.sum_down_strike_qty = new_sum;
        vault.sum_down_strike_qty_negative = new_neg;
    };
}

/// Execute a redeem trade. Updates aggregate exposure and strike-weighted sums.
/// Payout calculation is done by the orchestrator.
public(package) fun execute_redeem<Quote>(
    vault: &mut Vault<Quote>,
    is_up: bool,
    strike: u64,
    quantity: u64,
    payout: u64,
): Balance<Quote> {
    assert!(vault.balance.value() >= payout, EInsufficientBalance);
    let strike_qty = math::mul(quantity, strike);
    if (is_up) {
        vault.total_up_short = vault.total_up_short - quantity;
        let (new_sum, new_neg) = predict_math::sub_signed_u64(
            vault.sum_up_strike_qty,
            vault.sum_up_strike_qty_negative,
            strike_qty,
            false,
        );
        vault.sum_up_strike_qty = new_sum;
        vault.sum_up_strike_qty_negative = new_neg;
    } else {
        vault.total_down_short = vault.total_down_short - quantity;
        let (new_sum, new_neg) = predict_math::sub_signed_u64(
            vault.sum_down_strike_qty,
            vault.sum_down_strike_qty_negative,
            strike_qty,
            false,
        );
        vault.sum_down_strike_qty = new_sum;
        vault.sum_down_strike_qty_negative = new_neg;
    };
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
    assert!(vault.max_liability() <= math::mul(balance, max_total_pct), EExceedsMaxTotalExposure);
}

/// Supply USDC to the vault, receive shares.
/// `vault_value` is the expected NAV computed by the orchestrator.
public(package) fun supply<Quote>(
    vault: &mut Vault<Quote>,
    coin: Coin<Quote>,
    vault_value: u64,
    clock: &Clock,
    ctx: &TxContext,
): u64 {
    let amount = coin.value();
    let shares = vault.supply_manager.supply(amount, vault_value, clock, ctx);
    vault.balance.join(coin.into_balance());

    shares
}

/// Withdraw USDC from the vault by burning shares.
/// `vault_value` is the expected NAV computed by the orchestrator.
public(package) fun withdraw<Quote>(
    vault: &mut Vault<Quote>,
    shares: u64,
    vault_value: u64,
    lockup_period_ms: u64,
    clock: &Clock,
    ctx: &TxContext,
): Balance<Quote> {
    let amount = vault.supply_manager.withdraw(shares, vault_value, lockup_period_ms, clock, ctx);

    vault.balance.split(amount)
}
