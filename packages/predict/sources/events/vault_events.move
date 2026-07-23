// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pool-vault events for staking, expiry cash and profit, fee incentives, and the
/// queued LP request lifecycle. A flush records the frozen pool mark used by fills.
module deepbook_predict::vault_events;

use sui::event;

/// Emitted when expiry-local cash returns to pool idle: either settled free cash
/// during the terminal sweep, or residual rebate reserve returned by a settled
/// rebate claim.
public struct ExpiryCashReceived has copy, drop, store {
    pool_vault_id: ID,
    expiry_market_id: ID,
    settlement_price: u64,
    amount: u64,
}

/// Emitted when an active expiry's cash is rebalanced toward target: a top-up from
/// idle (`to_expiry = true`) or a surplus-sweep back to idle (`to_expiry = false`).
/// On a sweep, any carried protocol cut a prior settled sweep could not cover can
/// also be realized from the returned idle into the reserve; that sub-effect is
/// reported as the `protocol_profit_realized` delta.
public struct ExpiryCashRebalanced has copy, drop, store {
    pool_vault_id: ID,
    expiry_market_id: ID,
    amount: u64,
    to_expiry: bool,
    target_cash: u64,
    protocol_profit_realized: u64,
}

/// Emitted when a terminal expiry's profit is materialized: the LP cut stays in idle
/// and the protocol cut is realized into the protocol reserve up to available idle, any
/// remainder carried in `pending_protocol_profit_after` for a later sweep to realize.
public struct ExpiryProfitMaterialized has copy, drop, store {
    pool_vault_id: ID,
    expiry_market_id: ID,
    lp_profit: u64,
    protocol_profit: u64,
    protocol_reserve_balance_after: u64,
    profit_basis_after: u64,
    pending_protocol_profit_after: u64,
}

/// Emitted when a keeper resolves one account's settled trading-loss rebate.
public struct TradingLossRebateClaimed has copy, drop, store {
    pool_vault_id: ID,
    expiry_market_id: ID,
    account_id: ID,
    rebate_amount: u64,
    residual_returned: u64,
    trading_fees_paid: u64,
    gross_profit: u64,
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
/// `min_plp_out` is the minimum PLP the frozen mark must mint before the request
/// fills. `index` is the queue handle used to cancel.
public struct SupplyRequested has copy, drop, store {
    pool_vault_id: ID,
    account_id: ID,
    recipient: address,
    index: u64,
    amount: u64,
    min_plp_out: u64,
    requests_pending_after: u64,
}

/// Emitted when an LP queues a withdraw request: `amount` PLP shares are escrowed and
/// DUSDC will be delivered to `recipient` at a later flush. `min_dusdc_out` is the
/// minimum DUSDC the frozen mark must pay before the request fills.
public struct WithdrawRequested has copy, drop, store {
    pool_vault_id: ID,
    account_id: ID,
    recipient: address,
    index: u64,
    amount: u64,
    min_dusdc_out: u64,
    requests_pending_after: u64,
}

/// Emitted when a still-pending request is cancelled and the escrow (`amount` of
/// DUSDC if `is_supply`, else PLP) is refunded straight into the requesting account.
/// Cancellation can be user-requested before flush or protocol-triggered when the
/// frozen mark makes the request non-executable, or after repeated limit misses.
public struct RequestCancelled has copy, drop, store {
    pool_vault_id: ID,
    account_id: ID,
    recipient: address,
    index: u64,
    amount: u64,
    is_supply: bool,
    /// 0=user, 1=non-executable frozen mark, 2=limit expired.
    reason: u8,
    requests_pending_after: u64,
}

/// Emitted when a queued LP request reaches the head during a flush but the frozen
/// mark output misses its request-time limit and the request remains queued.
public struct RequestLimitMissed has copy, drop, store {
    pool_vault_id: ID,
    account_id: ID,
    recipient: address,
    index: u64,
    amount: u64,
    is_supply: bool,
    quoted_output: u64,
    min_output: u64,
    missed_flushes: u64,
    max_misses: u64,
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
    requests_pending_after: u64,
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
    requests_pending_after: u64,
}

/// Emitted once after a flush drains both queues at one frozen pre-drain
/// bid/ask mark over `total_supply`.
public struct FlushExecuted has copy, drop, store {
    pool_vault_id: ID,
    epoch: u64,
    /// Lower certified pool value used for withdrawal payouts.
    withdraw_pool_value: u64,
    /// Upper certified pool value used for supply share issuance.
    supply_pool_value: u64,
    /// PLP supply in the frozen pre-drain mark pair used to price every fill.
    total_supply: u64,
    /// Sum of the marked NAV contributed by each active market; settled markets add zero.
    active_market_nav: u64,
    /// Certified absolute error on `active_market_nav`.
    active_market_nav_error: u64,
    /// Number of active markets valued for this flush.
    market_count: u64,
    /// Idle DUSDC held by the pool at valuation time, before the drain.
    idle_balance_before: u64,
    supplies_filled: u64,
    withdrawals_filled: u64,
    requests_processed: u64,
    idle_balance_after: u64,
    /// PLP supply after the drain's completed mints and burns.
    total_supply_after: u64,
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

#[test_only]
public fun flush_withdraw_pool_value(event: &FlushExecuted): u64 {
    event.withdraw_pool_value
}

#[test_only]
public fun flush_supply_pool_value(event: &FlushExecuted): u64 {
    event.supply_pool_value
}

// === Public-Package Functions ===

public(package) fun emit_expiry_cash_received(
    pool_vault_id: ID,
    expiry_market_id: ID,
    settlement_price: u64,
    amount: u64,
) {
    event::emit(ExpiryCashReceived {
        pool_vault_id,
        expiry_market_id,
        settlement_price,
        amount,
    });
}

public(package) fun emit_expiry_cash_rebalanced(
    pool_vault_id: ID,
    expiry_market_id: ID,
    amount: u64,
    to_expiry: bool,
    target_cash: u64,
    protocol_profit_realized: u64,
) {
    event::emit(ExpiryCashRebalanced {
        pool_vault_id,
        expiry_market_id,
        amount,
        to_expiry,
        target_cash,
        protocol_profit_realized,
    });
}

public(package) fun emit_expiry_profit_materialized(
    pool_vault_id: ID,
    expiry_market_id: ID,
    lp_profit: u64,
    protocol_profit: u64,
    protocol_reserve_balance_after: u64,
    profit_basis_after: u64,
    pending_protocol_profit_after: u64,
) {
    event::emit(ExpiryProfitMaterialized {
        pool_vault_id,
        expiry_market_id,
        lp_profit,
        protocol_profit,
        protocol_reserve_balance_after,
        profit_basis_after,
        pending_protocol_profit_after,
    });
}

public(package) fun emit_trading_loss_rebate_claimed(
    pool_vault_id: ID,
    expiry_market_id: ID,
    account_id: ID,
    rebate_amount: u64,
    residual_returned: u64,
    trading_fees_paid: u64,
    gross_profit: u64,
) {
    event::emit(TradingLossRebateClaimed {
        pool_vault_id,
        expiry_market_id,
        account_id,
        rebate_amount,
        residual_returned,
        trading_fees_paid,
        gross_profit,
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
    min_plp_out: u64,
    requests_pending_after: u64,
) {
    event::emit(SupplyRequested {
        pool_vault_id,
        account_id,
        recipient,
        index,
        amount,
        min_plp_out,
        requests_pending_after,
    });
}

public(package) fun emit_withdraw_requested(
    pool_vault_id: ID,
    account_id: ID,
    recipient: address,
    index: u64,
    amount: u64,
    min_dusdc_out: u64,
    requests_pending_after: u64,
) {
    event::emit(WithdrawRequested {
        pool_vault_id,
        account_id,
        recipient,
        index,
        amount,
        min_dusdc_out,
        requests_pending_after,
    });
}

public(package) fun emit_request_cancelled(
    pool_vault_id: ID,
    account_id: ID,
    recipient: address,
    index: u64,
    amount: u64,
    is_supply: bool,
    reason: u8,
    requests_pending_after: u64,
) {
    event::emit(RequestCancelled {
        pool_vault_id,
        account_id,
        recipient,
        index,
        amount,
        is_supply,
        reason,
        requests_pending_after,
    });
}

public(package) fun emit_request_limit_missed(
    pool_vault_id: ID,
    account_id: ID,
    recipient: address,
    index: u64,
    amount: u64,
    is_supply: bool,
    quoted_output: u64,
    min_output: u64,
    missed_flushes: u64,
    max_misses: u64,
) {
    event::emit(RequestLimitMissed {
        pool_vault_id,
        account_id,
        recipient,
        index,
        amount,
        is_supply,
        quoted_output,
        min_output,
        missed_flushes,
        max_misses,
    });
}

public(package) fun emit_supply_filled(
    pool_vault_id: ID,
    account_id: ID,
    recipient: address,
    index: u64,
    dusdc_amount: u64,
    shares_minted: u64,
    requests_pending_after: u64,
) {
    event::emit(SupplyFilled {
        pool_vault_id,
        account_id,
        recipient,
        index,
        dusdc_amount,
        shares_minted,
        requests_pending_after,
    });
}

public(package) fun emit_withdraw_filled(
    pool_vault_id: ID,
    account_id: ID,
    recipient: address,
    index: u64,
    shares_burned: u64,
    dusdc_amount: u64,
    requests_pending_after: u64,
) {
    event::emit(WithdrawFilled {
        pool_vault_id,
        account_id,
        recipient,
        index,
        shares_burned,
        dusdc_amount,
        requests_pending_after,
    });
}

public(package) fun emit_flush_executed(
    pool_vault_id: ID,
    epoch: u64,
    withdraw_pool_value: u64,
    supply_pool_value: u64,
    total_supply: u64,
    active_market_nav: u64,
    active_market_nav_error: u64,
    market_count: u64,
    idle_balance_before: u64,
    supplies_filled: u64,
    withdrawals_filled: u64,
    requests_processed: u64,
    idle_balance_after: u64,
    total_supply_after: u64,
) {
    event::emit(FlushExecuted {
        pool_vault_id,
        epoch,
        withdraw_pool_value,
        supply_pool_value,
        total_supply,
        active_market_nav,
        active_market_nav_error,
        market_count,
        idle_balance_before,
        supplies_filled,
        withdrawals_filled,
        requests_processed,
        idle_balance_after,
        total_supply_after,
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
