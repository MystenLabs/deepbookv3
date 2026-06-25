// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Block Scholes forward oracle: one shared object per source id, storing
/// per-expiry forward streams keyed by expiry timestamp.
///
/// Predict-unaware: this module stores raw source facts and leaves feed binding,
/// freshness, and pricing-safe envelopes to consumers.
module propbook::block_scholes_forward_feed;

use block_scholes_oracle::update::ForwardUpdate;
use propbook::{constants, oracle_lane::{Self, OracleLane, OracleRead}};
use std::option::{Self, Option};
use sui::{clock::Clock, table::{Self, Table}};

const EWrongSource: u64 = 0;
const ERawForwardNotFound: u64 = 2;
const EWrongVersion: u64 = 3;
const ENotNewerVersion: u64 = 4;

/// Source-native Block Scholes forward fields. The generic oracle lane stores
/// Propbook's canonical millisecond timestamps around this payload.
public struct RawForward has copy, drop, store {
    bs_source_id: u32,
    expiry_ms: u64,
    forward: u64,
}

/// One Block Scholes forward feed: version gate plus one generic oracle lane per expiry.
public struct BlockScholesForwardFeed has key {
    id: UID,
    bs_source_id: u32,
    /// Package version this feed runs at; updates require an exact match and
    /// `migrate` advances it forward-only after a package upgrade.
    version: u64,
    expiries: Table<u64, OracleLane<RawForward>>,
}

// === Read Functions ===

/// Return the feed object ID.
public fun id(feed: &BlockScholesForwardFeed): ID {
    feed.id.to_inner()
}

/// Return the Block Scholes source id this feed is bound to.
public fun bs_source_id(feed: &BlockScholesForwardFeed): u32 {
    feed.bs_source_id
}

/// Return the package version this feed runs at.
public fun version(feed: &BlockScholesForwardFeed): u64 {
    feed.version
}

/// Latest raw BS forward read for `expiry_ms`. Aborts if no live update has landed.
public fun raw_forward(feed: &BlockScholesForwardFeed, expiry_ms: u64): OracleRead<RawForward> {
    assert!(feed.expiries.contains(expiry_ms), ERawForwardNotFound);
    let read = feed.expiries.borrow(expiry_ms).latest_read();
    assert!(read.is_some(), ERawForwardNotFound);
    read.destroy_some()
}

/// Latest Propbook-normalized forward in 1e9 price scaling for `expiry_ms`.
public fun normalized_forward(
    feed: &BlockScholesForwardFeed,
    expiry_ms: u64,
): Option<OracleRead<u64>> {
    if (!feed.expiries.contains(expiry_ms)) return option::none();
    let read = feed.expiries.borrow(expiry_ms).latest_read();
    if (read.is_none()) return option::none();
    normalized_forward_from_read(&read.destroy_some())
}

/// Exact raw BS forward read for `(expiry_ms, timestamp_ms)`.
public fun raw_forward_at(
    feed: &BlockScholesForwardFeed,
    expiry_ms: u64,
    timestamp_ms: u64,
): OracleRead<RawForward> {
    assert!(feed.expiries.contains(expiry_ms), ERawForwardNotFound);
    let read = feed.expiries.borrow(expiry_ms).read_at(timestamp_ms);
    assert!(read.is_some(), ERawForwardNotFound);
    read.destroy_some()
}

/// Exact Propbook-normalized forward in 1e9 price scaling for `(expiry_ms, timestamp_ms)`.
public fun normalized_forward_at(
    feed: &BlockScholesForwardFeed,
    expiry_ms: u64,
    timestamp_ms: u64,
): Option<OracleRead<u64>> {
    if (!feed.expiries.contains(expiry_ms)) return option::none();
    let read = feed.expiries.borrow(expiry_ms).read_at(timestamp_ms);
    if (read.is_none()) return option::none();
    normalized_forward_from_read(&read.destroy_some())
}

public fun raw_bs_source_id(raw: &RawForward): u32 {
    raw.bs_source_id
}

public fun raw_expiry_ms(raw: &RawForward): u64 {
    raw.expiry_ms
}

public fun raw_forward_value(raw: &RawForward): u64 {
    raw.forward
}

// === Write Functions ===

/// Ingest a verified BS forward update into this feed's generic oracle lane.
public fun update(
    feed: &mut BlockScholesForwardFeed,
    update: ForwardUpdate,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(feed.version == constants::current_version!(), EWrongVersion);
    assert!(update.forward_source_id() == feed.bs_source_id, EWrongSource);

    let read = feed.new_read(&update, clock.timestamp_ms());
    let expiry = read.read_value().expiry_ms;
    let id = feed.id();
    feed.update_expiry(expiry, id, read, ctx);
}

/// Insert an exact BS forward observation keyed by the update-derived source
/// timestamp. This does not mutate the live latest observation.
public fun insert_at(
    feed: &mut BlockScholesForwardFeed,
    update: ForwardUpdate,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(feed.version == constants::current_version!(), EWrongVersion);
    assert!(update.forward_source_id() == feed.bs_source_id, EWrongSource);

    let read = feed.new_read(&update, clock.timestamp_ms());
    let expiry = read.read_value().expiry_ms;
    let id = feed.id();
    feed.insert_expiry_at(expiry, id, read, ctx);
}

/// Migrate this feed to the running package version. Forward-only:
/// `current_version!()` is compiled into each package version's bytecode.
public fun migrate(feed: &mut BlockScholesForwardFeed) {
    assert!(constants::current_version!() > feed.version, ENotNewerVersion);
    feed.version = constants::current_version!();
}

// === Public-Package Functions ===

/// Create and share a BS forward feed for `bs_source_id`.
/// Package-only: `registry` owns source-catalog uniqueness.
public(package) fun create_and_share(
    bs_source_id: u32,
    ctx: &mut TxContext,
): ID {
    let feed = BlockScholesForwardFeed {
        id: object::new(ctx),
        bs_source_id,
        version: constants::current_version!(),
        expiries: table::new(ctx),
    };
    let id = feed.id();
    transfer::share_object(feed);
    id
}

// === Private Functions ===

fun new_read(
    feed: &BlockScholesForwardFeed,
    update: &ForwardUpdate,
    update_timestamp_ms: u64,
): OracleRead<RawForward> {
    oracle_lane::new_read(
        update.forward_published_at_ms(),
        update_timestamp_ms,
        RawForward {
            bs_source_id: feed.bs_source_id,
            expiry_ms: update.forward_expiry_ms(),
            forward: update.forward(),
        },
    )
}

fun update_expiry(
    feed: &mut BlockScholesForwardFeed,
    expiry_ms: u64,
    propbook_oracle_id: ID,
    read: OracleRead<RawForward>,
    ctx: &mut TxContext,
) {
    if (feed.expiries.contains(expiry_ms)) {
        feed.expiries.borrow_mut(expiry_ms).update(propbook_oracle_id, read);
    } else {
        if (!oracle_lane::read_has_valid_timestamp(&read)) return;
        let mut lane = oracle_lane::new(ctx);
        lane.update(propbook_oracle_id, read);
        feed.expiries.add(expiry_ms, lane);
    };
}

fun insert_expiry_at(
    feed: &mut BlockScholesForwardFeed,
    expiry_ms: u64,
    propbook_oracle_id: ID,
    read: OracleRead<RawForward>,
    ctx: &mut TxContext,
) {
    if (feed.expiries.contains(expiry_ms)) {
        feed.expiries.borrow_mut(expiry_ms).insert_at(propbook_oracle_id, read);
    } else {
        if (!oracle_lane::read_has_valid_timestamp(&read)) return;
        let mut lane = oracle_lane::new(ctx);
        lane.insert_at(propbook_oracle_id, read);
        feed.expiries.add(expiry_ms, lane);
    };
}

fun normalized_forward_from_read(read: &OracleRead<RawForward>): Option<OracleRead<u64>> {
    let raw = read.read_value();
    if (raw.forward == 0) return option::none();
    option::some(
        oracle_lane::new_read(
            read.read_source_timestamp_ms(),
            read.read_update_timestamp_ms(),
            raw.forward,
        ),
    )
}

// === Test-Only Functions ===

#[test_only]
public fun set_version_for_testing(feed: &mut BlockScholesForwardFeed, version: u64) {
    feed.version = version;
}
