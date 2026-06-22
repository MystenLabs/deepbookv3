// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pool-vault events for Predict: DEEP staking, expiry cash/profit, fee
/// incentives, and the async LP supply/withdraw request → flush lifecycle (the
/// flush event carries the full-pool valuation it priced fills at).
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
/// On a sweep, any carried protocol cut a prior settled sweep could not cover is also
/// realized from the returned idle into the reserve, so `protocol_reserve_balance_after`
/// and `pending_protocol_profit_after` report the post-drain state.
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
    protocol_reserve_balance_after: u64,
    pending_protocol_profit_after: u64,
}

/// Emitted when a terminal expiry's profit is materialized: the LP cut stays in idle
/// and the protocol cut is realized into the protocol reserve up to available idle, any
/// remainder carried in `pending_protocol_profit_after` for a later sweep to realize.
public struct ExpiryProfitMaterialized has copy, drop, store {
    pool_vault_id: ID,
    expiry_market_id: ID,
    lp_profit: u64,
    protocol_profit: u64,
    idle_balance_after: u64,
    protocol_reserve_balance_after: u64,
    profit_basis_after: u64,
    pending_protocol_profit_after: u64,
}

/// Emitted when an account stakes DEEP for trading benefits.
public struct DeepStaked has copy, drop, store {
    pool_vault_id: ID,
    account_id: ID,
    amount: u64,
    /// Account active/inactive stake after the deposit. Freshly staked DEEP is
    /// inactive until it rolls active in a later epoch, so both are reported.
    active_stake_after: u64,
    inactive_stake_after: u64,
}

/// Emitted when an account unstakes all of its DEEP (active and inactive).
public struct DeepUnstaked has copy, drop, store {
    pool_vault_id: ID,
    account_id: ID,
    amount: u64,
}

/// Emitted when an LP queues a supply request: `amount` DUSDC is escrowed and a fill
/// will be delivered to `recipient` (the account's receive address) at a later flush.
/// `index` is the queue handle used to cancel.
public struct SupplyRequested has copy, drop, store {
    pool_vault_id: ID,
    account_id: ID,
    recipient: address,
    index: u64,
    amount: u64,
}

/// Emitted when an LP queues a withdraw request: `amount` PLP shares are escrowed and
/// DUSDC will be delivered to `recipient` at a later flush.
public struct WithdrawRequested has copy, drop, store {
    pool_vault_id: ID,
    account_id: ID,
    recipient: address,
    index: u64,
    amount: u64,
}

/// Emitted when an LP cancels a still-pending request before it is flushed: the
/// escrow (`amount` of DUSDC if `is_supply`, else PLP) is refunded straight into the
/// requesting account.
public struct RequestCancelled has copy, drop, store {
    pool_vault_id: ID,
    account_id: ID,
    recipient: address,
    index: u64,
    amount: u64,
    is_supply: bool,
}

/// Emitted when a supply request fills: `dusdc_amount` joined pool idle and
/// `shares_minted` PLP were delivered to `recipient`. `account_id` is the
/// owning account (carried from the queued request so the fill is self-contained;
/// `recipient` is its receive address).
public struct SupplyFilled has copy, drop, store {
    pool_vault_id: ID,
    account_id: ID,
    recipient: address,
    index: u64,
    dusdc_amount: u64,
    shares_minted: u64,
}

/// Emitted when a withdraw request fills: `shares_burned` PLP were burned and
/// `dusdc_amount` was delivered to `recipient` from pool idle. `account_id`
/// is the owning account (carried from the queued request).
public struct WithdrawFilled has copy, drop, store {
    pool_vault_id: ID,
    account_id: ID,
    recipient: address,
    index: u64,
    shares_burned: u64,
    dusdc_amount: u64,
}

/// Emitted once per flush after both queues drain. The flush IS the full-pool
/// valuation, so this single event carries the frozen mark every fill was priced at
/// (`pool_value` over `total_supply`), its valuation breakdown (`idle_balance_before`
/// plus `active_market_nav` over `market_count` active markets), how many of each
/// kind filled, the total live requests processed against the per-flush cap, and the
/// idle balance after the drain.
public struct FlushExecuted has copy, drop, store {
    pool_vault_id: ID,
    epoch: u64,
    /// LP-attributable pool NAV every fill was priced at: `lp_pool_value(idle,
    /// credits, debits, reserve_share, active_market_nav)`.
    pool_value: u64,
    total_supply: u64,
    /// Σ of each active market's exact NAV at valuation (settled markets contribute 0).
    active_market_nav: u64,
    /// Number of active markets valued for this flush.
    market_count: u64,
    /// Idle DUSDC held by the pool at valuation time, before the drain.
    idle_balance_before: u64,
    supplies_filled: u64,
    withdrawals_filled: u64,
    requests_processed: u64,
    idle_balance_after: u64,
}

/// Emitted once when the pool is bootstrapped via `plp::lock_capital`: `amount`
/// DUSDC is permanently locked as minimum liquidity and matching PLP is minted into
/// the book's locked balance (never withdrawable), so `total_supply` stays > 0.
public struct CapitalLocked has copy, drop, store {
    pool_vault_id: ID,
    amount: u64,
}

/// Emitted when a sponsor contributes DUSDC to the pool-level fee incentive reserve.
public struct FeeIncentivesSponsored has copy, drop, store {
    pool_vault_id: ID,
    sponsor: address,
    amount: u64,
    reserve_after: u64,
}

/// Emitted when pool-level sponsor funds are allocated into an expiry's local
/// fee-incentive balance.
public struct FeeIncentivesAllocated has copy, drop, store {
    pool_vault_id: ID,
    expiry_market_id: ID,
    amount: u64,
    pool_reserve_after: u64,
    expiry_incentive_balance_after: u64,
    expiry_incentives_allocated_after: u64,
}

/// Emitted when a settled expiry returns unused local fee incentives to the
/// pool-level reserve.
public struct FeeIncentivesReturned has copy, drop, store {
    pool_vault_id: ID,
    expiry_market_id: ID,
    amount: u64,
    pool_reserve_after: u64,
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
    protocol_reserve_balance_after: u64,
    pending_protocol_profit_after: u64,
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
        protocol_reserve_balance_after,
        pending_protocol_profit_after,
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
    pending_protocol_profit_after: u64,
) {
    event::emit(ExpiryProfitMaterialized {
        pool_vault_id,
        expiry_market_id,
        lp_profit,
        protocol_profit,
        idle_balance_after,
        protocol_reserve_balance_after,
        profit_basis_after,
        pending_protocol_profit_after,
    });
}

public(package) fun emit_deep_staked(
    pool_vault_id: ID,
    account_id: ID,
    amount: u64,
    active_stake_after: u64,
    inactive_stake_after: u64,
) {
    event::emit(DeepStaked {
        pool_vault_id,
        account_id,
        amount,
        active_stake_after,
        inactive_stake_after,
    });
}

public(package) fun emit_deep_unstaked(pool_vault_id: ID, account_id: ID, amount: u64) {
    event::emit(DeepUnstaked {
        pool_vault_id,
        account_id,
        amount,
    });
}

public(package) fun emit_supply_requested(
    pool_vault_id: ID,
    account_id: ID,
    recipient: address,
    index: u64,
    amount: u64,
) {
    event::emit(SupplyRequested {
        pool_vault_id,
        account_id,
        recipient,
        index,
        amount,
    });
}

public(package) fun emit_withdraw_requested(
    pool_vault_id: ID,
    account_id: ID,
    recipient: address,
    index: u64,
    amount: u64,
) {
    event::emit(WithdrawRequested {
        pool_vault_id,
        account_id,
        recipient,
        index,
        amount,
    });
}

public(package) fun emit_request_cancelled(
    pool_vault_id: ID,
    account_id: ID,
    recipient: address,
    index: u64,
    amount: u64,
    is_supply: bool,
) {
    event::emit(RequestCancelled {
        pool_vault_id,
        account_id,
        recipient,
        index,
        amount,
        is_supply,
    });
}

public(package) fun emit_supply_filled(
    pool_vault_id: ID,
    account_id: ID,
    recipient: address,
    index: u64,
    dusdc_amount: u64,
    shares_minted: u64,
) {
    event::emit(SupplyFilled {
        pool_vault_id,
        account_id,
        recipient,
        index,
        dusdc_amount,
        shares_minted,
    });
}

public(package) fun emit_withdraw_filled(
    pool_vault_id: ID,
    account_id: ID,
    recipient: address,
    index: u64,
    shares_burned: u64,
    dusdc_amount: u64,
) {
    event::emit(WithdrawFilled {
        pool_vault_id,
        account_id,
        recipient,
        index,
        shares_burned,
        dusdc_amount,
    });
}

public(package) fun emit_flush_executed(
    pool_vault_id: ID,
    epoch: u64,
    pool_value: u64,
    total_supply: u64,
    active_market_nav: u64,
    market_count: u64,
    idle_balance_before: u64,
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
        active_market_nav,
        market_count,
        idle_balance_before,
        supplies_filled,
        withdrawals_filled,
        requests_processed,
        idle_balance_after,
    });
}

public(package) fun emit_capital_locked(pool_vault_id: ID, amount: u64) {
    event::emit(CapitalLocked { pool_vault_id, amount });
}

public(package) fun emit_fee_incentives_sponsored(
    pool_vault_id: ID,
    sponsor: address,
    amount: u64,
    reserve_after: u64,
) {
    event::emit(FeeIncentivesSponsored {
        pool_vault_id,
        sponsor,
        amount,
        reserve_after,
    });
}

public(package) fun emit_fee_incentives_allocated(
    pool_vault_id: ID,
    expiry_market_id: ID,
    amount: u64,
    pool_reserve_after: u64,
    expiry_incentive_balance_after: u64,
    expiry_incentives_allocated_after: u64,
) {
    event::emit(FeeIncentivesAllocated {
        pool_vault_id,
        expiry_market_id,
        amount,
        pool_reserve_after,
        expiry_incentive_balance_after,
        expiry_incentives_allocated_after,
    });
}

public(package) fun emit_fee_incentives_returned(
    pool_vault_id: ID,
    expiry_market_id: ID,
    amount: u64,
    pool_reserve_after: u64,
) {
    event::emit(FeeIncentivesReturned {
        pool_vault_id,
        expiry_market_id,
        amount,
        pool_reserve_after,
    });
}
