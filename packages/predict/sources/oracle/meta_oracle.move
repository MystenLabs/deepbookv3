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
    block_scholes_source::{BlockScholesSource, SVIParams},
    pyth_source::PythSource,
    tuning_constants
};
use sui::clock::Clock;

const EInvalidFreshnessThreshold: u64 = 0;
const EBlockScholesPriceNotSeeded: u64 = 1;
const EBlockScholesSVINotSeeded: u64 = 2;
const EBlockScholesBasisStale: u64 = 3;
const EBlockScholesSVIStale: u64 = 4;
const EBlockScholesSpotFallbackStale: u64 = 5;

const SOURCE_PYTH: u8 = 1;
const SOURCE_BLOCK_SCHOLES: u8 = 2;
const SOURCE_DERIVED: u8 = 3;

/// Source-data and on-chain update timestamps for one canonical value.
public struct ValueTimestamps has copy, drop, store {
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
}

/// Freshness thresholds used when selecting canonical oracle values.
public struct MetaOracleConfig has copy, drop, store {
    pyth_spot_freshness_ms: u64,
    block_scholes_basis_freshness_ms: u64,
    block_scholes_spot_fallback_freshness_ms: u64,
    block_scholes_svi_freshness_ms: u64,
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
    SOURCE_PYTH
}

/// Return the source code for Block Scholes-sourced values.
public fun source_block_scholes(): u8 {
    SOURCE_BLOCK_SCHOLES
}

/// Return the source code for values derived from more than one source.
public fun source_derived(): u8 {
    SOURCE_DERIVED
}

/// Create freshness config from explicit thresholds.
public fun new_config(
    pyth_spot_freshness_ms: u64,
    block_scholes_basis_freshness_ms: u64,
    block_scholes_spot_fallback_freshness_ms: u64,
    block_scholes_svi_freshness_ms: u64,
): MetaOracleConfig {
    validate_freshness_ms(pyth_spot_freshness_ms);
    validate_freshness_ms(block_scholes_basis_freshness_ms);
    validate_freshness_ms(block_scholes_spot_fallback_freshness_ms);
    validate_freshness_ms(block_scholes_svi_freshness_ms);

    MetaOracleConfig {
        pyth_spot_freshness_ms,
        block_scholes_basis_freshness_ms,
        block_scholes_spot_fallback_freshness_ms,
        block_scholes_svi_freshness_ms,
    }
}

/// Create freshness config using current Predict oracle defaults.
public fun default_config(): MetaOracleConfig {
    new_config(
        tuning_constants::default_lazer_authoritative_threshold_ms!(),
        tuning_constants::default_basis_staleness_threshold_ms!(),
        tuning_constants::default_spot_staleness_threshold_ms!(),
        tuning_constants::default_basis_staleness_threshold_ms!(),
    )
}

/// Build the canonical snapshot from raw Pyth and Block Scholes source state.
///
/// Pyth supplies spot while fresh. Block Scholes always supplies basis and SVI;
/// when Pyth spot is stale, Block Scholes also supplies the fallback spot and
/// forward if its price update is inside the stricter fallback freshness
/// window.
public fun build_snapshot(
    config: &MetaOracleConfig,
    pyth: &PythSource,
    block_scholes: &BlockScholesSource,
    clock: &Clock,
): CanonicalSnapshot {
    assert_block_scholes_seeded(block_scholes);
    assert!(
        block_scholes_basis_is_fresh(config, block_scholes, clock),
        EBlockScholesBasisStale,
    );
    assert!(
        block_scholes_svi_is_fresh(config, block_scholes, clock),
        EBlockScholesSVIStale,
    );

    let basis = block_scholes.basis();
    let svi = block_scholes.svi();
    let block_scholes_price_timestamps = block_scholes_price_timestamps(block_scholes);
    let block_scholes_svi_timestamps = block_scholes_svi_timestamps(block_scholes);

    if (pyth_spot_is_fresh(config, pyth, clock)) {
        let spot = pyth.spot();
        let pyth_timestamps = pyth_spot_timestamps(pyth);
        let forward_timestamps = merge_timestamps(&pyth_timestamps, &block_scholes_price_timestamps);

        CanonicalSnapshot {
            spot,
            forward: math::mul(spot, basis),
            basis,
            svi,
            spot_source: SOURCE_PYTH,
            forward_source: SOURCE_DERIVED,
            spot_timestamps: pyth_timestamps,
            forward_timestamps,
            basis_timestamps: block_scholes_price_timestamps,
            svi_timestamps: block_scholes_svi_timestamps,
        }
    } else {
        assert!(
            block_scholes_spot_fallback_is_fresh(config, block_scholes, clock),
            EBlockScholesSpotFallbackStale,
        );

        CanonicalSnapshot {
            spot: block_scholes.spot(),
            forward: block_scholes.forward(),
            basis,
            svi,
            spot_source: SOURCE_BLOCK_SCHOLES,
            forward_source: SOURCE_BLOCK_SCHOLES,
            spot_timestamps: block_scholes_price_timestamps,
            forward_timestamps: block_scholes_price_timestamps,
            basis_timestamps: block_scholes_price_timestamps,
            svi_timestamps: block_scholes_svi_timestamps,
        }
    }
}

/// Return whether Pyth spot is fresh under the configured threshold.
public fun pyth_spot_is_fresh(
    config: &MetaOracleConfig,
    pyth: &PythSource,
    clock: &Clock,
): bool {
    timestamps_are_fresh(
        clock.timestamp_ms(),
        pyth.source_timestamp_us() / 1000,
        pyth.update_timestamp_ms(),
        config.pyth_spot_freshness_ms,
    )
}

/// Return whether Block Scholes basis can be used.
public fun block_scholes_basis_is_fresh(
    config: &MetaOracleConfig,
    block_scholes: &BlockScholesSource,
    clock: &Clock,
): bool {
    timestamps_are_fresh(
        clock.timestamp_ms(),
        block_scholes.price_source_timestamp_ms(),
        block_scholes.price_update_timestamp_ms(),
        config.block_scholes_basis_freshness_ms,
    )
}

/// Return whether Block Scholes can be used as the spot/forward fallback.
public fun block_scholes_spot_fallback_is_fresh(
    config: &MetaOracleConfig,
    block_scholes: &BlockScholesSource,
    clock: &Clock,
): bool {
    timestamps_are_fresh(
        clock.timestamp_ms(),
        block_scholes.price_source_timestamp_ms(),
        block_scholes.price_update_timestamp_ms(),
        config.block_scholes_spot_fallback_freshness_ms,
    )
}

/// Return whether Block Scholes SVI can be used.
public fun block_scholes_svi_is_fresh(
    config: &MetaOracleConfig,
    block_scholes: &BlockScholesSource,
    clock: &Clock,
): bool {
    timestamps_are_fresh(
        clock.timestamp_ms(),
        block_scholes.svi_source_timestamp_ms(),
        block_scholes.svi_update_timestamp_ms(),
        config.block_scholes_svi_freshness_ms,
    )
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

fun validate_freshness_ms(value: u64) {
    assert!(
        value > 0 && value <= tuning_constants::max_staleness_threshold_ms!(),
        EInvalidFreshnessThreshold,
    );
}

fun assert_block_scholes_seeded(block_scholes: &BlockScholesSource) {
    assert!(block_scholes.price_source_timestamp_ms() > 0, EBlockScholesPriceNotSeeded);
    assert!(block_scholes.svi_source_timestamp_ms() > 0, EBlockScholesSVINotSeeded);
}

fun timestamps_are_fresh(
    now_ms: u64,
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
    freshness_ms: u64,
): bool {
    timestamp_is_fresh(now_ms, source_timestamp_ms, freshness_ms)
        && timestamp_is_fresh(now_ms, update_timestamp_ms, freshness_ms)
}

fun timestamp_is_fresh(now_ms: u64, timestamp_ms: u64, freshness_ms: u64): bool {
    if (timestamp_ms == 0) return false;
    now_ms <= timestamp_ms || now_ms - timestamp_ms <= freshness_ms
}

fun pyth_spot_timestamps(pyth: &PythSource): ValueTimestamps {
    ValueTimestamps {
        source_timestamp_ms: pyth.source_timestamp_us() / 1000,
        update_timestamp_ms: pyth.update_timestamp_ms(),
    }
}

fun block_scholes_price_timestamps(block_scholes: &BlockScholesSource): ValueTimestamps {
    ValueTimestamps {
        source_timestamp_ms: block_scholes.price_source_timestamp_ms(),
        update_timestamp_ms: block_scholes.price_update_timestamp_ms(),
    }
}

fun block_scholes_svi_timestamps(block_scholes: &BlockScholesSource): ValueTimestamps {
    ValueTimestamps {
        source_timestamp_ms: block_scholes.svi_source_timestamp_ms(),
        update_timestamp_ms: block_scholes.svi_update_timestamp_ms(),
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
