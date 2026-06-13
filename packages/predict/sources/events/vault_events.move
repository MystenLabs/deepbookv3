// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pool-vault DEEP-staking, full-pool valuation, and expiry cash/profit events
/// for Predict.
module deepbook_predict::vault_events;

use sui::event;

/// Emitted when a settled expiry returns its free cash to the pool (during the
/// settled-market sweep): the expiry is deactivated and all cash above settled
/// backing is returned to idle.
public struct ExpiryCashReceived has copy, drop, store {
    pool_vault_id: ID,
    expiry_market_id: ID,
    settlement_price: u64,
    amount: u64,
    idle_balance_after: u64,
    sent_to_expiry_after: u64,
    received_from_expiry_after: u64,
}

/// Emitted when a terminal expiry's profit is materialized: the LP cut stays in
/// idle and the protocol cut is moved into the protocol reserve.
public struct ExpiryProfitMaterialized has copy, drop, store {
    pool_vault_id: ID,
    expiry_market_id: ID,
    lp_profit: u64,
    protocol_profit: u64,
    idle_balance_after: u64,
    protocol_reserve_balance_after: u64,
    profit_basis_after: u64,
}

/// Emitted when a full-pool NAV valuation completes: the LP-attributable pool-wide
/// DUSDC NAV, aggregated from idle balance plus every active market's exact NAV,
/// net of the pending-protocol-profit exclusion priced from the profit basis.
public struct PoolValued has copy, drop, store {
    pool_vault_id: ID,
    /// LP-attributable pool NAV: `lp_pool_value(idle, credits, debits, share, active)`.
    pool_nav: u64,
    /// Idle DUSDC held by the pool at valuation time.
    idle_balance: u64,
    /// Σ of each active market's exact NAV (settled markets contribute 0).
    active_market_nav: u64,
    /// Number of markets valued (the active set at snapshot time).
    market_count: u64,
}

/// Emitted when a manager stakes DEEP for trading benefits.
public struct DeepStaked has copy, drop, store {
    pool_vault_id: ID,
    predict_manager_id: ID,
    amount: u64,
    /// Manager active/inactive stake after the deposit. Freshly staked DEEP is
    /// inactive until it rolls active in a later epoch, so both are reported.
    active_stake_after: u64,
    inactive_stake_after: u64,
}

/// Emitted when a manager unstakes all of its DEEP (active and inactive).
public struct DeepUnstaked has copy, drop, store {
    pool_vault_id: ID,
    predict_manager_id: ID,
    amount: u64,
}

// === Public-Package Functions ===

public(package) fun emit_expiry_cash_received(
    pool_vault_id: ID,
    expiry_market_id: ID,
    settlement_price: u64,
    amount: u64,
    idle_balance_after: u64,
    sent_to_expiry_after: u64,
    received_from_expiry_after: u64,
) {
    event::emit(ExpiryCashReceived {
        pool_vault_id,
        expiry_market_id,
        settlement_price,
        amount,
        idle_balance_after,
        sent_to_expiry_after,
        received_from_expiry_after,
    });
}

public(package) fun emit_expiry_profit_materialized(
    pool_vault_id: ID,
    expiry_market_id: ID,
    lp_profit: u64,
    protocol_profit: u64,
    idle_balance_after: u64,
    protocol_reserve_balance_after: u64,
    profit_basis_after: u64,
) {
    event::emit(ExpiryProfitMaterialized {
        pool_vault_id,
        expiry_market_id,
        lp_profit,
        protocol_profit,
        idle_balance_after,
        protocol_reserve_balance_after,
        profit_basis_after,
    });
}

public(package) fun emit_pool_valued(
    pool_vault_id: ID,
    pool_nav: u64,
    idle_balance: u64,
    active_market_nav: u64,
    market_count: u64,
) {
    event::emit(PoolValued {
        pool_vault_id,
        pool_nav,
        idle_balance,
        active_market_nav,
        market_count,
    });
}

public(package) fun emit_deep_staked(
    pool_vault_id: ID,
    predict_manager_id: ID,
    amount: u64,
    active_stake_after: u64,
    inactive_stake_after: u64,
) {
    event::emit(DeepStaked {
        pool_vault_id,
        predict_manager_id,
        amount,
        active_stake_after,
        inactive_stake_after,
    });
}

public(package) fun emit_deep_unstaked(pool_vault_id: ID, predict_manager_id: ID, amount: u64) {
    event::emit(DeepUnstaked {
        pool_vault_id,
        predict_manager_id,
        amount,
    });
}
