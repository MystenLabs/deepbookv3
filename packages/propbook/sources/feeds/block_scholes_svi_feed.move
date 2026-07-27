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

/// SVI smile parameters; `a`, `rho`, and `m` are signed (`fixed_math::i64`).
public struct SVIParams has copy, drop, store {
    a: I64,
    b: u64,
    rho: I64,
    m: I64,
    sigma: u64,
}

/// A normalized SVI observation with separate parameter-age, publication, and
/// on-chain landing timestamps.
public struct SVIRead has copy, drop {
    /// Source timestamp of the first accepted envelope carrying this exact
    /// normalized parameter tuple.
    params_timestamp_ms: u64,
    /// Source timestamp of the latest accepted provider envelope.
    source_timestamp_ms: u64,
    /// Sui clock time when that latest envelope landed on chain.
    update_timestamp_ms: u64,
    svi: SVIParams,
}

/// Source-native Block Scholes SVI fields. `params_timestamp_ms` remains fixed
/// across exact normalized tuple retransmissions while the lane envelope advances.
public struct RawSVI has copy, drop, store {
    bs_source_id: u32,
    expiry_ms: u64,
    params_timestamp_ms: u64,
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

/// Latest Propbook-normalized SVI params and their three timestamp semantics for
/// `expiry_ms`.
public fun normalized_svi(feed: &BlockScholesSVIFeed, expiry_ms: u64): Option<SVIRead> {
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

/// Exact normalized SVI parameters anchored to their exact source timestamp.
public fun normalized_svi_at(
    feed: &BlockScholesSVIFeed,
    expiry_ms: u64,
    timestamp_ms: u64,
): Option<SVIRead> {
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

/// Return when the currently stored normalized parameter tuple first appeared.
public fun raw_params_timestamp_ms(raw: &RawSVI): u64 {
    raw.params_timestamp_ms
}

/// Return the source-native SVI parameters for external raw-feed inspection.
public fun raw_svi_params(raw: &RawSVI): SVIParams {
    raw.svi
}

/// Return when this exact normalized tuple first appeared.
public fun params_timestamp_ms(read: &SVIRead): u64 {
    read.params_timestamp_ms
}

/// Return the latest accepted provider-envelope timestamp.
public fun source_timestamp_ms(read: &SVIRead): u64 {
    read.source_timestamp_ms
}

/// Return when the latest accepted envelope landed on chain.
public fun update_timestamp_ms(read: &SVIRead): u64 {
    read.update_timestamp_ms
}

/// Return the normalized parameters carried by this read.
public fun svi_params(read: &SVIRead): SVIParams {
    read.svi
}

public fun a(params: &SVIParams): I64 {
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
            params_timestamp_ms: update.svi_published_at_ms(),
            svi: SVIParams {
                a: i64::from_parts(update.svi_a_magnitude(), update.svi_a_is_negative()),
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
        let lane = feed.expiries.borrow_mut(expiry_ms);
        let read = preserve_params_timestamp_for_unchanged_tuple(lane, read);
        lane.update(read, propbook_oracle_id);
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

fun preserve_params_timestamp_for_unchanged_tuple(
    lane: &OracleLane<RawSVI>,
    read: OracleRead<RawSVI>,
): OracleRead<RawSVI> {
    let latest = lane.latest_read();
    if (latest.is_none()) return read;

    let latest_raw = latest.destroy_some().read_value();
    let raw = read.read_value();
    if (raw.svi != latest_raw.svi) return read;

    oracle_lane::new_read(
        read.read_source_timestamp_ms(),
        read.read_update_timestamp_ms(),
        RawSVI {
            bs_source_id: raw.bs_source_id,
            expiry_ms: raw.expiry_ms,
            params_timestamp_ms: latest_raw.params_timestamp_ms,
            svi: raw.svi,
        },
    )
}

fun normalized_svi_from_read(read: &OracleRead<RawSVI>): SVIRead {
    let raw = read.read_value();
    SVIRead {
        params_timestamp_ms: raw.params_timestamp_ms,
        source_timestamp_ms: read.read_source_timestamp_ms(),
        update_timestamp_ms: read.read_update_timestamp_ms(),
        svi: raw.svi,
    }
}
