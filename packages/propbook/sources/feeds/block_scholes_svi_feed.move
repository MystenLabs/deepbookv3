// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Stores Block Scholes SVI surface streams for one source, partitioned by expiry into independent Propbook oracle lanes.
/// Writes require the verifier-produced `SVIUpdate` type and must match the feed's immutable source ID.
/// Propbook preserves the signed surface parameters but does not impose consumer-specific pricing or no-arbitrage policy.
module propbook::block_scholes_svi_feed;

use block_scholes_oracle::update::SVIUpdate;
use fixed_math::i64::{Self, I64};
use propbook::{constants, oracle_lane::{Self, OracleLane, OracleRead}};
use sui::{clock::Clock, table::{Self, Table}};

const EWrongSource: u64 = 0;
const ERawSVINotFound: u64 = 1;
const EWrongVersion: u64 = 2;
const ENotNewerVersion: u64 = 3;

/// SVI smile parameters at 1e9 scale; `rho` and `m` are signed.
public struct SVIParams has copy, drop, store {
    a: u64,
    b: u64,
    rho: I64,
    m: I64,
    sigma: u64,
}

/// Source-native Block Scholes SVI fields; the lane supplies publication and recording timestamps.
public struct RawSVI has copy, drop, store {
    bs_source_id: u32,
    expiry_ms: u64,
    svi: SVIParams,
}

/// A versioned Block Scholes SVI feed with one lane per expiry.
public struct BlockScholesSVIFeed has key {
    id: UID,
    bs_source_id: u32,
    /// Package version this feed runs at; updates require an exact match and
    /// `migrate` advances it forward-only after a package upgrade.
    version: u64,
    expiries: Table<u64, OracleLane<RawSVI>>,
}

// === Read Functions ===

// Raw reads expose source-native fields for external inspection; normalized reads expose the signed parameter representation used by consumers.

/// Returns the feed identity for external composition and canonical-binding discovery.
public fun id(feed: &BlockScholesSVIFeed): ID {
    feed.id.to_inner()
}

/// Returns the immutable Block Scholes source ID for external feed inspection.
public fun bs_source_id(feed: &BlockScholesSVIFeed): u32 {
    feed.bs_source_id
}

/// Returns the write-gating storage version for external feed inspection.
public fun version(feed: &BlockScholesSVIFeed): u64 {
    feed.version
}

/// Latest raw SVI parameters for external inspection; aborts if none has landed.
public fun raw_svi(feed: &BlockScholesSVIFeed, expiry_ms: u64): OracleRead<RawSVI> {
    assert!(feed.expiries.contains(expiry_ms), ERawSVINotFound);
    let read = feed.expiries.borrow(expiry_ms).latest_read();
    assert!(read.is_some(), ERawSVINotFound);
    read.destroy_some()
}

/// Latest Propbook-normalized SVI params for `expiry_ms`.
public fun normalized_svi(
    feed: &BlockScholesSVIFeed,
    expiry_ms: u64,
): Option<OracleRead<SVIParams>> {
    if (!feed.expiries.contains(expiry_ms)) return option::none();
    let read = feed.expiries.borrow(expiry_ms).latest_read();
    if (read.is_none()) return option::none();
    option::some(normalized_svi_from_read(&read.destroy_some()))
}

/// Exact source-native SVI read for external Move, PTB, and devInspect consumers.
public fun raw_svi_at(
    feed: &BlockScholesSVIFeed,
    expiry_ms: u64,
    timestamp_ms: u64,
): OracleRead<RawSVI> {
    assert!(feed.expiries.contains(expiry_ms), ERawSVINotFound);
    let read = feed.expiries.borrow(expiry_ms).read_at(timestamp_ms);
    assert!(read.is_some(), ERawSVINotFound);
    read.destroy_some()
}

/// Exact normalized SVI parameters for external timestamp inspection.
public fun normalized_svi_at(
    feed: &BlockScholesSVIFeed,
    expiry_ms: u64,
    timestamp_ms: u64,
): Option<OracleRead<SVIParams>> {
    if (!feed.expiries.contains(expiry_ms)) return option::none();
    let read = feed.expiries.borrow(expiry_ms).read_at(timestamp_ms);
    if (read.is_none()) return option::none();
    option::some(normalized_svi_from_read(&read.destroy_some()))
}

/// Return the provider source ID for external raw-feed inspection.
public fun raw_bs_source_id(raw: &RawSVI): u32 {
    raw.bs_source_id
}

/// Return the quoted expiry timestamp for external raw-feed inspection.
public fun raw_expiry_ms(raw: &RawSVI): u64 {
    raw.expiry_ms
}

/// Return the source-native SVI parameters for external raw-feed inspection.
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

/// Record a verifier-produced SVI update in the lane selected by its expiry.
/// After the version and source checks, a zero, future, duplicate, or stale source
/// timestamp is ignored without changing `latest` or emitting an event.
public fun update(
    feed: &mut BlockScholesSVIFeed,
    update: SVIUpdate,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(feed.version == constants::current_version!(), EWrongVersion);
    assert!(update.svi_source_id() == feed.bs_source_id, EWrongSource);

    let read = feed.new_read(&update, clock.timestamp_ms());
    let expiry = read.read_value().expiry_ms;
    let id = feed.id();
    feed.update_expiry(expiry, id, read, ctx);
}

/// Inserts a verifier-produced SVI observation at its exact source timestamp without changing `latest`.
/// The first valid observation accepted for an expiry and timestamp owns that key; later inserts are ignored.
public fun insert_at(
    feed: &mut BlockScholesSVIFeed,
    update: SVIUpdate,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(feed.version == constants::current_version!(), EWrongVersion);
    assert!(update.svi_source_id() == feed.bs_source_id, EWrongSource);

    let read = feed.new_read(&update, clock.timestamp_ms());
    let expiry = read.read_value().expiry_ms;
    let id = feed.id();
    feed.insert_expiry_at(expiry, id, read, ctx);
}

/// Migrate this feed to the running package version. Forward-only:
/// `current_version!()` is compiled into each package version's bytecode.
public fun migrate(feed: &mut BlockScholesSVIFeed) {
    assert!(constants::current_version!() > feed.version, ENotNewerVersion);
    feed.version = constants::current_version!();
}

// === Public-Package Functions ===

/// Create and share a BS SVI feed for `bs_source_id`.
/// Package-only: `registry` owns source-catalog uniqueness.
public(package) fun create_and_share(bs_source_id: u32, ctx: &mut TxContext): ID {
    let feed = BlockScholesSVIFeed {
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
    feed: &BlockScholesSVIFeed,
    update: &SVIUpdate,
    update_timestamp_ms: u64,
): OracleRead<RawSVI> {
    oracle_lane::new_read(
        update.svi_published_at_ms(),
        update_timestamp_ms,
        RawSVI {
            bs_source_id: feed.bs_source_id,
            expiry_ms: update.svi_expiry_ms(),
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

fun update_expiry(
    feed: &mut BlockScholesSVIFeed,
    expiry_ms: u64,
    propbook_oracle_id: ID,
    read: OracleRead<RawSVI>,
    ctx: &mut TxContext,
) {
    if (feed.expiries.contains(expiry_ms)) {
        feed.expiries.borrow_mut(expiry_ms).update(read, propbook_oracle_id);
    } else {
        if (!read.read_has_valid_timestamp()) return;
        let mut lane = oracle_lane::new(ctx);
        lane.update(read, propbook_oracle_id);
        feed.expiries.add(expiry_ms, lane);
    };
}

fun insert_expiry_at(
    feed: &mut BlockScholesSVIFeed,
    expiry_ms: u64,
    propbook_oracle_id: ID,
    read: OracleRead<RawSVI>,
    ctx: &mut TxContext,
) {
    if (feed.expiries.contains(expiry_ms)) {
        feed.expiries.borrow_mut(expiry_ms).insert_at(read, propbook_oracle_id);
    } else {
        if (!read.read_has_valid_timestamp()) return;
        let mut lane = oracle_lane::new(ctx);
        lane.insert_at(read, propbook_oracle_id);
        feed.expiries.add(expiry_ms, lane);
    };
}

fun normalized_svi_from_read(read: &OracleRead<RawSVI>): OracleRead<SVIParams> {
    let raw = read.read_value();
    oracle_lane::new_read(
        read.read_source_timestamp_ms(),
        read.read_update_timestamp_ms(),
        raw.svi,
    )
}
