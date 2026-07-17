// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

// TODO(bs-verifier): once block_scholes_oracle validates signatures, these
// updates become verified provenance. Flip the "unverified (stub-oracle)"
// wording back to "verified" at every `grep -rn 'TODO(bs-verifier)'` site.
/// Block Scholes spot oracle: one shared object per source id, storing the
/// source-native spot stream through a generic Propbook oracle lane.
///
/// `SpotUpdate` carries no provenance proof today: `block_scholes_oracle` is a
/// stub that performs no validation, so update values are forgeable until the
/// production verifier lands (see that module's warning). Predict-unaware: this
/// module stores raw source facts and leaves feed binding, freshness, and
/// pricing-safe envelopes to consumers.
module propbook::block_scholes_spot_feed;

use block_scholes_oracle::update::SpotUpdate;
use propbook::{constants, oracle_lane::{Self, OracleLane, OracleRead}};
use sui::clock::Clock;

const EWrongSource: u64 = 0;
const ERawSpotNotFound: u64 = 1;
const EWrongVersion: u64 = 2;
const ENotNewerVersion: u64 = 3;

/// Source-native Block Scholes spot fields. The generic oracle lane stores
/// Propbook's canonical millisecond timestamps around this payload.
public struct RawSpot has copy, drop, store {
    bs_source_id: u32,
    spot: u64,
}

/// One Block Scholes spot feed: version gate plus one generic oracle lane.
public struct BlockScholesSpotFeed has key {
    id: UID,
    bs_source_id: u32,
    /// Package version this feed runs at; updates require an exact match and
    /// `migrate` advances it forward-only after a package upgrade.
    version: u64,
    lane: OracleLane<RawSpot>,
}

// === Read Functions ===

// Raw reads (`raw_*`) are public provenance/observability API (devInspect and
// external composition); validated consumers use the `normalized_*` reads.

/// Return the feed object ID.
public fun id(feed: &BlockScholesSpotFeed): ID {
    feed.id.to_inner()
}

/// Return the Block Scholes source id this feed is bound to.
public fun bs_source_id(feed: &BlockScholesSpotFeed): u32 {
    feed.bs_source_id
}

/// Return the package version this feed runs at.
public fun version(feed: &BlockScholesSpotFeed): u64 {
    feed.version
}

/// Latest raw BS spot read. Aborts if no live update has landed.
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

/// Exact raw BS spot read for `timestamp_ms`.
public fun raw_spot_at(feed: &BlockScholesSpotFeed, timestamp_ms: u64): OracleRead<RawSpot> {
    let read = feed.lane.read_at(timestamp_ms);
    assert!(read.is_some(), ERawSpotNotFound);
    read.destroy_some()
}

/// Exact Propbook-normalized spot in 1e9 price scaling for `timestamp_ms`.
public fun normalized_spot_at(
    feed: &BlockScholesSpotFeed,
    timestamp_ms: u64,
): Option<OracleRead<u64>> {
    let read = feed.lane.read_at(timestamp_ms);
    if (read.is_none()) return option::none();
    normalized_spot_from_read(&read.destroy_some())
}

public fun raw_bs_source_id(raw: &RawSpot): u32 {
    raw.bs_source_id
}

public fun raw_spot_value(raw: &RawSpot): u64 {
    raw.spot
}

// === Write Functions ===

// TODO(bs-verifier): "unverified" holds only while block_scholes_oracle is a stub.
/// Ingest an unverified (stub-oracle) BS spot update into this feed's generic oracle lane.
public fun update(feed: &mut BlockScholesSpotFeed, update: SpotUpdate, clock: &Clock) {
    assert!(feed.version == constants::current_version!(), EWrongVersion);
    assert!(update.spot_source_id() == feed.bs_source_id, EWrongSource);

    let read = feed.new_read(&update, clock.timestamp_ms());
    let id = feed.id();
    feed.lane.update(read, id);
}

/// Insert an exact BS spot observation keyed by the update-derived source
/// timestamp. This does not mutate the live latest observation.
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
