// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Canonical market-data selection over raw oracle sources.
///
/// The meta oracle reads Pyth spot and Block Scholes price/SVI state, applies
/// freshness policy, and returns the values downstream pricing should use. It
/// does not ingest source updates, compute binary prices, apply trade fees, or
/// settle markets.
module deepbook_predict::meta_oracle;

use deepbook::math;
use deepbook_predict::{
    market_oracle::{Self, MarketOracle, SVIParams},
    pyth_source::PythSource
};
use sui::clock::Clock;

const EBlockScholesPriceNotSeeded: u64 = 1;
const EBlockScholesSVINotSeeded: u64 = 2;
const EBlockScholesBasisStale: u64 = 3;
const EBlockScholesSVIStale: u64 = 4;
const EMarketNotActive: u64 = 6;

const SOURCE_DERIVED: u8 = 3;

/// Source-data and on-chain update timestamps for one canonical value.
public struct ValueTimestamps has copy, drop, store {
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
}

/// Canonical market-data snapshot consumed by downstream pricing.
public struct CanonicalSnapshot has copy, drop, store {
    spot: u64,
    forward: u64,
    basis: u64,
    svi: SVIParams,
    spot_source: u8,
    forward_source: u8,
    spot_timestamps: ValueTimestamps,
    forward_timestamps: ValueTimestamps,
    basis_timestamps: ValueTimestamps,
    svi_timestamps: ValueTimestamps,
}

// === Public Functions ===

/// Return the source code for Pyth-sourced values.
public fun source_pyth(): u8 {
    market_oracle::source_pyth()
}

/// Return the source code for Block Scholes-sourced values.
public fun source_block_scholes(): u8 {
    market_oracle::source_block_scholes()
}

/// Return the source code for values derived from more than one source.
public fun source_derived(): u8 {
    SOURCE_DERIVED
}

/// Build the canonical live snapshot for one market oracle.
public fun build_live_snapshot(
    market: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
): CanonicalSnapshot {
    market.assert_pyth_source_id(pyth.id());
    assert!(market.status(clock) == market_oracle::status_active(), EMarketNotActive);
    let bounds = market.bounds();

    assert_block_scholes_seeded(market);
    assert!(
        market_oracle::block_scholes_price_is_fresh(
            market,
            clock,
            market_oracle::bounds_block_scholes_price_freshness_ms(&bounds),
        ),
        EBlockScholesBasisStale,
    );
    assert!(
        market_oracle::block_scholes_svi_is_fresh(
            market,
            clock,
            market_oracle::bounds_block_scholes_svi_freshness_ms(&bounds),
        ),
        EBlockScholesSVIStale,
    );

    let (spot, spot_source, spot_source_timestamp_ms, spot_update_timestamp_ms) =
        market_oracle::select_live_spot(market, pyth, clock);
    let spot_timestamps = ValueTimestamps {
        source_timestamp_ms: spot_source_timestamp_ms,
        update_timestamp_ms: spot_update_timestamp_ms,
    };
    let basis = market.block_scholes_basis();
    let svi = market.block_scholes_svi();
    let block_scholes_price_timestamps = block_scholes_price_timestamps(market);
    let block_scholes_svi_timestamps = block_scholes_svi_timestamps(market);

    if (spot_source == market_oracle::source_pyth()) {
        let forward_timestamps = merge_timestamps(
            &spot_timestamps,
            &block_scholes_price_timestamps,
        );

        CanonicalSnapshot {
            spot,
            forward: math::mul(spot, basis),
            basis,
            svi,
            spot_source: market_oracle::source_pyth(),
            forward_source: SOURCE_DERIVED,
            spot_timestamps,
            forward_timestamps,
            basis_timestamps: block_scholes_price_timestamps,
            svi_timestamps: block_scholes_svi_timestamps,
        }
    } else {
        CanonicalSnapshot {
            spot,
            forward: market.block_scholes_forward(),
            basis,
            svi,
            spot_source: market_oracle::source_block_scholes(),
            forward_source: market_oracle::source_block_scholes(),
            spot_timestamps,
            forward_timestamps: block_scholes_price_timestamps,
            basis_timestamps: block_scholes_price_timestamps,
            svi_timestamps: block_scholes_svi_timestamps,
        }
    }
}

/// Return the canonical spot.
public fun spot(snapshot: &CanonicalSnapshot): u64 {
    snapshot.spot
}

/// Return the canonical forward.
public fun forward(snapshot: &CanonicalSnapshot): u64 {
    snapshot.forward
}

/// Return the canonical basis.
public fun basis(snapshot: &CanonicalSnapshot): u64 {
    snapshot.basis
}

/// Return the canonical SVI parameters.
public fun svi(snapshot: &CanonicalSnapshot): SVIParams {
    snapshot.svi
}

/// Return the source code for the canonical spot.
public fun spot_source(snapshot: &CanonicalSnapshot): u8 {
    snapshot.spot_source
}

/// Return the source code for the canonical forward.
public fun forward_source(snapshot: &CanonicalSnapshot): u8 {
    snapshot.forward_source
}

/// Return timestamps for the canonical spot.
public fun spot_timestamps(snapshot: &CanonicalSnapshot): ValueTimestamps {
    snapshot.spot_timestamps
}

/// Return timestamps for the canonical forward.
public fun forward_timestamps(snapshot: &CanonicalSnapshot): ValueTimestamps {
    snapshot.forward_timestamps
}

/// Return timestamps for the canonical basis.
public fun basis_timestamps(snapshot: &CanonicalSnapshot): ValueTimestamps {
    snapshot.basis_timestamps
}

/// Return timestamps for the canonical SVI.
public fun svi_timestamps(snapshot: &CanonicalSnapshot): ValueTimestamps {
    snapshot.svi_timestamps
}

/// Return a value's source-data timestamp.
public fun source_timestamp_ms(timestamps: &ValueTimestamps): u64 {
    timestamps.source_timestamp_ms
}

/// Return the on-chain timestamp when a value's source data landed.
public fun update_timestamp_ms(timestamps: &ValueTimestamps): u64 {
    timestamps.update_timestamp_ms
}

// === Private Functions ===

fun assert_block_scholes_seeded(market: &MarketOracle) {
    assert!(market.block_scholes_price_source_timestamp_ms() > 0, EBlockScholesPriceNotSeeded);
    assert!(market.block_scholes_svi_source_timestamp_ms() > 0, EBlockScholesSVINotSeeded);
}

fun block_scholes_price_timestamps(market: &MarketOracle): ValueTimestamps {
    ValueTimestamps {
        source_timestamp_ms: market.block_scholes_price_source_timestamp_ms(),
        update_timestamp_ms: market.block_scholes_price_update_timestamp_ms(),
    }
}

fun block_scholes_svi_timestamps(market: &MarketOracle): ValueTimestamps {
    ValueTimestamps {
        source_timestamp_ms: market.block_scholes_svi_source_timestamp_ms(),
        update_timestamp_ms: market.block_scholes_svi_update_timestamp_ms(),
    }
}

fun merge_timestamps(a: &ValueTimestamps, b: &ValueTimestamps): ValueTimestamps {
    ValueTimestamps {
        source_timestamp_ms: min(a.source_timestamp_ms, b.source_timestamp_ms),
        update_timestamp_ms: min(a.update_timestamp_ms, b.update_timestamp_ms),
    }
}

fun min(a: u64, b: u64): u64 {
    if (a < b) a else b
}
