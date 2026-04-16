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

use fun net_max_payout as StrikeMatrix.net_max_payout;

// === Errors ===
const EInsufficientBalance: u64 = 0;
const EExceedsMaxTotalExposure: u64 = 1;
const EOracleExposureNotFound: u64 = 2;
const EMtmExceedsBalance: u64 = 3;
const EAssetNotInVault: u64 = 4;

// === Structs ===

/// Dynamic bag key for storing a concrete asset balance by type.
public struct BalanceKey<phantom T> has copy, drop, store {}

public struct SettledOracleState has copy, drop, store {
    remaining_quantity: u64,
    remaining_liability: u64,
}

public struct Vault has store {
    /// Concrete balances stored per accepted quote asset type.
    balances: Bag,
    /// Shared treasury balance tracked in quote units.
    balance: u64,
    /// Per-oracle matrix for strike-level position tracking.
    oracle_matrices: Table<ID, StrikeMatrix>,
    /// Per-oracle compact state used after settlement compaction.
    settled_oracles: Table<ID, SettledOracleState>,
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
        settled_oracles: table::new(ctx),
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

/// Insert a vertical range into the per-oracle exposure structure and update
/// cached max payout. The range is recorded as `long UP@lower + long DN@higher`
/// plus a `quantity` range_qty delta; the vault's `total_max_payout` reflects the
/// range_qty-adjusted (net) contribution.
public(package) fun insert_range(
    vault: &mut Vault,
    oracle_id: ID,
    lower: u64,
    higher: u64,
    quantity: u64,
) {
    assert!(vault.oracle_matrices.contains(oracle_id), EOracleExposureNotFound);
    let old_net_max_payout = vault.oracle_matrices[oracle_id].net_max_payout();
    vault.oracle_matrices[oracle_id].insert_range(lower, higher, quantity);
    let new_net_max_payout = vault.oracle_matrices[oracle_id].net_max_payout();
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

/// Remove a vertical range from the per-oracle exposure structure and update
/// cached max payout. Symmetric to `insert_range`.
public(package) fun remove_range(
    vault: &mut Vault,
    oracle_id: ID,
    lower: u64,
    higher: u64,
    quantity: u64,
) {
    assert!(vault.oracle_matrices.contains(oracle_id), EOracleExposureNotFound);
    let old_net_max_payout = vault.oracle_matrices[oracle_id].net_max_payout();
    vault.oracle_matrices[oracle_id].remove_range(lower, higher, quantity);
    let new_net_max_payout = vault.oracle_matrices[oracle_id].net_max_payout();
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

public(package) fun has_settled_oracle(vault: &Vault, oracle_id: ID): bool {
    vault.settled_oracles.contains(oracle_id)
}

public(package) fun set_mtm_with_curve(
    vault: &mut Vault,
    oracle_id: ID,
    curve: &vector<CurvePoint>,
) {
    assert!(vault.oracle_matrices.contains(oracle_id), EOracleExposureNotFound);

    let matrix = &vault.oracle_matrices[oracle_id];
    let old_mtm = matrix.mtm();
    let new_mtm = matrix.evaluate(curve) - matrix.range_qty();

    let matrix = &mut vault.oracle_matrices[oracle_id];
    matrix.set_mtm(new_mtm);
    vault.total_mtm = vault.total_mtm + new_mtm - old_mtm;
}

public(package) fun set_mtm_with_settlement(vault: &mut Vault, oracle_id: ID, settlement: u64) {
    assert!(vault.oracle_matrices.contains(oracle_id), EOracleExposureNotFound);

    let matrix = &vault.oracle_matrices[oracle_id];
    let old_mtm = matrix.mtm();
    let new_mtm = matrix.evaluate_settled(settlement) - matrix.range_qty();

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

public(package) fun compact_settled_oracle_if_needed(
    vault: &mut Vault,
    oracle_id: ID,
    settlement: u64,
) {
    if (vault.settled_oracles.contains(oracle_id)) return;

    assert!(vault.oracle_matrices.contains(oracle_id), EOracleExposureNotFound);
    let matrix = vault.oracle_matrices.remove(oracle_id);
    let old_mtm = matrix.mtm();
    let old_max_payout = matrix.net_max_payout();
    let (remaining_quantity, remaining_liability) = strike_matrix::into_settled_totals(
        matrix,
        settlement,
    );

    vault.total_mtm = vault.total_mtm + remaining_liability - old_mtm;
    vault.total_max_payout = vault.total_max_payout + remaining_liability - old_max_payout;

    vault
        .settled_oracles
        .add(
            oracle_id,
            SettledOracleState {
                remaining_quantity,
                remaining_liability,
            },
        );
}

public(package) fun redeem_settled_position(
    vault: &mut Vault,
    oracle_id: ID,
    quantity: u64,
    payout: u64,
) {
    assert!(vault.settled_oracles.contains(oracle_id), EOracleExposureNotFound);
    let state = &mut vault.settled_oracles[oracle_id];
    state.remaining_quantity = state.remaining_quantity - quantity;
    state.remaining_liability = state.remaining_liability - payout;
    vault.total_mtm = vault.total_mtm - payout;
    vault.total_max_payout = vault.total_max_payout - payout;
    // TODO: Decide whether fully redeemed settled oracles should be removed
    // entirely or retained as zeroed records.
}

/// Per-matrix max payout net of the range quantity contributed by range mints.
fun net_max_payout(matrix: &StrikeMatrix): u64 {
    matrix.max_payout() - matrix.range_qty()
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

// === Tests ===

#[test]
fun test_compact_settled_oracle_builds_compact_state() {
    let settlement = 120;
    let expected_quantity = 18;
    let expected_liability = 18;
    let ctx = &mut tx_context::dummy();
    let mut vault = new(ctx);
    let oracle_uid = object::new(ctx);
    let oracle_id = oracle_uid.to_inner();

    init_oracle_matrix(&mut vault, oracle_id, 100, 130, 10, ctx);
    insert_position(&mut vault, oracle_id, true, 100, 7);
    insert_position(&mut vault, oracle_id, false, 120, 11);
    set_mtm_with_settlement(&mut vault, oracle_id, settlement);
    compact_settled_oracle_if_needed(&mut vault, oracle_id, settlement);

    let state = vault.settled_oracles[oracle_id];
    assert!(has_settled_oracle(&vault, oracle_id), 0);
    assert!(state.remaining_quantity == expected_quantity, 0);
    assert!(state.remaining_liability == expected_liability, 0);
    assert!(vault.total_mtm == expected_liability, 0);
    assert!(vault.total_max_payout == expected_liability, 0);

    destroy_test_vault(vault, oracle_id);
    oracle_uid.delete();
}

#[test]
fun test_compact_settled_oracle_accounts_for_range_positions() {
    let settlement = 110;
    let quantity = 7;
    let ctx = &mut tx_context::dummy();
    let mut vault = new(ctx);
    let oracle_uid = object::new(ctx);
    let oracle_id = oracle_uid.to_inner();

    init_oracle_matrix(&mut vault, oracle_id, 100, 120, 10, ctx);
    insert_range(&mut vault, oracle_id, 100, 120, quantity);
    set_mtm_with_settlement(&mut vault, oracle_id, settlement);
    compact_settled_oracle_if_needed(&mut vault, oracle_id, settlement);

    let state = vault.settled_oracles[oracle_id];
    assert!(state.remaining_quantity == quantity, 0);
    assert!(state.remaining_liability == quantity, 0);
    assert!(vault.total_mtm == quantity, 0);
    assert!(vault.total_max_payout == quantity, 0);

    destroy_test_vault(vault, oracle_id);
    oracle_uid.delete();
}

#[test]
fun test_redeem_settled_position_keeps_zeroed_record() {
    let settlement = 110;
    let quantity = 9;
    let payout = 9;
    let ctx = &mut tx_context::dummy();
    let mut vault = new(ctx);
    let oracle_uid = object::new(ctx);
    let oracle_id = oracle_uid.to_inner();

    init_oracle_matrix(&mut vault, oracle_id, 100, 120, 10, ctx);
    insert_position(&mut vault, oracle_id, true, 100, quantity);
    set_mtm_with_settlement(&mut vault, oracle_id, settlement);
    compact_settled_oracle_if_needed(&mut vault, oracle_id, settlement);
    redeem_settled_position(&mut vault, oracle_id, quantity, payout);

    let state = vault.settled_oracles[oracle_id];
    assert!(has_settled_oracle(&vault, oracle_id), 0);
    assert!(state.remaining_quantity == 0, 0);
    assert!(state.remaining_liability == 0, 0);
    assert!(vault.total_mtm == 0, 0);
    assert!(vault.total_max_payout == 0, 0);

    destroy_test_vault(vault, oracle_id);
    oracle_uid.delete();
}

#[test_only]
fun destroy_test_vault(mut vault: Vault, oracle_id: ID) {
    if (vault.settled_oracles.contains(oracle_id)) {
        let _ = table::remove(&mut vault.settled_oracles, oracle_id);
    };
    if (vault.oracle_matrices.contains(oracle_id)) {
        let matrix = table::remove(&mut vault.oracle_matrices, oracle_id);
        let (_, _) = strike_matrix::into_settled_totals(matrix, 0);
    };

    let Vault {
        balances,
        balance: _,
        oracle_matrices,
        settled_oracles,
        total_mtm: _,
        total_max_payout: _,
    } = vault;
    balances.destroy_empty();
    oracle_matrices.destroy_empty();
    settled_oracles.destroy_empty();
}
