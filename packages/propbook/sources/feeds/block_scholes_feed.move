// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Block Scholes volatility-surface oracle: a per-source-id shared object holding
/// a package-version gate and a table of per-expiry Propbook oracle lanes. Each
/// expiry lane behaves the same way as a Pyth feed lane; the BS feed only routes
/// source-native BS payloads to the lane keyed by `expiry_ms`.
///
/// The verified `Update` is its own provenance proof (today via the
/// `block_scholes_oracle` stub verifier). Predict-unaware: it owns no
/// market-settlement valuation, valuation lock, expiry-validity policy, or
/// consumer-specific pricing envelope; callers own which expiries are real markets
/// and whether a stored surface is safe for their math.
module propbook::block_scholes_feed;

use block_scholes_oracle::update::Update;
use fixed_math::i64::{Self, I64};
use propbook::{constants, oracle_lane::{Self, OracleLane, OracleRead}};
use std::option::{Self, Option};
use sui::{clock::Clock, table::{Self, Table}};

const EWrongSource: u64 = 0;
const ERawSurfaceNotFound: u64 = 1;
const EWrongVersion: u64 = 2;
const ENotNewerVersion: u64 = 3;

/// SVI smile parameters; `rho` and `m` are signed (`fixed_math::i64`).
public struct SVIParams has copy, drop, store {
    a: u64,
    b: u64,
    rho: I64,
    m: I64,
    sigma: u64,
}

/// Source-native Block Scholes surface fields for an expiry. The generic oracle
/// lane stores Propbook's canonical millisecond timestamps around this payload.
public struct RawSurface has copy, drop, store {
    bs_source_id: u32,
    expiry_ms: u64,
    /// Underlying spot for this expiry's snapshot, in 1e9 price scaling.
    spot: u64,
    forward: u64,
    svi: SVIParams,
}

/// Propbook-normalized Block Scholes surface for an expiry.
public struct Surface has copy, drop, store {
    spot: u64,
    forward: u64,
    svi: SVIParams,
}

/// One Block Scholes feed: version gate plus one generic oracle lane per expiry.
public struct BlockScholesFeed has key {
    id: UID,
    bs_source_id: u32,
    /// Package version this feed runs at; updates require an exact match and
    /// `migrate` advances it forward-only after a package upgrade.
    version: u64,
    expiries: Table<u64, OracleLane<RawSurface>>,
}

// === Read Functions ===

/// Return the feed object ID.
public fun id(feed: &BlockScholesFeed): ID {
    feed.id.to_inner()
}

/// Return the Block Scholes source id this feed is bound to.
public fun bs_source_id(feed: &BlockScholesFeed): u32 {
    feed.bs_source_id
}

/// Return the package version this feed runs at.
public fun version(feed: &BlockScholesFeed): u64 {
    feed.version
}

/// Exact raw surface recorded for `timestamp_ms` for `expiry`.
/// Aborts if the expiry or timestamp was never recorded.
public fun raw_surface_at(
    feed: &BlockScholesFeed,
    expiry: u64,
    timestamp_ms: u64,
): OracleRead<RawSurface> {
    assert!(feed.expiries.contains(expiry), ERawSurfaceNotFound);
    let read = feed.expiries.borrow(expiry).read_at(timestamp_ms);
    assert!(read.is_some(), ERawSurfaceNotFound);
    read.destroy_some()
}

public fun normalized_surface_at(
    feed: &BlockScholesFeed,
    expiry: u64,
    timestamp_ms: u64,
): Option<OracleRead<Surface>> {
    if (!feed.expiries.contains(expiry)) return option::none();
    let read = feed.expiries.borrow(expiry).read_at(timestamp_ms);
    if (read.is_none()) return option::none();
    normalized_surface_from_read(&read.destroy_some())
}

/// Latest raw surface for `expiry`.
public fun raw_surface(feed: &BlockScholesFeed, expiry: u64): OracleRead<RawSurface> {
    assert!(feed.expiries.contains(expiry), ERawSurfaceNotFound);
    let read = feed.expiries.borrow(expiry).latest_read();
    assert!(read.is_some(), ERawSurfaceNotFound);
    read.destroy_some()
}

/// Latest Propbook-normalized surface for `expiry`.
public fun normalized_surface(feed: &BlockScholesFeed, expiry: u64): Option<OracleRead<Surface>> {
    if (!feed.expiries.contains(expiry)) return option::none();
    let read = feed.expiries.borrow(expiry).latest_read();
    if (read.is_none()) return option::none();
    normalized_surface_from_read(&read.destroy_some())
}

public fun raw_bs_source_id(raw: &RawSurface): u32 {
    raw.bs_source_id
}

public fun raw_expiry_ms(raw: &RawSurface): u64 {
    raw.expiry_ms
}

public fun raw_spot(raw: &RawSurface): u64 {
    raw.spot
}

public fun raw_forward(raw: &RawSurface): u64 {
    raw.forward
}

public fun raw_svi(raw: &RawSurface): SVIParams {
    raw.svi
}

public fun surface_spot(surface: &Surface): u64 {
    surface.spot
}

public fun surface_forward(surface: &Surface): u64 {
    surface.forward
}

public fun surface_svi(surface: &Surface): SVIParams {
    surface.svi
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

/// Ingest a verified BS snapshot for one expiry. The feed validates only source
/// binding and routes the source-native payload to that expiry's generic oracle
/// lane; the lane owns freshness, history, and event emission.
public fun update(feed: &mut BlockScholesFeed, update: Update, clock: &Clock, ctx: &mut TxContext) {
    assert!(feed.version == constants::current_version!(), EWrongVersion);
    assert!(update.source_id() == feed.bs_source_id, EWrongSource);

    let read = feed.new_read(&update, clock.timestamp_ms());
    let expiry = read.read_value().expiry_ms;
    let id = feed.id();
    feed.update_expiry(expiry, id, read, ctx);
}

/// Insert an exact BS surface observation keyed by the update-derived source
/// timestamp. This does not mutate the live per-expiry latest observation.
///
/// Permissionless by interface: the Update is supposed to be its own provenance
/// proof. CURRENT STUB WARNING: `block_scholes_oracle::update` does not verify
/// signatures yet, so permissionless exact BS insert writes are not
/// production-safe until the real verifier replaces the stub.
public fun insert_at(
    feed: &mut BlockScholesFeed,
    update: Update,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(feed.version == constants::current_version!(), EWrongVersion);
    assert!(update.source_id() == feed.bs_source_id, EWrongSource);

    let read = feed.new_read(&update, clock.timestamp_ms());
    let expiry = read.read_value().expiry_ms;
    let id = feed.id();
    feed.insert_expiry_at(expiry, id, read, ctx);
}

/// Migrate this feed to the running package version. Forward-only:
/// `current_version!()` is compiled into each package version's bytecode (callers
/// cannot inject an arbitrary version), and the strictly-greater check blocks
/// downgrade griefing. Every package upgrade MUST bump `current_version!()`.
public fun migrate(feed: &mut BlockScholesFeed) {
    assert!(constants::current_version!() > feed.version, ENotNewerVersion);
    feed.version = constants::current_version!();
}

// === Public-Package Functions ===

/// Create and share a BS feed for `bs_source_id`. Package-only: `registry` owns
/// source-catalog uniqueness and calls this helper after checking duplicates.
public(package) fun create_and_share(bs_source_id: u32, ctx: &mut TxContext): ID {
    let feed = BlockScholesFeed {
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
    feed: &BlockScholesFeed,
    update: &Update,
    update_timestamp_ms: u64,
): OracleRead<RawSurface> {
    oracle_lane::new_read(
        update.published_at_ms(),
        update_timestamp_ms,
        RawSurface {
            bs_source_id: feed.bs_source_id,
            expiry_ms: update.expiry_ms(),
            spot: update.spot(),
            forward: update.forward(),
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
    feed: &mut BlockScholesFeed,
    expiry_ms: u64,
    propbook_oracle_id: ID,
    read: OracleRead<RawSurface>,
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
    feed: &mut BlockScholesFeed,
    expiry_ms: u64,
    propbook_oracle_id: ID,
    read: OracleRead<RawSurface>,
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

fun normalized_surface_from_read(read: &OracleRead<RawSurface>): Option<OracleRead<Surface>> {
    let raw = read.read_value();
    if (raw.spot == 0 || raw.forward == 0) return option::none();
    option::some(
        oracle_lane::new_read(
            read.read_source_timestamp_ms(),
            read.read_update_timestamp_ms(),
            Surface {
                spot: raw.spot,
                forward: raw.forward,
                svi: raw.svi,
            },
        ),
    )
}

// === Test-Only Functions ===

#[test_only]
public fun set_version_for_testing(feed: &mut BlockScholesFeed, version: u64) {
    feed.version = version;
}
