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
use propbook::{constants, oracle_lane::{Self, OracleLane, OracleObservation}};
use sui::{clock::Clock, table::{Self, Table}};

const EWrongSource: u64 = 0;
const EExpiryNotFound: u64 = 1;
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

/// One source-native Block Scholes payload for an expiry. The generic oracle
/// lane stores Propbook's canonical millisecond timestamps around this payload.
public struct BlockScholesSourcePayload has copy, drop, store {
    bs_source_id: u32,
    expiry_ms: u64,
    /// Underlying spot for this expiry's snapshot, in 1e9 price scaling.
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
    expiries: Table<u64, OracleLane<BlockScholesSourcePayload>>,
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

/// First-observed update recorded for `minute_ms`'s spot bucket for `expiry`.
/// Aborts if the expiry or minute was never recorded; use `has_observation` to
/// check first.
public fun observation_at_minute(
    feed: &BlockScholesFeed,
    expiry: u64,
    minute_ms: u64,
): OracleObservation<BlockScholesSourcePayload> {
    assert!(feed.expiries.contains(expiry), EExpiryNotFound);
    feed.expiries.borrow(expiry).observation_at_minute(minute_ms)
}

/// Whether this feed has a first-observed update for `minute_ms`'s bucket for
/// `expiry`.
public fun has_observation(feed: &BlockScholesFeed, expiry: u64, minute_ms: u64): bool {
    feed.expiries.contains(expiry)
        && feed.expiries.borrow(expiry).has_observation(minute_ms)
}

/// Official settlement observation recorded for exact `resolution_timestamp_ms`
/// for `expiry`. Aborts if the expiry or official settlement timestamp was never
/// recorded.
public fun official_observation_at_resolution(
    feed: &BlockScholesFeed,
    expiry: u64,
    resolution_timestamp_ms: u64,
): OracleObservation<BlockScholesSourcePayload> {
    assert!(feed.expiries.contains(expiry), EExpiryNotFound);
    feed.expiries.borrow(expiry).official_observation_at_resolution(resolution_timestamp_ms)
}

/// Whether this feed has official settlement data for exact
/// `resolution_timestamp_ms` for `expiry`.
public fun has_official_settlement(
    feed: &BlockScholesFeed,
    expiry: u64,
    resolution_timestamp_ms: u64,
): bool {
    feed.expiries.contains(expiry)
        && feed.expiries.borrow(expiry).has_official_settlement(resolution_timestamp_ms)
}

/// Whether a live observation exists for `expiry`.
public fun has_expiry(feed: &BlockScholesFeed, expiry: u64): bool {
    feed.expiries.contains(expiry)
        && feed.expiries.borrow(expiry).has_latest()
}

/// Return the source-native observation for `expiry`.
public fun source_observation(
    feed: &BlockScholesFeed,
    expiry: u64,
): OracleObservation<BlockScholesSourcePayload> {
    assert!(feed.has_expiry(expiry), EExpiryNotFound);
    feed.expiries.borrow(expiry).latest()
}

/// The underlying spot for `expiry`, 1e9-scaled. Aborts `EExpiryNotFound` if no row.
public fun spot(feed: &BlockScholesFeed, expiry: u64): u64 {
    let observation = feed.source_observation(expiry);
    observation_spot(&observation)
}

/// The forward for `expiry`, 1e9-scaled. Aborts `EExpiryNotFound` if no row.
public fun forward(feed: &BlockScholesFeed, expiry: u64): u64 {
    let observation = feed.source_observation(expiry);
    observation_forward(&observation)
}

/// The SVI params for `expiry`. Aborts `EExpiryNotFound` if no row.
public fun svi(feed: &BlockScholesFeed, expiry: u64): SVIParams {
    let observation = feed.source_observation(expiry);
    observation_svi(&observation)
}

/// Freshness reference for this expiry's surface row: the source timestamp.
/// Aborts `EExpiryNotFound` if no row.
public fun surface_freshness_timestamp_ms(feed: &BlockScholesFeed, expiry: u64): u64 {
    assert!(feed.has_expiry(expiry), EExpiryNotFound);
    feed.expiries.borrow(expiry).freshness_timestamp_ms()
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

public fun observation_bs_source_id(
    observation: &OracleObservation<BlockScholesSourcePayload>,
): u32 {
    observation.payload().bs_source_id
}

public fun observation_expiry_ms(observation: &OracleObservation<BlockScholesSourcePayload>): u64 {
    observation.payload().expiry_ms
}

public fun observation_spot(observation: &OracleObservation<BlockScholesSourcePayload>): u64 {
    observation.payload().spot
}

public fun observation_forward(observation: &OracleObservation<BlockScholesSourcePayload>): u64 {
    observation.payload().forward
}

public fun observation_svi(observation: &OracleObservation<BlockScholesSourcePayload>): SVIParams {
    observation.payload().svi
}

public fun observation_source_timestamp_ms(
    observation: &OracleObservation<BlockScholesSourcePayload>,
): u64 {
    observation.source_timestamp_ms()
}

public fun observation_update_timestamp_ms(
    observation: &OracleObservation<BlockScholesSourcePayload>,
): u64 {
    observation.update_timestamp_ms()
}

// === Write Functions ===

/// Ingest a verified BS snapshot for one expiry. The feed validates only source
/// binding and routes the source-native payload to that expiry's generic oracle
/// lane; the lane owns freshness, history, and event emission.
public fun update_from_bs(
    feed: &mut BlockScholesFeed,
    update: Update,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(feed.version == constants::current_version!(), EWrongVersion);
    assert!(update.source_id() == feed.bs_source_id, EWrongSource);

    let observation = feed.new_observation_from_bs(&update, clock.timestamp_ms());
    let expiry = observation_expiry_ms(&observation);
    feed.add_empty_expiry_if_absent(expiry, ctx);
    let id = feed.id();
    feed.expiries.borrow_mut(expiry).record_observation_if_fresh(id, observation);
}

/// Record an official settlement observation using a BS update. This does not
/// mutate the live per-expiry latest observation or first-observed minute data;
/// official settlement is a separate write-once lane keyed by the update-derived
/// millisecond source timestamp.
///
/// Permissionless by interface: the Update is supposed to be its own provenance
/// proof. CURRENT STUB WARNING: `block_scholes_oracle::update` does not verify
/// signatures yet, so permissionless official BS settlement writes are not
/// production-safe until the real verifier replaces the stub.
public fun record_official_settlement_from_bs(
    feed: &mut BlockScholesFeed,
    update: Update,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(feed.version == constants::current_version!(), EWrongVersion);
    assert!(update.source_id() == feed.bs_source_id, EWrongSource);

    let observation = feed.new_observation_from_bs(&update, clock.timestamp_ms());
    let expiry = observation_expiry_ms(&observation);
    feed.add_empty_expiry_if_absent(expiry, ctx);
    let id = feed.id();
    feed.expiries.borrow_mut(expiry).record_official_settlement(id, observation);
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

fun new_observation_from_bs(
    feed: &BlockScholesFeed,
    update: &Update,
    update_timestamp_ms: u64,
): OracleObservation<BlockScholesSourcePayload> {
    new_observation(feed.bs_source_id, update, update_timestamp_ms)
}

fun new_observation(
    bs_source_id: u32,
    update: &Update,
    update_timestamp_ms: u64,
): OracleObservation<BlockScholesSourcePayload> {
    oracle_lane::new_observation(
        BlockScholesSourcePayload {
            bs_source_id,
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
        update.published_at_ms(),
        update_timestamp_ms,
    )
}

fun add_empty_expiry_if_absent(feed: &mut BlockScholesFeed, expiry_ms: u64, ctx: &mut TxContext) {
    if (!feed.expiries.contains(expiry_ms)) {
        feed
            .expiries
            .add(expiry_ms, oracle_lane::new(empty_payload(feed.bs_source_id, expiry_ms), ctx));
    };
}

fun empty_payload(bs_source_id: u32, expiry_ms: u64): BlockScholesSourcePayload {
    BlockScholesSourcePayload {
        bs_source_id,
        expiry_ms,
        spot: 0,
        forward: 0,
        svi: SVIParams {
            a: 0,
            b: 0,
            rho: i64::from_parts(0, false),
            m: i64::from_parts(0, false),
            sigma: 0,
        },
    }
}

// === Test-Only Functions ===

#[test_only]
public fun set_version_for_testing(feed: &mut BlockScholesFeed, version: u64) {
    feed.version = version;
}
