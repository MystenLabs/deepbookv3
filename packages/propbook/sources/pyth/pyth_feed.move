// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pyth Lazer spot oracle: a thin wrapper embedding the shared `FeedCore`. It
/// decodes verified Lazer updates, feeds them to the core's validated
/// `store_tick_if_fresh` (asserting freshness — see `update_from_lazer`), and
/// emits its own events. Feed uniqueness per Lazer `feed_id` is enforced by the
/// shared `OracleRegistry`.
///
/// Fully permissionless: anyone can create, update, and migrate feeds — the
/// verified `Update` is its own provenance proof. Predict-unaware: it owns no
/// DUSDC conversion, forward derivation, freshness policy, or settlement; callers
/// own feed binding and freshness (read `freshness_timestamp_ms`).
module propbook::pyth_feed;

use propbook::{
    feed_core::{Self, FeedCore},
    lazer_decode,
    minute_history::DataPoint,
    pyth_feed_events,
    registry::{Self, OracleRegistry}
};
use pyth_lazer::update::Update as LazerUpdate;
use sui::clock::Clock;

/// Pyth keeps strict abort-on-stale: a non-advancing source timestamp aborts.
const EStaleSourceUpdate: u64 = 0;

/// One Pyth Lazer feed: a shared object wrapping the embedded `FeedCore`.
public struct PythFeed has key {
    id: UID,
    core: FeedCore,
}

// === Read Functions ===

/// Return the feed object ID.
public fun id(feed: &PythFeed): ID {
    feed.id.to_inner()
}

/// Return the configured Pyth Lazer feed id.
public fun feed_id(feed: &PythFeed): u32 {
    feed.core.feed_id()
}

/// Return the latest normalized spot in 1e9 price scaling.
public fun spot(feed: &PythFeed): u64 {
    feed.core.spot()
}

/// Return the publisher timestamp of the latest accepted tick, in milliseconds.
public fun source_timestamp_ms(feed: &PythFeed): u64 {
    feed.core.source_timestamp_ms()
}

/// Return the on-chain landing timestamp of the latest accepted tick.
public fun update_timestamp_ms(feed: &PythFeed): u64 {
    feed.core.update_timestamp_ms()
}

/// Freshness reference for consumers: the older of the publisher and on-chain
/// landing timestamps.
public fun freshness_timestamp_ms(feed: &PythFeed): u64 {
    feed.core.freshness_timestamp_ms()
}

/// Return the package version this feed runs at.
public fun version(feed: &PythFeed): u64 {
    feed.core.version()
}

/// Data point recorded for `minute_ms`'s bucket. Aborts if the minute was never
/// recorded; use `has_minute` to check first.
public fun price_at_minute(feed: &PythFeed, minute_ms: u64): DataPoint {
    feed.core.price_at_minute(minute_ms)
}

/// Whether a tick was recorded for `minute_ms`'s bucket.
public fun has_minute(feed: &PythFeed, minute_ms: u64): bool {
    feed.core.has_minute(minute_ms)
}

// === Write Functions ===

/// Decode a verified Pyth Lazer spot update, store it through the core's
/// validated chokepoint, then emit the update event. Permissionless: the verified
/// `LazerUpdate` is its own provenance proof. A non-advancing source timestamp
/// aborts `EStaleSourceUpdate` (strict; pyth has a single value per feed, so a
/// stale tick is never useful).
public fun update_from_lazer(feed: &mut PythFeed, update: LazerUpdate, clock: &Clock) {
    let (spot, source_timestamp_us) = lazer_decode::extract_spot(&update, feed.core.feed_id());
    assert!(
        feed
            .core
            .store_tick_if_fresh(
                spot,
                lazer_decode::us_to_ms_ceil(source_timestamp_us),
                clock.timestamp_ms(),
            ),
        EStaleSourceUpdate,
    );
    pyth_feed_events::emit_pyth_feed_updated(
        feed.id(),
        feed.core.feed_id(),
        feed.core.spot(),
        feed.core.source_timestamp_ms(),
        feed.core.update_timestamp_ms(),
    );
}

/// Create and share a feed for `feed_id`, recording it in the registry so each
/// Lazer feed has exactly one shared `PythFeed`.
///
/// Permissionless and safe: a feed is fully determined by `feed_id` and is shared
/// (no creator advantage), the registry blocks duplicates, and a junk `feed_id`
/// only creates an inert feed (Lazer decode aborts `ELazerFeedNotFound`) whose
/// storage the creator pays for.
public fun create_and_share(registry: &mut OracleRegistry, feed_id: u32, ctx: &mut TxContext): ID {
    let feed = PythFeed { id: object::new(ctx), core: feed_core::new(feed_id, ctx) };
    let id = feed.id();
    // Aborts EFeedAlreadyExists on a duplicate; the tx is atomic, so a dup
    // reverts the object creation above — no orphaned feed.
    registry.record(registry::kind_pyth!(), feed_id, id);
    transfer::share_object(feed);
    pyth_feed_events::emit_pyth_feed_created(feed_id, id);
    id
}

/// Migrate this feed to the running package version (forward-only). See
/// `feed_core::migrate`.
public fun migrate(feed: &mut PythFeed) {
    feed.core.migrate();
}

// === Test-Only Functions ===

/// Apply an already-decoded tick straight through the same strict wrapper as
/// `update_from_lazer` (assert-on-stale) — the thin seam an integration test uses
/// to prove a tick flows into the embedded core and the stale-abort path holds,
/// since a real `pyth_lazer::Update` has no Move-side test constructor.
#[test_only]
public fun store_tick_for_testing(
    feed: &mut PythFeed,
    spot: u64,
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
) {
    assert!(
        feed.core.store_tick_if_fresh(spot, source_timestamp_ms, update_timestamp_ms),
        EStaleSourceUpdate,
    );
}
