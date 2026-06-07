// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pool-vault lifecycle events for Predict.
///
/// These are low-frequency relative to trades, so they are rich: supply and
/// withdraw carry the pool value used to price shares, and expiry cash receipts
/// carry the pool-owned expiry cash-flow movements.
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
    /// Pool NAV used to price the mint, in DUSDC base units. Includes the
    /// `incentive_value` slice below; subtract it to get the DUSDC-only NAV,
    /// which is the basis `WithdrawExecuted.pool_value_before` reports.
    pool_value_before: u64,
    /// DUSDC-denominated value of vested SUI/DEEP incentives folded into
    /// `pool_value_before`. Withdraw prices the DUSDC payout on the DUSDC-only
    /// NAV (incentives paid in-kind), so this field makes the two bases comparable.
    incentive_value: u64,
    total_supply_after: u64,
    idle_balance_after: u64,
}

/// Emitted when PLP shares are burned and DUSDC is withdrawn.
public struct WithdrawExecuted has copy, drop, store {
    pool_vault_id: ID,
    shares_burned: u64,
    payout: u64,
    pool_value_before: u64,
    total_supply_after: u64,
    idle_balance_after: u64,
}

/// Emitted when live expiry cash is rebalanced against current backing needs.
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

/// Emitted when an expiry's max net pool funding cap changes.
public struct ExpiryMaxFundingUpdated has copy, drop, store {
    pool_vault_id: ID,
    expiry_market_id: ID,
    max_expiry_funding: u64,
    net_funding: u64,
}

/// Emitted when an expiry returns cash to the pool.
public struct ExpiryCashReceived has copy, drop, store {
    pool_vault_id: ID,
    expiry_market_id: ID,
    settlement_price: u64,
    amount: u64,
    idle_balance_after: u64,
    sent_to_expiry_after: u64,
    received_from_expiry_after: u64,
}

/// Emitted when terminal expiry profit is split between LPs and protocol reserves.
public struct ExpiryProfitMaterialized has copy, drop, store {
    pool_vault_id: ID,
    expiry_market_id: ID,
    lp_profit: u64,
    protocol_profit: u64,
    idle_balance_after: u64,
    protocol_reserve_balance_after: u64,
    profit_basis_after: u64,
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

public(package) fun emit_supply_executed(
    pool_vault_id: ID,
    payment: u64,
    shares_minted: u64,
    pool_value_before: u64,
    incentive_value: u64,
    total_supply_after: u64,
    idle_balance_after: u64,
) {
    event::emit(SupplyExecuted {
        pool_vault_id,
        payment,
        shares_minted,
        pool_value_before,
        incentive_value,
        total_supply_after,
        idle_balance_after,
    });
}

public(package) fun emit_withdraw_executed(
    pool_vault_id: ID,
    shares_burned: u64,
    payout: u64,
    pool_value_before: u64,
    total_supply_after: u64,
    idle_balance_after: u64,
) {
    event::emit(WithdrawExecuted {
        pool_vault_id,
        shares_burned,
        payout,
        pool_value_before,
        total_supply_after,
        idle_balance_after,
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

public(package) fun emit_expiry_max_funding_updated(
    pool_vault_id: ID,
    expiry_market_id: ID,
    max_expiry_funding: u64,
    net_funding: u64,
) {
    event::emit(ExpiryMaxFundingUpdated {
        pool_vault_id,
        expiry_market_id,
        max_expiry_funding,
        net_funding,
    });
}

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
