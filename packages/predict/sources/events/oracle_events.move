// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Oracle value-update and settlement events for Predict.
///
/// Each carries both the source-data timestamp and the on-chain landing
/// timestamp because they are genuinely different values used for freshness.
module deepbook_predict::oracle_events;

use predict_math::i64::I64;
use sui::event;

/// Emitted when Block Scholes spot/forward data is accepted.
public struct BlockScholesPricesUpdated has copy, drop, store {
    market_oracle_id: ID,
    spot: u64,
    forward: u64,
    basis: u64,
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
}

/// Emitted when Block Scholes SVI data is accepted.
public struct BlockScholesSVIUpdated has copy, drop, store {
    market_oracle_id: ID,
    a: u64,
    b: u64,
    rho: I64,
    m: I64,
    sigma: u64,
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
}

/// Emitted when a verified Pyth Lazer spot update is accepted.
public struct PythSourceUpdated has copy, drop, store {
    pyth_source_id: ID,
    feed_id: u32,
    spot: u64,
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
}

/// Emitted when the oracle records terminal settlement.
public struct MarketOracleSettled has copy, drop, store {
    market_oracle_id: ID,
    expiry: u64,
    settlement_price: u64,
    /// `1` means sampled Pyth, `2` post-expiry Pyth, `3` sampled Block
    /// Scholes, and `4` post-expiry Block Scholes.
    spot_source: u8,
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
}

// === Public-Package Functions ===

public(package) fun emit_block_scholes_prices_updated(
    market_oracle_id: ID,
    spot: u64,
    forward: u64,
    basis: u64,
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
) {
    event::emit(BlockScholesPricesUpdated {
        market_oracle_id,
        spot,
        forward,
        basis,
        source_timestamp_ms,
        update_timestamp_ms,
    });
}

public(package) fun emit_block_scholes_svi_updated(
    market_oracle_id: ID,
    a: u64,
    b: u64,
    rho: I64,
    m: I64,
    sigma: u64,
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
) {
    event::emit(BlockScholesSVIUpdated {
        market_oracle_id,
        a,
        b,
        rho,
        m,
        sigma,
        source_timestamp_ms,
        update_timestamp_ms,
    });
}

public(package) fun emit_pyth_source_updated(
    pyth_source_id: ID,
    feed_id: u32,
    spot: u64,
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
) {
    event::emit(PythSourceUpdated {
        pyth_source_id,
        feed_id,
        spot,
        source_timestamp_ms,
        update_timestamp_ms,
    });
}

public(package) fun emit_market_oracle_settled(
    market_oracle_id: ID,
    expiry: u64,
    settlement_price: u64,
    spot_source: u8,
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
) {
    event::emit(MarketOracleSettled {
        market_oracle_id,
        expiry,
        settlement_price,
        spot_source,
        source_timestamp_ms,
        update_timestamp_ms,
    });
}
