// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Vault module - pure state machine for trade execution.
///
/// The vault holds accepted quote assets and takes the opposite side of every trade.
/// All pricing logic is handled by the orchestrator (predict.move).
///
/// Tracks mark-to-market liability via per-oracle strike matrices and a cached
/// global total_mtm, refreshed on every trade.
///
/// Scaling conventions (aligned with DeepBook):
/// - Quantities are in quote units: 1_000_000 = 1 contract = $1 at settlement
module deepbook_predict::vault;

use deepbook::math;
use deepbook_predict::{oracle_config::CurvePoint, strike_matrix::{Self, StrikeMatrix}};
use sui::{bag::{Self, Bag}, balance::Balance, table::{Self, Table}};

// === Errors ===
const EInsufficientBalance: u64 = 0;
const EExceedsMaxTotalExposure: u64 = 1;
const EOracleExposureNotFound: u64 = 2;
const EMtmExceedsBalance: u64 = 3;
const EAssetNotInVault: u64 = 4;

// === Structs ===

/// Dynamic bag key for storing a concrete asset balance by type.
public struct BalanceKey<phantom T> has copy, drop, store {}

public struct Vault has store {
    /// Concrete balances stored per accepted quote asset type.
    balances: Bag,
    /// Shared treasury balance tracked in quote units.
    balance: u64,
    /// Per-oracle matrix for strike-level position tracking.
    oracle_matrices: Table<ID, StrikeMatrix>,
    /// Sum of all oracle matrix MTM values.
    total_mtm: u64,
    /// Sum of all oracle matrix max payout values.
    total_max_payout: u64,
}

// === Public Functions ===

public fun balance(vault: &Vault): u64 {
    vault.balance
}

public fun asset_balance<T>(vault: &Vault): u64 {
    let key = BalanceKey<T> {};
    if (vault.balances.contains(key)) {
        let balance: &Balance<T> = &vault.balances[key];
        balance.value()
    } else {
        0
    }
}

public fun total_mtm(vault: &Vault): u64 {
    vault.total_mtm
}

public fun vault_value(vault: &Vault): u64 {
    assert!(vault.balance >= vault.total_mtm, EMtmExceedsBalance);
    vault.balance - vault.total_mtm
}

public fun total_max_payout(vault: &Vault): u64 {
    vault.total_max_payout
}

// === Public-Package Functions ===

public(package) fun new(ctx: &mut TxContext): Vault {
    Vault {
        balances: bag::new(ctx),
        balance: 0,
        oracle_matrices: table::new(ctx),
        total_mtm: 0,
        total_max_payout: 0,
    }
}

/// Allocate one zeroed strike matrix for an oracle's configured strike grid.
public(package) fun init_oracle_matrix(
    vault: &mut Vault,
    oracle_id: ID,
    min_strike: u64,
    max_strike: u64,
    tick_size: u64,
    ctx: &mut TxContext,
) {
    if (!vault.oracle_matrices.contains(oracle_id)) {
        vault
            .oracle_matrices
            .add(
                oracle_id,
                strike_matrix::new(ctx, tick_size, min_strike, max_strike),
            );
    };
}

/// Insert a position into the per-oracle exposure structure and update cached max payout.
public(package) fun insert_position(
    vault: &mut Vault,
    oracle_id: ID,
    is_up: bool,
    strike: u64,
    quantity: u64,
) {
    assert!(vault.oracle_matrices.contains(oracle_id), EOracleExposureNotFound);
    let old_max_payout = vault.oracle_matrices[oracle_id].max_payout();
    vault.oracle_matrices[oracle_id].insert(strike, quantity, is_up);
    let new_max_payout = vault.oracle_matrices[oracle_id].max_payout();
    vault.total_max_payout = vault.total_max_payout + new_max_payout - old_max_payout;
}

/// Insert a vertical spread into the per-oracle exposure structure and update
/// cached max payout. The spread is recorded as `long UP@lower + long DN@higher`
/// plus a `quantity` cashback delta; the vault's `total_max_payout` reflects the
/// cashback-adjusted (net) contribution.
public(package) fun insert_spread(
    vault: &mut Vault,
    oracle_id: ID,
    lower: u64,
    higher: u64,
    quantity: u64,
) {
    assert!(vault.oracle_matrices.contains(oracle_id), EOracleExposureNotFound);
    let old_net_max_payout = net_max_payout(&vault.oracle_matrices[oracle_id]);
    vault.oracle_matrices[oracle_id].insert_spread(lower, higher, quantity);
    let new_net_max_payout = net_max_payout(&vault.oracle_matrices[oracle_id]);
    vault.total_max_payout = vault.total_max_payout + new_net_max_payout - old_net_max_payout;
}

/// Accept payment into vault balance.
public(package) fun accept_payment<T>(vault: &mut Vault, payment: Balance<T>) {
    let amount = payment.value();
    vault.deposit_balance(payment);
    vault.balance = vault.balance + amount;
}

/// Remove a position from the strike matrix.
public(package) fun remove_position(
    vault: &mut Vault,
    oracle_id: ID,
    is_up: bool,
    strike: u64,
    quantity: u64,
) {
    assert!(vault.oracle_matrices.contains(oracle_id), EOracleExposureNotFound);
    let old_max_payout = vault.oracle_matrices[oracle_id].max_payout();
    vault.oracle_matrices[oracle_id].remove(strike, quantity, is_up);
    let new_max_payout = vault.oracle_matrices[oracle_id].max_payout();
    vault.total_max_payout = vault.total_max_payout + new_max_payout - old_max_payout;
}

/// Remove a vertical spread from the per-oracle exposure structure and update
/// cached max payout. Symmetric to `insert_spread`.
public(package) fun remove_spread(
    vault: &mut Vault,
    oracle_id: ID,
    lower: u64,
    higher: u64,
    quantity: u64,
) {
    assert!(vault.oracle_matrices.contains(oracle_id), EOracleExposureNotFound);
    let old_net_max_payout = net_max_payout(&vault.oracle_matrices[oracle_id]);
    vault.oracle_matrices[oracle_id].remove_spread(lower, higher, quantity);
    let new_net_max_payout = net_max_payout(&vault.oracle_matrices[oracle_id]);
    vault.total_max_payout = vault.total_max_payout + new_net_max_payout - old_net_max_payout;
}

/// Dispense payout from vault balance.
public(package) fun dispense_payout<T>(vault: &mut Vault, amount: u64): Balance<T> {
    let payout = vault.withdraw_balance<T>(amount);
    vault.balance = vault.balance - amount;
    payout
}

/// Assert that total vault exposure is within risk limits.
public(package) fun assert_total_exposure(vault: &Vault, max_total_pct: u64) {
    assert!(vault.total_mtm <= math::mul(vault.balance, max_total_pct), EExceedsMaxTotalExposure);
}

/// Return the historical minted strike bounds for this oracle's matrix.
/// These bounds expand on insert and do not shrink after positions are removed.
public(package) fun oracle_strike_range(vault: &Vault, oracle_id: ID): (u64, u64) {
    assert!(vault.oracle_matrices.contains(oracle_id), EOracleExposureNotFound);
    let matrix = &vault.oracle_matrices[oracle_id];
    matrix.minted_strike_range()
}

public(package) fun set_mtm_with_curve(
    vault: &mut Vault,
    oracle_id: ID,
    curve: &vector<CurvePoint>,
) {
    assert!(vault.oracle_matrices.contains(oracle_id), EOracleExposureNotFound);

    let matrix = &vault.oracle_matrices[oracle_id];
    let old_mtm = matrix.mtm();
    let new_mtm = matrix.evaluate(curve) - matrix.cashback();

    let matrix = &mut vault.oracle_matrices[oracle_id];
    matrix.set_mtm(new_mtm);
    vault.total_mtm = vault.total_mtm + new_mtm - old_mtm;
}

public(package) fun set_mtm_with_settlement(vault: &mut Vault, oracle_id: ID, settlement: u64) {
    assert!(vault.oracle_matrices.contains(oracle_id), EOracleExposureNotFound);

    let matrix = &vault.oracle_matrices[oracle_id];
    let old_mtm = matrix.mtm();
    let new_mtm = matrix.evaluate_settled(settlement) - matrix.cashback();

    let matrix = &mut vault.oracle_matrices[oracle_id];
    matrix.set_mtm(new_mtm);
    vault.total_mtm = vault.total_mtm + new_mtm - old_mtm;
}

public(package) fun set_mtm(vault: &mut Vault, oracle_id: ID, mtm: u64) {
    assert!(vault.oracle_matrices.contains(oracle_id), EOracleExposureNotFound);

    let old_mtm = vault.oracle_matrices[oracle_id].mtm();
    vault.oracle_matrices[oracle_id].set_mtm(mtm);
    vault.total_mtm = vault.total_mtm + mtm - old_mtm;
}

/// Per-matrix max payout net of the cashback contributed by spread mints.
fun net_max_payout(matrix: &StrikeMatrix): u64 {
    matrix.max_payout() - matrix.cashback()
}

fun deposit_balance<T>(vault: &mut Vault, payment: Balance<T>) {
    let key = BalanceKey<T> {};
    if (vault.balances.contains(key)) {
        let balance: &mut Balance<T> = &mut vault.balances[key];
        balance.join(payment);
    } else {
        vault.balances.add(key, payment);
    }
}

fun withdraw_balance<T>(vault: &mut Vault, amount: u64): Balance<T> {
    let key = BalanceKey<T> {};
    assert!(vault.balances.contains(key), EAssetNotInVault);
    let balance: &mut Balance<T> = &mut vault.balances[key];
    assert!(balance.value() >= amount, EInsufficientBalance);
    balance.split(amount)
}
