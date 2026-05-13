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
use sui::{clock::Clock, event};

const EStaleSourceUpdate: u64 = 0;
const EZeroSpot: u64 = 1;
const EFutureSourceUpdate: u64 = 2;

public struct PythSourceUpdated has copy, drop, store {
    pyth_source_id: ID,
    feed_id: u32,
    spot: u64,
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
}

/// Latest normalized spot observed from one Pyth Lazer feed.
public struct PythSource has key {
    id: UID,
    feed_id: u32,
    spot: u64,
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
}

/// Decode and store a verified Pyth Lazer spot update.
public fun update_from_lazer(source: &mut PythSource, update: LazerUpdate, clock: &Clock) {
    let (spot, source_timestamp_us) = lazer_helper::extract_spot(&update, source.feed_id);
    let source_timestamp_ms = us_to_ms_ceil(source_timestamp_us);
    let update_timestamp_ms = clock.timestamp_ms();

    assert!(spot > 0, EZeroSpot);
    assert!(source_timestamp_ms > source.source_timestamp_ms, EStaleSourceUpdate);
    assert!(source_timestamp_ms <= update_timestamp_ms, EFutureSourceUpdate);

    source.spot = spot;
    source.source_timestamp_ms = source_timestamp_ms;
    source.update_timestamp_ms = update_timestamp_ms;
    event::emit(PythSourceUpdated {
        pyth_source_id: source.id.to_inner(),
        feed_id: source.feed_id,
        spot,
        source_timestamp_ms,
        update_timestamp_ms,
    });
}

/// Return the Pyth source object ID.
public fun id(source: &PythSource): ID {
    source.id.to_inner()
}

/// Return the configured Pyth Lazer feed id.
public fun feed_id(source: &PythSource): u32 {
    source.feed_id
}

/// Return the latest normalized spot in Predict's 1e9 price scaling.
public fun spot(source: &PythSource): u64 {
    source.spot
}

/// Return Pyth's source timestamp from the latest accepted update, in milliseconds.
public fun source_timestamp_ms(source: &PythSource): u64 {
    source.source_timestamp_ms
}

/// Return the on-chain timestamp when the latest update landed.
public fun update_timestamp_ms(source: &PythSource): u64 {
    source.update_timestamp_ms
}

// === Public-Package Functions ===

/// Create and share a Pyth source bound to a Lazer feed id.
public(package) fun create_and_share(feed_id: u32, ctx: &mut TxContext): ID {
    let source = PythSource {
        id: object::new(ctx),
        feed_id,
        spot: 0,
        source_timestamp_ms: 0,
        update_timestamp_ms: 0,
    };
    let id = source.id.to_inner();
    transfer::share_object(source);
    id
}

fun us_to_ms_ceil(timestamp_us: u64): u64 {
    let ms = timestamp_us / 1000;
    if (timestamp_us % 1000 == 0) ms else ms + 1
}
