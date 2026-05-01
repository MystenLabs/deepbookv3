// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Vault module - pure state machine for trade execution.
///
/// The vault holds accepted quote assets and takes the opposite side of every trade.
/// Pricing inputs are prepared by the orchestrator (predict.move).
///
/// Tracks mark-to-market liability via per-oracle strike matrices and a cached
/// global total_mtm. Trade mutations receive a post-trade valuation input and
/// leave aggregate exposure accounting current when they return.
///
/// Scaling conventions (aligned with DeepBook):
/// - Quantities are in quote units: 1_000_000 = 1 contract = $1 at settlement
module deepbook_predict::vault;

use deepbook::math;
use deepbook_predict::{
    pricing::CurvePoint,
    range_key::RangeKey,
    strike_matrix::{Self, StrikeMatrix}
};
use sui::{bag::{Self, Bag}, balance::Balance, clock::Clock, table::{Self, Table}};

const EInsufficientBalance: u64 = 0;
const EExceedsMaxTotalExposure: u64 = 1;
const EOracleExposureNotFound: u64 = 2;
const EMtmExceedsBalance: u64 = 3;
const EAssetNotInVault: u64 = 4;

/// Dynamic bag key for storing a concrete asset balance by type.
public struct BalanceKey<phantom T> has copy, drop, store {}

/// Vault state for balances, exposure matrices, and aggregate liability.
public struct Vault has store {
    /// Concrete balances stored per accepted quote asset type.
    balances: Bag,
    /// Shared treasury balance tracked in quote units.
    balance: u64,
    /// Per-oracle matrix for strike-level position tracking.
    oracle_matrices: Table<ID, StrikeMatrix>,
    /// Per-oracle expiry used to block LP flows while exposed expired oracles wait for settlement.
    oracle_expiries: Table<ID, u64>,
    /// Settlement prices for compacted oracles.
    compacted_oracle_settlements: Table<ID, u64>,
    /// Sum of all oracle matrix MTM values.
    total_mtm: u64,
    /// Sum of all oracle matrix max payout values.
    total_max_payout: u64,
    /// Oracle IDs whose unsettled exposure must have fresh MTM before LP
    /// supply/withdraw. Trade mutations refresh the touched oracle inline.
    unsettled_exposed_oracles: vector<ID>,
}

// === Public Functions ===

/// Return the aggregate vault balance across accepted quote assets.
public fun balance(vault: &Vault): u64 {
    vault.balance
}

/// Return the concrete balance for asset type `T`, or zero if absent.
public fun asset_balance<T>(vault: &Vault): u64 {
    let key = BalanceKey<T> {};
    if (vault.balances.contains(key)) {
        let balance: &Balance<T> = &vault.balances[key];
        balance.value()
    } else {
        0
    }
}

/// Return cached total mark-to-market liability.
public fun total_mtm(vault: &Vault): u64 {
    vault.total_mtm
}

/// Return balance net of cached mark-to-market liability.
public fun vault_value(vault: &Vault): u64 {
    assert!(vault.balance >= vault.total_mtm, EMtmExceedsBalance);
    vault.balance - vault.total_mtm
}

/// Return cached total worst-case payout liability.
public fun total_max_payout(vault: &Vault): u64 {
    vault.total_max_payout
}

// === Public-Package Functions ===

/// Create an empty vault.
public(package) fun new(ctx: &mut TxContext): Vault {
    Vault {
        balances: bag::new(ctx),
        balance: 0,
        oracle_matrices: table::new(ctx),
        oracle_expiries: table::new(ctx),
        compacted_oracle_settlements: table::new(ctx),
        total_mtm: 0,
        total_max_payout: 0,
        unsettled_exposed_oracles: vector[],
    }
}

/// Allocate one zeroed strike matrix for an oracle's configured strike grid.
public(package) fun init_oracle_matrix(
    vault: &mut Vault,
    oracle_id: ID,
    expiry: u64,
    min_strike: u64,
    max_strike: u64,
    tick_size: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    if (!vault.oracle_matrices.contains(oracle_id)) {
        vault
            .oracle_matrices
            .add(
                oracle_id,
                strike_matrix::new(ctx, tick_size, min_strike, max_strike, clock),
            );
    };
    if (!vault.oracle_expiries.contains(oracle_id)) {
        vault.oracle_expiries.add(oracle_id, expiry);
    };
}

/// Insert a live vertical range and refresh live risk accounting.
public(package) fun insert_live_range(
    vault: &mut Vault,
    key: RangeKey,
    quantity: u64,
    curve: vector<CurvePoint>,
    clock: &Clock,
) {
    let oracle_id = key.oracle_id();
    let lower = key.lower_strike();
    let higher = key.higher_strike();
    assert!(vault.oracle_matrices.contains(oracle_id), EOracleExposureNotFound);
    let matrix = &mut vault.oracle_matrices[oracle_id];
    matrix.insert_range(lower, higher, quantity);
    vault.apply_live_valuation(oracle_id, curve, clock);
    vault.add_unsettled_exposed_oracle(oracle_id);
}

/// Remove a live vertical range from dense matrix exposure and refresh live risk accounting.
public(package) fun remove_live_range(
    vault: &mut Vault,
    key: RangeKey,
    quantity: u64,
    curve: vector<CurvePoint>,
    clock: &Clock,
) {
    let oracle_id = key.oracle_id();
    let lower = key.lower_strike();
    let higher = key.higher_strike();
    assert!(vault.oracle_matrices.contains(oracle_id), EOracleExposureNotFound);
    let matrix = &mut vault.oracle_matrices[oracle_id];
    matrix.remove_range(lower, higher, quantity);
    vault.apply_live_valuation(oracle_id, curve, clock);
    vault.remove_unsettled_exposed_oracle_if_empty(oracle_id);
}

/// Remove a settled vertical range from dense matrix exposure or compacted liability.
public(package) fun remove_settled_range(
    vault: &mut Vault,
    key: RangeKey,
    quantity: u64,
    settlement: u64,
    clock: &Clock,
) {
    let oracle_id = key.oracle_id();
    let lower = key.lower_strike();
    let higher = key.higher_strike();
    if (vault.compacted_oracle_settlements.contains(oracle_id)) {
        let settlement_price = *vault.compacted_oracle_settlements.borrow(oracle_id);
        let payout = key.settled_payout(settlement_price, quantity);
        vault.total_mtm = vault.total_mtm - payout;
        vault.total_max_payout = vault.total_max_payout - payout;
        vault.remove_unsettled_exposed_oracle(oracle_id);
    } else {
        assert!(vault.oracle_matrices.contains(oracle_id), EOracleExposureNotFound);
        let matrix = &mut vault.oracle_matrices[oracle_id];
        matrix.remove_range(lower, higher, quantity);
        vault.apply_settled_oracle_valuation(oracle_id, settlement, clock);
    };
}

/// Accept payment into vault balance.
public(package) fun accept_payment<T>(vault: &mut Vault, payment: Balance<T>) {
    let amount = payment.value();
    vault.deposit_balance(payment);
    vault.balance = vault.balance + amount;
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

/// Compact a settled oracle's dense matrix into fixed-size liability state.
public(package) fun compact_settled_oracle_if_needed(
    vault: &mut Vault,
    oracle_id: ID,
    settlement: u64,
) {
    if (vault.compacted_oracle_settlements.contains(oracle_id)) {
        vault.remove_unsettled_exposed_oracle(oracle_id);
        return
    };

    assert!(vault.oracle_matrices.contains(oracle_id), EOracleExposureNotFound);
    let matrix = vault.oracle_matrices.remove(oracle_id);
    vault.remove_unsettled_exposed_oracle(oracle_id);
    let old_mtm = matrix.mtm();
    let old_max_payout = matrix.max_payout();
    let remaining_liability = strike_matrix::into_settled_liability(matrix, settlement);

    vault.total_mtm = vault.total_mtm + remaining_liability - old_mtm;
    vault.total_max_payout = vault.total_max_payout + remaining_liability - old_max_payout;

    vault.compacted_oracle_settlements.add(oracle_id, settlement);
}

/// Return oracle IDs requiring fresh MTM before LP supply/withdraw.
public(package) fun unsettled_exposed_oracles(vault: &Vault): &vector<ID> {
    &vault.unsettled_exposed_oracles
}

/// Return the historical minted strike bounds needed to value an oracle.
public(package) fun valuation_strike_range(vault: &Vault, oracle_id: ID): (u64, u64) {
    assert!(vault.oracle_matrices.contains(oracle_id), EOracleExposureNotFound);
    let matrix = &vault.oracle_matrices[oracle_id];
    matrix.minted_strike_range()
}

/// Apply a live curve valuation to one oracle's cached MTM and max payout.
public(package) fun apply_live_valuation(
    vault: &mut Vault,
    oracle_id: ID,
    curve: vector<CurvePoint>,
    clock: &Clock,
) {
    if (vault.compacted_oracle_settlements.contains(oracle_id)) {
        return
    };
    assert!(vault.oracle_matrices.contains(oracle_id), EOracleExposureNotFound);
    let matrix = &mut vault.oracle_matrices[oracle_id];
    let (old_mtm, old_max_payout, new_mtm, new_max_payout) = matrix.refresh_live_risk(
        &curve,
        clock,
    );
    vault.update_cached_risk(old_mtm, old_max_payout, new_mtm, new_max_payout);
}

/// Apply settled valuation and clear the oracle from the live-refresh worklist.
public(package) fun apply_settled_oracle_valuation(
    vault: &mut Vault,
    oracle_id: ID,
    settlement: u64,
    clock: &Clock,
) {
    if (vault.compacted_oracle_settlements.contains(oracle_id)) {
        vault.remove_unsettled_exposed_oracle(oracle_id);
        return
    };
    assert!(vault.oracle_matrices.contains(oracle_id), EOracleExposureNotFound);
    let matrix = &mut vault.oracle_matrices[oracle_id];
    let (old_mtm, old_max_payout, new_mtm, new_max_payout) = matrix.refresh_settled_risk(
        settlement,
        clock,
    );
    vault.update_cached_risk(old_mtm, old_max_payout, new_mtm, new_max_payout);
    vault.remove_unsettled_exposed_oracle(oracle_id);
}

/// Return the cached MTM update timestamp for an oracle.
public(package) fun get_last_mtm_update(vault: &Vault, oracle_id: ID): u64 {
    assert!(vault.oracle_matrices.contains(oracle_id), EOracleExposureNotFound);
    vault.oracle_matrices[oracle_id].last_mtm_update()
}

/// Return the registered expiry for an oracle.
public(package) fun oracle_expiry(vault: &Vault, oracle_id: ID): u64 {
    assert!(vault.oracle_expiries.contains(oracle_id), EOracleExposureNotFound);
    vault.oracle_expiries[oracle_id]
}

// === Private Functions ===

fun add_unsettled_exposed_oracle(vault: &mut Vault, oracle_id: ID) {
    let mut i = 0;
    while (i < vault.unsettled_exposed_oracles.length()) {
        if (vault.unsettled_exposed_oracles[i] == oracle_id) return;
        i = i + 1;
    };
    vault.unsettled_exposed_oracles.push_back(oracle_id);
}

fun remove_unsettled_exposed_oracle_if_empty(vault: &mut Vault, oracle_id: ID) {
    assert!(vault.oracle_matrices.contains(oracle_id), EOracleExposureNotFound);
    let matrix = &vault.oracle_matrices[oracle_id];
    if (matrix.mtm() != 0 || matrix.max_payout() != 0) return;

    vault.remove_unsettled_exposed_oracle(oracle_id);
}

fun remove_unsettled_exposed_oracle(vault: &mut Vault, oracle_id: ID) {
    let mut i = 0;
    while (i < vault.unsettled_exposed_oracles.length()) {
        if (vault.unsettled_exposed_oracles[i] == oracle_id) {
            vault.unsettled_exposed_oracles.swap_remove(i);
            return
        };
        i = i + 1;
    };
}

fun update_cached_risk(
    vault: &mut Vault,
    old_mtm: u64,
    old_max_payout: u64,
    new_mtm: u64,
    new_max_payout: u64,
) {
    vault.total_mtm = vault.total_mtm + new_mtm - old_mtm;
    vault.total_max_payout = vault.total_max_payout + new_max_payout - old_max_payout;
}

/// Join a concrete asset balance into its bag entry, creating it if needed.
fun deposit_balance<T>(vault: &mut Vault, payment: Balance<T>) {
    let key = BalanceKey<T> {};
    if (vault.balances.contains(key)) {
        let balance: &mut Balance<T> = &mut vault.balances[key];
        balance.join(payment);
    } else {
        vault.balances.add(key, payment);
    }
}

/// Split a concrete asset balance from its bag entry.
fun withdraw_balance<T>(vault: &mut Vault, amount: u64): Balance<T> {
    let key = BalanceKey<T> {};
    assert!(vault.balances.contains(key), EAssetNotInVault);
    let balance: &mut Balance<T> = &mut vault.balances[key];
    assert!(balance.value() >= amount, EInsufficientBalance);
    balance.split(amount)
}
