// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pool-vault lifecycle events for Predict.
///
/// These are low-frequency relative to trades, so they are rich: supply and
/// withdraw carry the pool value used to price shares, and settled-expiry
/// sweeps carry the pool-owned expiry cash-flow movements.
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

/// Emitted when the pool funds a newly created expiry.
public struct ExpiryCashFunded has copy, drop, store {
    pool_vault_id: ID,
    expiry_market_id: ID,
    funding: u64,
    idle_balance_after: u64,
    sent_to_expiry_after: u64,
    received_from_expiry_after: u64,
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

/// Emitted when a settled expiry returns surplus cash.
public struct ExpirySurplusSwept has copy, drop, store {
    pool_vault_id: ID,
    expiry_market_id: ID,
    settlement_price: u64,
    /// Surplus cash returned to the pool this sweep.
    returned_cash: u64,
    idle_balance_after: u64,
    sent_to_expiry_after: u64,
    received_from_expiry_after: u64,
}

/// Emitted when aggregate returned expiry cash is split between LPs and protocol reserves.
public struct ExpiryProfitMaterialized has copy, drop, store {
    pool_vault_id: ID,
    profit: u64,
    lp_profit: u64,
    protocol_profit: u64,
    idle_balance_after: u64,
    protocol_reserve_balance_after: u64,
    profit_basis_debits_after: u64,
    profit_basis_credits_after: u64,
}

// === Public-Package Functions ===

public(package) fun emit_supply_executed(
    pool_vault_id: ID,
    payment: u64,
    shares_minted: u64,
    pool_value_before: u64,
    total_supply_after: u64,
    idle_balance_after: u64,
) {
    event::emit(SupplyExecuted {
        pool_vault_id,
        payment,
        shares_minted,
        pool_value_before,
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

public(package) fun emit_expiry_cash_funded(
    pool_vault_id: ID,
    expiry_market_id: ID,
    funding: u64,
    idle_balance_after: u64,
    sent_to_expiry_after: u64,
    received_from_expiry_after: u64,
) {
    event::emit(ExpiryCashFunded {
        pool_vault_id,
        expiry_market_id,
        funding,
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

public(package) fun emit_expiry_surplus_swept(
    pool_vault_id: ID,
    expiry_market_id: ID,
    settlement_price: u64,
    returned_cash: u64,
    idle_balance_after: u64,
    sent_to_expiry_after: u64,
    received_from_expiry_after: u64,
) {
    event::emit(ExpirySurplusSwept {
        pool_vault_id,
        expiry_market_id,
        settlement_price,
        returned_cash,
        idle_balance_after,
        sent_to_expiry_after,
        received_from_expiry_after,
    });
}

public(package) fun emit_expiry_profit_materialized(
    pool_vault_id: ID,
    profit: u64,
    lp_profit: u64,
    protocol_profit: u64,
    idle_balance_after: u64,
    protocol_reserve_balance_after: u64,
    profit_basis_debits_after: u64,
    profit_basis_credits_after: u64,
) {
    event::emit(ExpiryProfitMaterialized {
        pool_vault_id,
        profit,
        lp_profit,
        protocol_profit,
        idle_balance_after,
        protocol_reserve_balance_after,
        profit_basis_debits_after,
        profit_basis_credits_after,
    });
}
