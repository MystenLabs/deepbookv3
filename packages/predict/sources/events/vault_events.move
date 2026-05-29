// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pool-vault lifecycle events for Predict.
///
/// These are low-frequency relative to trades, so they are rich: supply and
/// withdraw carry the pool value used to price shares, and settled-expiry
/// sweeps carry the raw cash and fee movements.
module deepbook_predict::vault_events;

use sui::event;

/// Emitted when DUSDC is supplied and PLP shares are minted.
///
/// `pool_value_before` is the full-pool NAV that priced the mint, so the NAV per
/// share and pool composition are recoverable without a separate valuation event.
public struct SupplyExecuted has copy, drop, store {
    pool_vault_id: ID,
    payment: u64,
    shares_minted: u64,
    /// Pool NAV used to price the mint, in DUSDC base units.
    pool_value_before: u64,
    total_supply_after: u64,
    idle_balance_after: u64,
    total_allocated_after: u64,
}

/// Emitted when PLP shares are burned and DUSDC is withdrawn.
public struct WithdrawExecuted has copy, drop, store {
    pool_vault_id: ID,
    shares_burned: u64,
    payout: u64,
    pool_value_before: u64,
    total_supply_after: u64,
    idle_balance_after: u64,
    total_allocated_after: u64,
}

/// Emitted when an expiry's allocation is created, grows, or shrinks.
public struct ExpiryAllocationChanged has copy, drop, store {
    pool_vault_id: ID,
    expiry_market_id: ID,
    amount: u64,
    /// True when capital moved from pool idle cash into the expiry market.
    to_expiry_pool: bool,
    allocation_after: u64,
    idle_balance_after: u64,
}

/// Emitted when a settled expiry returns surplus cash or releases allocation.
public struct ExpirySurplusSwept has copy, drop, store {
    pool_vault_id: ID,
    expiry_market_id: ID,
    settlement_price: u64,
    /// Active allocation retired by this sweep. Zero on residual sweeps.
    released_allocation: u64,
    /// Surplus LP cash returned to idle this sweep.
    returned_cash: u64,
    idle_balance_after: u64,
    total_allocated_after: u64,
    fee_surplus_to_protocol: u64,
    fee_surplus_to_insurance: u64,
    fee_surplus_to_lp: u64,
}

// === Public-Package Functions ===

public(package) fun emit_supply_executed(
    pool_vault_id: ID,
    payment: u64,
    shares_minted: u64,
    pool_value_before: u64,
    total_supply_after: u64,
    idle_balance_after: u64,
    total_allocated_after: u64,
) {
    event::emit(SupplyExecuted {
        pool_vault_id,
        payment,
        shares_minted,
        pool_value_before,
        total_supply_after,
        idle_balance_after,
        total_allocated_after,
    });
}

public(package) fun emit_withdraw_executed(
    pool_vault_id: ID,
    shares_burned: u64,
    payout: u64,
    pool_value_before: u64,
    total_supply_after: u64,
    idle_balance_after: u64,
    total_allocated_after: u64,
) {
    event::emit(WithdrawExecuted {
        pool_vault_id,
        shares_burned,
        payout,
        pool_value_before,
        total_supply_after,
        idle_balance_after,
        total_allocated_after,
    });
}

public(package) fun emit_expiry_allocation_changed(
    pool_vault_id: ID,
    expiry_market_id: ID,
    amount: u64,
    to_expiry_pool: bool,
    allocation_after: u64,
    idle_balance_after: u64,
) {
    event::emit(ExpiryAllocationChanged {
        pool_vault_id,
        expiry_market_id,
        amount,
        to_expiry_pool,
        allocation_after,
        idle_balance_after,
    });
}

public(package) fun emit_expiry_surplus_swept(
    pool_vault_id: ID,
    expiry_market_id: ID,
    settlement_price: u64,
    released_allocation: u64,
    returned_cash: u64,
    idle_balance_after: u64,
    total_allocated_after: u64,
    fee_surplus_to_protocol: u64,
    fee_surplus_to_insurance: u64,
    fee_surplus_to_lp: u64,
) {
    event::emit(ExpirySurplusSwept {
        pool_vault_id,
        expiry_market_id,
        settlement_price,
        released_allocation,
        returned_cash,
        idle_balance_after,
        total_allocated_after,
        fee_surplus_to_protocol,
        fee_surplus_to_insurance,
        fee_surplus_to_lp,
    });
}
