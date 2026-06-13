// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Events emitted by `pyth_feed`: feed creation (for off-chain discovery) and
/// accepted spot updates. The update event carries both the publisher (source)
/// timestamp and the on-chain landing timestamp because they are genuinely
/// different values used for freshness.
module propbook::pyth_feed_events;

use sui::event;

/// Emitted when a new feed is created and shared.
public struct PythFeedCreated has copy, drop {
    feed_id: u32,
    pyth_feed_id: ID,
}

/// Emitted when a feed accepts a verified Pyth Lazer spot update.
public struct PythFeedUpdated has copy, drop {
    pyth_feed_id: ID,
    feed_id: u32,
    spot: u64,
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
}

// === Public-Package Functions ===

public(package) fun emit_pyth_feed_created(feed_id: u32, pyth_feed_id: ID) {
    event::emit(PythFeedCreated { feed_id, pyth_feed_id });
}

public(package) fun emit_pyth_feed_updated(
    pyth_feed_id: ID,
    feed_id: u32,
    spot: u64,
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
) {
    event::emit(PythFeedUpdated {
        pyth_feed_id,
        feed_id,
        spot,
        source_timestamp_ms,
        update_timestamp_ms,
    });
}
