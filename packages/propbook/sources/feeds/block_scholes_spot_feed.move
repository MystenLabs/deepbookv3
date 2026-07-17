// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Stores the Block Scholes spot stream for one source in a shared Propbook oracle lane.
/// Writes require the verifier-produced `SpotUpdate` type and must match the feed's immutable source ID.
/// Canonical feed binding, freshness, and pricing policy remain consumer responsibilities.
module propbook::block_scholes_spot_feed;

use block_scholes_oracle::update::SpotUpdate;
use propbook::{constants, oracle_lane::{Self, OracleLane, OracleRead}};
use sui::clock::Clock;

const EWrongSource: u64 = 0;
const ERawSpotNotFound: u64 = 1;
const EWrongVersion: u64 = 2;
const ENotNewerVersion: u64 = 3;

/// Source-native Block Scholes spot fields; the lane supplies publication and recording timestamps.
public struct RawSpot has copy, drop, store {
    bs_source_id: u32,
    spot: u64,
}

/// A versioned Block Scholes spot feed bound to one source ID.
public struct BlockScholesSpotFeed has key {
    id: UID,
    bs_source_id: u32,
    /// Package version this feed runs at; updates require an exact match and
    /// `migrate` advances it forward-only after a package upgrade.
    version: u64,
    lane: OracleLane<RawSpot>,
}

// === Read Functions ===

// Raw reads expose source-native fields for external inspection; normalized reads expose the positive 1e9-scaled projection used by consumers.

/// Returns the feed identity for external composition and canonical-binding discovery.
public fun id(feed: &BlockScholesSpotFeed): ID {
    feed.id.to_inner()
}

/// Returns the immutable Block Scholes source ID for external feed inspection.
public fun bs_source_id(feed: &BlockScholesSpotFeed): u32 {
    feed.bs_source_id
}

/// Returns the write-gating storage version for external feed inspection.
public fun version(feed: &BlockScholesSpotFeed): u64 {
    feed.version
}

/// Latest raw BS spot for external inspection; aborts if none has landed.
public fun raw_spot(feed: &BlockScholesSpotFeed): OracleRead<RawSpot> {
    let read = feed.lane.latest_read();
    assert!(read.is_some(), ERawSpotNotFound);
    read.destroy_some()
}

/// Latest Propbook-normalized spot in 1e9 price scaling.
public fun normalized_spot(feed: &BlockScholesSpotFeed): Option<OracleRead<u64>> {
    let read = feed.lane.latest_read();
    if (read.is_none()) return option::none();
    normalized_spot_from_read(&read.destroy_some())
}

/// Exact raw BS spot for external timestamp inspection.
public fun raw_spot_at(feed: &BlockScholesSpotFeed, timestamp_ms: u64): OracleRead<RawSpot> {
    let read = feed.lane.read_at(timestamp_ms);
    assert!(read.is_some(), ERawSpotNotFound);
    read.destroy_some()
}

/// Exact normalized spot for external timestamp inspection, in 1e9 scaling.
public fun normalized_spot_at(
    feed: &BlockScholesSpotFeed,
    timestamp_ms: u64,
): Option<OracleRead<u64>> {
    let read = feed.lane.read_at(timestamp_ms);
    if (read.is_none()) return option::none();
    normalized_spot_from_read(&read.destroy_some())
}

/// Return the provider source ID for external raw-feed inspection.
public fun raw_bs_source_id(raw: &RawSpot): u32 {
    raw.bs_source_id
}

/// Return the source-native spot value for external raw-feed inspection.
public fun raw_spot_value(raw: &RawSpot): u64 {
    raw.spot
}

// === Write Functions ===

/// Record a verifier-produced raw spot when its source matches this feed. After
/// the version and source checks, a zero, future, duplicate, or stale source
/// timestamp is ignored without changing `latest` or emitting an event. A zero
/// spot is stored when its timestamp advances, but its normalized read is `none`.
public fun update(feed: &mut BlockScholesSpotFeed, update: SpotUpdate, clock: &Clock) {
    assert!(feed.version == constants::current_version!(), EWrongVersion);
    assert!(update.spot_source_id() == feed.bs_source_id, EWrongSource);

    let read = feed.new_read(&update, clock.timestamp_ms());
    let id = feed.id();
    feed.lane.update(read, id);
}

/// Insert a verifier-produced raw spot at its exact source timestamp without
/// changing `latest`. The first lane-valid value owns the key; zero still owns
/// the key even though its normalized read is `none`.
public fun insert_at(feed: &mut BlockScholesSpotFeed, update: SpotUpdate, clock: &Clock) {
    assert!(feed.version == constants::current_version!(), EWrongVersion);
    assert!(update.spot_source_id() == feed.bs_source_id, EWrongSource);

    let read = feed.new_read(&update, clock.timestamp_ms());
    let id = feed.id();
    feed.lane.insert_at(read, id);
}

/// Migrate this feed to the running package version. Forward-only:
/// `current_version!()` is compiled into each package version's bytecode.
public fun migrate(feed: &mut BlockScholesSpotFeed) {
    assert!(constants::current_version!() > feed.version, ENotNewerVersion);
    feed.version = constants::current_version!();
}

// === Public-Package Functions ===

/// Create and share a BS spot feed for `bs_source_id`. Package-only: `registry`
/// owns source-catalog uniqueness and calls this helper after checking duplicates.
public(package) fun create_and_share(bs_source_id: u32, ctx: &mut TxContext): ID {
    let feed = BlockScholesSpotFeed {
        id: object::new(ctx),
        bs_source_id,
        version: constants::current_version!(),
        lane: oracle_lane::new(ctx),
    };
    let id = feed.id();
    transfer::share_object(feed);
    id
}

// === Private Functions ===

fun new_read(
    feed: &BlockScholesSpotFeed,
    update: &SpotUpdate,
    update_timestamp_ms: u64,
): OracleRead<RawSpot> {
    oracle_lane::new_read(
        update.spot_published_at_ms(),
        update_timestamp_ms,
        RawSpot {
            bs_source_id: feed.bs_source_id,
            spot: update.spot(),
        },
    )
}

fun normalized_spot_from_read(read: &OracleRead<RawSpot>): Option<OracleRead<u64>> {
    let raw = read.read_value();
    if (raw.spot == 0) return option::none();
    option::some(
        oracle_lane::new_read(
            read.read_source_timestamp_ms(),
            read.read_update_timestamp_ms(),
            raw.spot,
        ),
    )
}
