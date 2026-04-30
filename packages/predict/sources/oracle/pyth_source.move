// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Raw Pyth Lazer spot source state.
///
/// This module is intentionally limited to source ingestion and timestamp
/// bookkeeping. It does not decide whether Pyth is authoritative, derive a
/// forward, apply circuit breakers, or settle a market.
module deepbook_predict::pyth_source;

use deepbook_predict::lazer_helper;
use pyth_lazer::update::Update as LazerUpdate;
use sui::clock::Clock;

const EStaleSourceUpdate: u64 = 0;
const EZeroSpot: u64 = 1;

/// Latest normalized spot observed from one Pyth Lazer feed.
public struct PythSource has copy, drop, store {
    feed_id: u32,
    spot: u64,
    source_timestamp_us: u64,
    update_timestamp_ms: u64,
}

/// Create an empty Pyth source bound to a Lazer feed id.
public fun new(feed_id: u32): PythSource {
    PythSource {
        feed_id,
        spot: 0,
        source_timestamp_us: 0,
        update_timestamp_ms: 0,
    }
}

/// Decode and store a verified Pyth Lazer spot update.
public fun update_from_lazer(source: &mut PythSource, update: LazerUpdate, clock: &Clock) {
    let (spot, source_timestamp_us) = lazer_helper::extract_spot(&update, source.feed_id);
    source.update_from_values(spot, source_timestamp_us, clock);
}

/// Store a normalized spot with its source timestamp.
fun update_from_values(
    source: &mut PythSource,
    spot: u64,
    source_timestamp_us: u64,
    clock: &Clock,
) {
    assert!(spot > 0, EZeroSpot);
    assert!(source_timestamp_us > source.source_timestamp_us, EStaleSourceUpdate);
    source.spot = spot;
    source.source_timestamp_us = source_timestamp_us;
    source.update_timestamp_ms = clock.timestamp_ms();
}

/// Return the configured Pyth Lazer feed id.
public fun feed_id(source: &PythSource): u32 {
    source.feed_id
}

/// Return the latest normalized spot in Predict's 1e9 price scaling.
public fun spot(source: &PythSource): u64 {
    source.spot
}

/// Return Pyth's source timestamp from the latest accepted update.
public fun source_timestamp_us(source: &PythSource): u64 {
    source.source_timestamp_us
}

/// Return the on-chain timestamp when the latest update landed.
public fun update_timestamp_ms(source: &PythSource): u64 {
    source.update_timestamp_ms
}
