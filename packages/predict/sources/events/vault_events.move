// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pool-vault events for Predict: DEEP staking, full-pool valuation, expiry
/// cash/profit, and the async LP supply/withdraw request → flush lifecycle.
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

/// Emitted when an active expiry's cash is rebalanced toward target: a top-up from
/// idle (`to_expiry = true`) or a surplus-sweep back to idle (`to_expiry = false`).
public struct ExpiryCashRebalanced has copy, drop, store {
    pool_vault_id: ID,
    expiry_market_id: ID,
    amount: u64,
    to_expiry: bool,
    target_cash: u64,
    expiry_cash_after: u64,
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

/// Emitted when an LP queues a supply request: `amount` DUSDC is escrowed and a fill
/// (or refund) will be delivered to `recipient` (the manager's address) at the next
/// flush. `index` is the queue handle used to cancel.
public struct SupplyRequested has copy, drop, store {
    pool_vault_id: ID,
    predict_manager_id: ID,
    recipient: address,
    index: u64,
    amount: u64,
}

/// Emitted when an LP queues a withdraw request: `amount` PLP shares are escrowed and
/// DUSDC (or a PLP refund) will be delivered to `recipient` at the next flush.
public struct WithdrawRequested has copy, drop, store {
    pool_vault_id: ID,
    predict_manager_id: ID,
    recipient: address,
    index: u64,
    amount: u64,
}

/// Emitted when an LP cancels a still-pending request before it is flushed: the
/// escrow (`amount` of DUSDC if `is_supply`, else PLP) is refunded straight into the
/// requesting manager.
public struct RequestCancelled has copy, drop, store {
    pool_vault_id: ID,
    predict_manager_id: ID,
    recipient: address,
    index: u64,
    amount: u64,
    is_supply: bool,
}

/// Emitted when a supply request fills: `dusdc_amount` joined pool idle and
/// `shares_minted` PLP were delivered to `recipient`.
public struct SupplyFilled has copy, drop, store {
    pool_vault_id: ID,
    recipient: address,
    index: u64,
    dusdc_amount: u64,
    shares_minted: u64,
}

/// Emitted when a withdraw request fills: `shares_burned` PLP were burned and
/// `dusdc_amount` was delivered to `recipient` from pool idle.
public struct WithdrawFilled has copy, drop, store {
    pool_vault_id: ID,
    recipient: address,
    index: u64,
    shares_burned: u64,
    dusdc_amount: u64,
}

/// Emitted when a supply request prices to zero shares (dust at the flush mark, or a
/// wiped pool) and its escrowed `dusdc_amount` is returned to `recipient` instead.
public struct SupplyRefunded has copy, drop, store {
    pool_vault_id: ID,
    recipient: address,
    index: u64,
    dusdc_amount: u64,
}

/// Emitted when a withdraw request prices to zero DUSDC (dust at the flush mark, or a
/// wiped pool) and its escrowed `plp_amount` is returned to `recipient` instead.
public struct WithdrawRefunded has copy, drop, store {
    pool_vault_id: ID,
    recipient: address,
    index: u64,
    plp_amount: u64,
}

/// Emitted once per flush after both queues drain: the frozen mark every fill was
/// priced at (`pool_value` over `total_supply`), how many of each kind filled, and
/// the total cursor advances spent against the per-flush cap.
public struct FlushExecuted has copy, drop, store {
    pool_vault_id: ID,
    epoch: u64,
    pool_value: u64,
    total_supply: u64,
    supplies_filled: u64,
    withdrawals_filled: u64,
    requests_processed: u64,
    idle_balance_after: u64,
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

public(package) fun emit_expiry_cash_rebalanced(
    pool_vault_id: ID,
    expiry_market_id: ID,
    amount: u64,
    to_expiry: bool,
    target_cash: u64,
    expiry_cash_after: u64,
    idle_balance_after: u64,
    sent_to_expiry_after: u64,
    received_from_expiry_after: u64,
) {
    event::emit(ExpiryCashRebalanced {
        pool_vault_id,
        expiry_market_id,
        amount,
        to_expiry,
        target_cash,
        expiry_cash_after,
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

public(package) fun emit_supply_requested(
    pool_vault_id: ID,
    predict_manager_id: ID,
    recipient: address,
    index: u64,
    amount: u64,
) {
    event::emit(SupplyRequested {
        pool_vault_id,
        predict_manager_id,
        recipient,
        index,
        amount,
    });
}

public(package) fun emit_withdraw_requested(
    pool_vault_id: ID,
    predict_manager_id: ID,
    recipient: address,
    index: u64,
    amount: u64,
) {
    event::emit(WithdrawRequested {
        pool_vault_id,
        predict_manager_id,
        recipient,
        index,
        amount,
    });
}

public(package) fun emit_request_cancelled(
    pool_vault_id: ID,
    predict_manager_id: ID,
    recipient: address,
    index: u64,
    amount: u64,
    is_supply: bool,
) {
    event::emit(RequestCancelled {
        pool_vault_id,
        predict_manager_id,
        recipient,
        index,
        amount,
        is_supply,
    });
}

public(package) fun emit_supply_filled(
    pool_vault_id: ID,
    recipient: address,
    index: u64,
    dusdc_amount: u64,
    shares_minted: u64,
) {
    event::emit(SupplyFilled {
        pool_vault_id,
        recipient,
        index,
        dusdc_amount,
        shares_minted,
    });
}

public(package) fun emit_withdraw_filled(
    pool_vault_id: ID,
    recipient: address,
    index: u64,
    shares_burned: u64,
    dusdc_amount: u64,
) {
    event::emit(WithdrawFilled {
        pool_vault_id,
        recipient,
        index,
        shares_burned,
        dusdc_amount,
    });
}

public(package) fun emit_supply_refunded(
    pool_vault_id: ID,
    recipient: address,
    index: u64,
    dusdc_amount: u64,
) {
    event::emit(SupplyRefunded {
        pool_vault_id,
        recipient,
        index,
        dusdc_amount,
    });
}

public(package) fun emit_withdraw_refunded(
    pool_vault_id: ID,
    recipient: address,
    index: u64,
    plp_amount: u64,
) {
    event::emit(WithdrawRefunded {
        pool_vault_id,
        recipient,
        index,
        plp_amount,
    });
}

public(package) fun emit_flush_executed(
    pool_vault_id: ID,
    epoch: u64,
    pool_value: u64,
    total_supply: u64,
    supplies_filled: u64,
    withdrawals_filled: u64,
    requests_processed: u64,
    idle_balance_after: u64,
) {
    event::emit(FlushExecuted {
        pool_vault_id,
        epoch,
        pool_value,
        total_supply,
        supplies_filled,
        withdrawals_filled,
        requests_processed,
        idle_balance_after,
    });
}
