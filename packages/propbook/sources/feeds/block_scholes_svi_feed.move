// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Block Scholes SVI oracle: one shared object per `(source id, expiry)`,
/// storing an independent expiry volatility-surface stream through a generic
/// Propbook oracle lane.
///
/// Propbook does not validate Predict's pricing-safe SVI envelope; consumers
/// own any bounds or no-arbitrage policy needed by their pricing math.
module propbook::block_scholes_svi_feed;

use block_scholes_oracle::update::SVIUpdate;
use fixed_math::i64::{Self, I64};
use propbook::{constants, oracle_lane::{Self, OracleLane, OracleRead}};
use std::option::{Self, Option};
use sui::clock::Clock;

const EWrongSource: u64 = 0;
const EWrongExpiry: u64 = 1;
const ERawSVINotFound: u64 = 2;
const EWrongVersion: u64 = 3;
const ENotNewerVersion: u64 = 4;

/// SVI smile parameters; `rho` and `m` are signed (`fixed_math::i64`).
public struct SVIParams has copy, drop, store {
    a: u64,
    b: u64,
    rho: I64,
    m: I64,
    sigma: u64,
}

/// Source-native Block Scholes SVI fields. The generic oracle lane stores
/// Propbook's canonical millisecond timestamps around this payload.
public struct RawSVI has copy, drop, store {
    bs_source_id: u32,
    expiry_ms: u64,
    svi: SVIParams,
}

/// One Block Scholes SVI feed: version gate plus one generic oracle lane.
public struct BlockScholesSVIFeed has key {
    id: UID,
    bs_source_id: u32,
    expiry_ms: u64,
    /// Package version this feed runs at; updates require an exact match and
    /// `migrate` advances it forward-only after a package upgrade.
    version: u64,
    lane: OracleLane<RawSVI>,
}

// === Read Functions ===

/// Return the feed object ID.
public fun id(feed: &BlockScholesSVIFeed): ID {
    feed.id.to_inner()
}

/// Return the Block Scholes source id this feed is bound to.
public fun bs_source_id(feed: &BlockScholesSVIFeed): u32 {
    feed.bs_source_id
}

/// Return the expiry this feed is bound to.
public fun expiry_ms(feed: &BlockScholesSVIFeed): u64 {
    feed.expiry_ms
}

/// Return the package version this feed runs at.
public fun version(feed: &BlockScholesSVIFeed): u64 {
    feed.version
}

/// Latest raw BS SVI read. Aborts if no live update has landed.
public fun raw_svi(feed: &BlockScholesSVIFeed): OracleRead<RawSVI> {
    let read = feed.lane.latest_read();
    assert!(read.is_some(), ERawSVINotFound);
    read.destroy_some()
}

/// Latest Propbook-normalized SVI params.
public fun normalized_svi(feed: &BlockScholesSVIFeed): Option<OracleRead<SVIParams>> {
    let read = feed.lane.latest_read();
    if (read.is_none()) return option::none();
    option::some(normalized_svi_from_read(&read.destroy_some()))
}

/// Exact raw BS SVI read for `timestamp_ms`.
public fun raw_svi_at(feed: &BlockScholesSVIFeed, timestamp_ms: u64): OracleRead<RawSVI> {
    let read = feed.lane.read_at(timestamp_ms);
    assert!(read.is_some(), ERawSVINotFound);
    read.destroy_some()
}

/// Exact Propbook-normalized SVI params for `timestamp_ms`.
public fun normalized_svi_at(
    feed: &BlockScholesSVIFeed,
    timestamp_ms: u64,
): Option<OracleRead<SVIParams>> {
    let read = feed.lane.read_at(timestamp_ms);
    if (read.is_none()) return option::none();
    option::some(normalized_svi_from_read(&read.destroy_some()))
}

public fun raw_bs_source_id(raw: &RawSVI): u32 {
    raw.bs_source_id
}

public fun raw_expiry_ms(raw: &RawSVI): u64 {
    raw.expiry_ms
}

public fun raw_svi_params(raw: &RawSVI): SVIParams {
    raw.svi
}

public fun a(params: &SVIParams): u64 {
    params.a
}

public fun b(params: &SVIParams): u64 {
    params.b
}

public fun rho(params: &SVIParams): I64 {
    params.rho
}

public fun m(params: &SVIParams): I64 {
    params.m
}

public fun sigma(params: &SVIParams): u64 {
    params.sigma
}

// === Write Functions ===

/// Ingest a verified BS SVI update into this feed's generic oracle lane.
public fun update(feed: &mut BlockScholesSVIFeed, update: SVIUpdate, clock: &Clock) {
    assert!(feed.version == constants::current_version!(), EWrongVersion);
    assert!(update.svi_source_id() == feed.bs_source_id, EWrongSource);
    assert!(update.svi_expiry_ms() == feed.expiry_ms, EWrongExpiry);

    let read = feed.new_read(&update, clock.timestamp_ms());
    let id = feed.id();
    feed.lane.update(id, read);
}

/// Insert an exact BS SVI observation keyed by the update-derived source
/// timestamp. This does not mutate the live latest observation.
public fun insert_at(feed: &mut BlockScholesSVIFeed, update: SVIUpdate, clock: &Clock) {
    assert!(feed.version == constants::current_version!(), EWrongVersion);
    assert!(update.svi_source_id() == feed.bs_source_id, EWrongSource);
    assert!(update.svi_expiry_ms() == feed.expiry_ms, EWrongExpiry);

    let read = feed.new_read(&update, clock.timestamp_ms());
    let id = feed.id();
    feed.lane.insert_at(id, read);
}

/// Migrate this feed to the running package version. Forward-only:
/// `current_version!()` is compiled into each package version's bytecode.
public fun migrate(feed: &mut BlockScholesSVIFeed) {
    assert!(constants::current_version!() > feed.version, ENotNewerVersion);
    feed.version = constants::current_version!();
}

// === Public-Package Functions ===

/// Create and share a BS SVI feed for `(bs_source_id, expiry_ms)`.
/// Package-only: `registry` owns source-catalog uniqueness.
public(package) fun create_and_share(
    bs_source_id: u32,
    expiry_ms: u64,
    ctx: &mut TxContext,
): ID {
    let feed = BlockScholesSVIFeed {
        id: object::new(ctx),
        bs_source_id,
        expiry_ms,
        version: constants::current_version!(),
        lane: oracle_lane::new(ctx),
    };
    let id = feed.id();
    transfer::share_object(feed);
    id
}

// === Private Functions ===

fun new_read(
    feed: &BlockScholesSVIFeed,
    update: &SVIUpdate,
    update_timestamp_ms: u64,
): OracleRead<RawSVI> {
    oracle_lane::new_read(
        update.svi_published_at_ms(),
        update_timestamp_ms,
        RawSVI {
            bs_source_id: feed.bs_source_id,
            expiry_ms: feed.expiry_ms,
            svi: SVIParams {
                a: update.svi_a(),
                b: update.svi_b(),
                rho: i64::from_parts(update.svi_rho_magnitude(), update.svi_rho_is_negative()),
                m: i64::from_parts(update.svi_m_magnitude(), update.svi_m_is_negative()),
                sigma: update.svi_sigma(),
            },
        },
    )
}

fun normalized_svi_from_read(read: &OracleRead<RawSVI>): OracleRead<SVIParams> {
    let raw = read.read_value();
    oracle_lane::new_read(
        read.read_source_timestamp_ms(),
        read.read_update_timestamp_ms(),
        raw.svi,
    )
}

// === Test-Only Functions ===

#[test_only]
public fun set_version_for_testing(feed: &mut BlockScholesSVIFeed, version: u64) {
    feed.version = version;
}
