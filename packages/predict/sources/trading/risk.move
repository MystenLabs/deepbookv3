// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Risk module - validates trades against safety limits.
///
/// Key responsibilities:
/// - Enforce position limits (per-trade, per-market, aggregate)
/// - Check circuit breaker conditions
/// - Validate capital sufficiency
///
/// Position limits:
/// - max_single_trade: min(available_capital * 5%, market_limit - current_exposure)
/// - max_exposure_per_market: vault_capital * 20%
/// - max_total_exposure: vault_capital * 80%
///
/// Circuit breakers (auto-pause trading when triggered):
/// - Oracle stale (> 30s since last update)
/// - Exposure > 90% of limit (allow only redeems)
/// - Utilization > 95% (allow only redeems)
/// - Single market > 50% of total exposure (widen spreads aggressively)
///
/// Capital reservation:
/// - Binary options have bounded payoff: each contract pays $0 or $1
/// - max_liability_per_market = |net_position| * $1
/// - Invariant: vault_balance >= total_max_liability
/// - Reserve capital for markets expiring within 24h
module deepbook_predict::risk;



// === Imports ===

// === Errors ===

// === Public-Package Functions ===

// === Private Functions ===
