// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Shared spot-feed core embedded by every propbook oracle: the latest normalized
/// 1e9-scaled spot with its publisher/landing timestamps, the package-version
/// gate, and the minute-bucket history. `store_tick_if_fresh` is the single
/// validated ingest chokepoint — an oracle module decodes its own payload, calls
/// it, and emits its own event when it returns true (the spot advanced).
///
/// Freshness is no-op-on-stale, not abort-on-stale: a non-advancing source
/// timestamp leaves the spot untouched and returns false (the same update may
/// still advance a sibling surface). Version/zero-spot/future-timestamp always
/// abort. A wrapper that wants strict abort-on-stale (pyth) asserts the return.
module propbook::feed_core;

use propbook::{constants, minute_history::{Self, MinuteHistory, DataPoint}};

const EZeroSpot: u64 = 0;
const EFutureSourceUpdate: u64 = 1;
const EWrongVersion: u64 = 2;
const ENotNewerVersion: u64 = 3;

/// The latest accepted spot plus the version gate and minute-bucket history that
/// every oracle shares. Embedded (not shared on its own) by an oracle object.
public struct FeedCore has store {
    feed_id: u32,
    /// Latest accepted spot, in 1e9 price scaling.
    spot: u64,
    /// Publisher timestamp of the latest accepted tick, in milliseconds.
    source_timestamp_ms: u64,
    /// On-chain landing timestamp of the latest accepted tick.
    update_timestamp_ms: u64,
    /// Package version this feed runs at; updates require an exact match and
    /// `migrate` advances it forward-only after a package upgrade.
    version: u64,
    minutes: MinuteHistory,
}

// === Public-Package Functions ===

public(package) fun feed_id(core: &FeedCore): u32 {
    core.feed_id
}

public(package) fun spot(core: &FeedCore): u64 {
    core.spot
}

public(package) fun source_timestamp_ms(core: &FeedCore): u64 {
    core.source_timestamp_ms
}

public(package) fun update_timestamp_ms(core: &FeedCore): u64 {
    core.update_timestamp_ms
}

/// The older of the publisher and on-chain landing timestamps.
public(package) fun freshness_timestamp_ms(core: &FeedCore): u64 {
    core.source_timestamp_ms.min(core.update_timestamp_ms)
}

public(package) fun version(core: &FeedCore): u64 {
    core.version
}

/// Data point recorded for `minute_ms`'s bucket. Aborts if the minute was never
/// recorded; use `has_minute` to check first.
public(package) fun price_at_minute(core: &FeedCore, minute_ms: u64): DataPoint {
    core.minutes.price_at_minute(minute_ms)
}

/// Whether a tick was recorded for `minute_ms`'s bucket.
public(package) fun has_minute(core: &FeedCore, minute_ms: u64): bool {
    core.minutes.has_minute(minute_ms)
}

public(package) fun new(feed_id: u32, ctx: &mut TxContext): FeedCore {
    FeedCore {
        feed_id,
        spot: 0,
        source_timestamp_ms: 0,
        update_timestamp_ms: 0,
        version: constants::current_version!(),
        minutes: minute_history::new(ctx),
    }
}

/// The single validated ingest chokepoint. Always gates the running version, a
/// zero spot, and a future source timestamp (even when the spot turns out stale,
/// because the same update may still advance a sibling surface). Writes the
/// latest fields and records the minute bucket only when `source_timestamp_ms`
/// strictly advances; returns whether the spot advanced.
public(package) fun store_tick_if_fresh(
    core: &mut FeedCore,
    spot: u64,
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
): bool {
    assert!(core.version == constants::current_version!(), EWrongVersion);
    assert!(spot > 0, EZeroSpot);
    assert!(source_timestamp_ms <= update_timestamp_ms, EFutureSourceUpdate);

    if (source_timestamp_ms > core.source_timestamp_ms) {
        core.spot = spot;
        core.source_timestamp_ms = source_timestamp_ms;
        core.update_timestamp_ms = update_timestamp_ms;
        core
            .minutes
            .record(minute_history::new_data_point(spot, source_timestamp_ms, update_timestamp_ms));
        true
    } else {
        false
    }
}

/// Migrate the core to the running package version. Forward-only:
/// `current_version!()` is compiled into each package version's bytecode (callers
/// cannot inject an arbitrary version), and the strictly-greater check blocks
/// downgrade griefing. Every package upgrade MUST bump `current_version!()`.
public(package) fun migrate(core: &mut FeedCore) {
    assert!(constants::current_version!() > core.version, ENotNewerVersion);
    core.version = constants::current_version!();
}

// === Test-Only Functions ===

/// Set the core's package version directly to simulate a feed created under a
/// different package version; cross-upgrade version states cannot otherwise be
/// constructed in a unit test.
#[test_only]
public(package) fun set_version_for_testing(core: &mut FeedCore, version: u64) {
    core.version = version;
}
