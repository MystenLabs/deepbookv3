// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Oracle module for the Predict protocol.
///
/// Manages external price data from Block Scholes:
/// - `Oracle<Asset>` shared object (one per underlying + expiry)
/// - `OracleCap` capability for Block Scholes to create oracles and push updates
///
/// Key responsibilities:
/// - Receive and store volatility surface updates (~1 update/second)
/// - Provide spot price and implied volatility for pricing calculations
/// - Staleness checks (data older than 30s is considered stale)
/// - Freeze settlement price on first update after expiry
///
/// The volatility surface allows pricing multiple strikes from a single oracle per expiry.
module deepbook_predict::oracle;

use deepbook_predict::registry::AdminCap;
use sui::clock::Clock;

// === Errors ===
const EInvalidOracleCap: u64 = 0;
const EOracleStale: u64 = 1;
const ENotSettled: u64 = 2;
const EAlreadySettled: u64 = 3;

// === Structs ===

/// Shared object storing price data for one underlying + expiry combination.
/// Created by Block Scholes using OracleCap.
public struct Oracle<phantom Asset> has key {
    id: UID,
    /// ID of the OracleCap that created this oracle
    oracle_cap_id: ID,
    /// Expiration timestamp in milliseconds
    expiry: u64,
    // === Live Data (updated by Block Scholes) ===
    /// Current spot price of the underlying asset
    spot_price: u64,
    /// Implied volatility at various strikes for interpolation
    volatility_surface: vector<VolPoint>,
    /// Risk-free rate for Black-Scholes calculation
    risk_free_rate: u64,
    /// Timestamp of last update in milliseconds
    timestamp: u64,
    // === Settlement ===
    /// Frozen on first update where timestamp > expiry
    settlement_price: Option<u64>,
}

/// A point on the volatility surface: IV at a specific strike.
public struct VolPoint has copy, drop, store {
    strike: u64,
    implied_volatility: u64,
}

/// Capability for Block Scholes to create oracles and push updates.
/// Created by admin, transferred to Block Scholes operator.
public struct OracleCap has key, store {
    id: UID,
}

// === Public Functions ===

/// Create a new OracleCap. Called by admin, transferred to Block Scholes.
public fun create_oracle_cap(_admin_cap: &AdminCap, ctx: &mut TxContext): OracleCap {
    OracleCap { id: object::new(ctx) }
}

/// Create a new Oracle for an underlying asset and expiry.
/// Called by Block Scholes using their OracleCap.
public fun create_oracle<Asset>(cap: &OracleCap, expiry: u64, clock: &Clock, ctx: &mut TxContext) {
    abort 0
}

/// Push new price and volatility data to an oracle.
/// Called by Block Scholes (~1 update/second).
/// If timestamp > expiry and settlement_price is None, freezes settlement price.
public fun update<Asset>(
    oracle: &mut Oracle<Asset>,
    cap: &OracleCap,
    spot_price: u64,
    volatility_surface: vector<VolPoint>,
    risk_free_rate: u64,
    clock: &Clock,
) {
    abort 0
}

// === Public View Functions ===

/// Get the current spot price.
public fun spot_price<Asset>(oracle: &Oracle<Asset>): u64 {
    oracle.spot_price
}

/// Get the expiry timestamp.
public fun expiry<Asset>(oracle: &Oracle<Asset>): u64 {
    oracle.expiry
}

/// Get the risk-free rate.
public fun risk_free_rate<Asset>(oracle: &Oracle<Asset>): u64 {
    oracle.risk_free_rate
}

/// Get the last update timestamp.
public fun timestamp<Asset>(oracle: &Oracle<Asset>): u64 {
    oracle.timestamp
}

/// Get the settlement price (only valid after settlement).
public fun settlement_price<Asset>(oracle: &Oracle<Asset>): Option<u64> {
    oracle.settlement_price
}

/// Check if the oracle data is stale (> 30s since last update).
public fun is_stale<Asset>(oracle: &Oracle<Asset>, clock: &Clock): bool {
    abort 0
}

/// Check if the oracle has been settled (settlement price frozen).
public fun is_settled<Asset>(oracle: &Oracle<Asset>): bool {
    oracle.settlement_price.is_some()
}

// === Public-Package Functions ===

/// Get interpolated implied volatility for a specific strike.
/// Uses linear interpolation between nearest points on the volatility surface.
public(package) fun get_iv<Asset>(oracle: &Oracle<Asset>, strike: u64): u64 {
    abort 0
}

/// Assert that the oracle is not stale. Aborts if stale.
public(package) fun assert_not_stale<Asset>(oracle: &Oracle<Asset>, clock: &Clock) {
    assert!(!is_stale(oracle, clock), EOracleStale);
}

/// Get all pricing data in one call for efficiency.
/// Returns (spot_price, implied_volatility, risk_free_rate, time_to_expiry_ms).
public(package) fun get_pricing_data<Asset>(
    oracle: &Oracle<Asset>,
    strike: u64,
    clock: &Clock,
): (u64, u64, u64, u64) {
    abort 0
}

// === Private Functions ===
