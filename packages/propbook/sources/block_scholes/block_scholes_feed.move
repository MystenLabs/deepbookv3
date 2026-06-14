// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Block Scholes volatility-surface oracle: a per-underlying shared object holding
/// a package-version gate, one shared minute-bucket history (the settlement
/// substrate), and a per-expiry `Table<u64, Surface>` of spot + forward + SVI.
/// Each expiry carries its *own* spot, so `basis(expiry) = forward / spot` is exact
/// (the spot and forward are contemporaneous within one expiry's `Update`).
///
/// Unlike `pyth_feed`, this feed has no single global spot (spot is per-expiry), so
/// it does not embed `FeedCore`; it holds the version gate and minute history
/// directly and feeds the minute history from every expiry update (first-wins per
/// minute — all expiries of one underlying carry the same spot at a given instant).
///
/// The verified `Update` is its own provenance proof (today via the
/// `block_scholes_oracle` stub verifier). Predict-unaware: it owns no settlement,
/// valuation lock, or expiry-validity policy; callers own which expiries are real
/// markets.
module propbook::block_scholes_feed;

use block_scholes_oracle::update::Update;
use fixed_math::{i64::{Self, I64}, math};
use propbook::{
    block_scholes_feed_events as bs_events,
    constants,
    minute_history::{Self, MinuteHistory, DataPoint},
    registry::{Self, OracleRegistry}
};
use sui::{clock::Clock, table::{Self, Table}};

const EWrongUnderlying: u64 = 0;
const EExpiryNotFound: u64 = 1;
const EZeroSpot: u64 = 2;
const EFutureSourceUpdate: u64 = 3;
const EWrongVersion: u64 = 4;
const ENotNewerVersion: u64 = 5;
const EZeroForward: u64 = 6;
const EInvalidSviRho: u64 = 7;
const EInvalidSviSigma: u64 = 8;

/// SVI smile parameters; `rho` and `m` are signed (`fixed_math::i64`).
public struct SVIParams has copy, drop, store {
    a: u64,
    b: u64,
    rho: I64,
    m: I64,
    sigma: u64,
}

/// One expiry's spot + forward + SVI row, with the timestamps that wrote it. Spot
/// is per-expiry (contemporaneous with this row's forward), making `basis` exact.
public struct Surface has store {
    /// Underlying spot for this expiry's snapshot, in 1e9 price scaling.
    spot: u64,
    forward: u64,
    svi: SVIParams,
    /// Publisher snapshot timestamp for this expiry's row, in milliseconds.
    source_timestamp_ms: u64,
    /// On-chain landing timestamp.
    update_timestamp_ms: u64,
}

/// One Block Scholes feed: a per-underlying shared object holding the version gate,
/// the shared minute history, and the per-expiry surface table.
public struct BlockScholesFeed has key {
    id: UID,
    underlying: u32,
    /// Package version this feed runs at; updates require an exact match and
    /// `migrate` advances it forward-only after a package upgrade.
    version: u64,
    minutes: MinuteHistory,
    expiries: Table<u64, Surface>,
}

// === Read Functions ===

/// Return the feed object ID.
public fun id(feed: &BlockScholesFeed): ID {
    feed.id.to_inner()
}

/// Return the underlying this feed is bound to.
public fun underlying(feed: &BlockScholesFeed): u32 {
    feed.underlying
}

/// Return the package version this feed runs at.
public fun version(feed: &BlockScholesFeed): u64 {
    feed.version
}

/// Data point recorded for `minute_ms`'s spot bucket. Aborts if the minute was
/// never recorded; use `has_minute` to check first.
public fun price_at_minute(feed: &BlockScholesFeed, minute_ms: u64): DataPoint {
    feed.minutes.price_at_minute(minute_ms)
}

/// Whether a spot tick was recorded for `minute_ms`'s bucket.
public fun has_minute(feed: &BlockScholesFeed, minute_ms: u64): bool {
    feed.minutes.has_minute(minute_ms)
}

/// Whether a surface row exists for `expiry`.
public fun has_expiry(feed: &BlockScholesFeed, expiry: u64): bool {
    feed.expiries.contains(expiry)
}

/// The underlying spot for `expiry`, 1e9-scaled. Aborts `EExpiryNotFound` if no row.
public fun spot(feed: &BlockScholesFeed, expiry: u64): u64 {
    assert!(feed.expiries.contains(expiry), EExpiryNotFound);
    feed.expiries.borrow(expiry).spot
}

/// The forward for `expiry`, 1e9-scaled. Aborts `EExpiryNotFound` if no row.
public fun forward(feed: &BlockScholesFeed, expiry: u64): u64 {
    assert!(feed.expiries.contains(expiry), EExpiryNotFound);
    feed.expiries.borrow(expiry).forward
}

/// The SVI params for `expiry`. Aborts `EExpiryNotFound` if no row.
public fun svi(feed: &BlockScholesFeed, expiry: u64): SVIParams {
    assert!(feed.expiries.contains(expiry), EExpiryNotFound);
    feed.expiries.borrow(expiry).svi
}

/// Basis = forward / spot for `expiry`, 1e9-scaled (exact: both legs are this
/// expiry's contemporaneous values). Aborts `EExpiryNotFound` if no row.
public fun basis(feed: &BlockScholesFeed, expiry: u64): u64 {
    math::div(feed.forward(expiry), feed.spot(expiry))
}

/// Freshness reference for this expiry's surface row: the older of its publisher
/// and on-chain landing timestamps. Aborts `EExpiryNotFound` if no row.
public fun surface_freshness_timestamp_ms(feed: &BlockScholesFeed, expiry: u64): u64 {
    assert!(feed.expiries.contains(expiry), EExpiryNotFound);
    let surface = feed.expiries.borrow(expiry);
    surface.source_timestamp_ms.min(surface.update_timestamp_ms)
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

/// Create and share a BS feed for `underlying`, recording it in the registry
/// under the block_scholes kind so each underlying has exactly one shared feed.
/// Permissionless and safe: identical reasoning to `pyth_feed::create_and_share`.
public fun create_and_share(
    registry: &mut OracleRegistry,
    underlying: u32,
    ctx: &mut TxContext,
): ID {
    let feed = BlockScholesFeed {
        id: object::new(ctx),
        underlying,
        version: constants::current_version!(),
        minutes: minute_history::new(ctx),
        expiries: table::new(ctx),
    };
    let id = feed.id();
    // Aborts EFeedAlreadyExists on a duplicate; the tx is atomic, so a dup
    // reverts the object creation above — no orphaned feed.
    registry.record(registry::kind_block_scholes!(), underlying, id);
    transfer::share_object(feed);
    bs_events::emit_block_scholes_feed_created(underlying, id);
    id
}

/// Ingest a verified BS snapshot for one expiry: validate the version gate and the
/// underlying binding, offer the spot to the shared minute history (first-wins per
/// UTC minute), then write this expiry's surface if the update is newer than the
/// expiry's current row.
///
/// No-op-on-stale (no abort) for the surface: a resend older than this expiry's row
/// leaves it untouched. The version gate, the underlying binding, a zero spot, or a
/// future publisher timestamp abort up front. A surface that is fresh enough to be
/// written must also be math-valid — a zero forward, `|rho| > 1` (the SVI
/// no-arbitrage bound), or `sigma` outside its validity band abort — so the stored
/// `Surface` stays well-defined for any consumer's variance/d2 math (a stale resend
/// of bad data is still a clean no-op, never an abort). The minute bucket is offered
/// on every valid update regardless of surface staleness, since it is the
/// spot-at-minute settlement substrate (a lagging expiry can still fill an empty
/// minute).
public fun update_from_bs(feed: &mut BlockScholesFeed, update: Update, clock: &Clock) {
    assert!(feed.version == constants::current_version!(), EWrongVersion);
    assert!(update.underlying() == feed.underlying, EWrongUnderlying);

    let spot = update.spot();
    let published = update.published_at_ms();
    let landed = clock.timestamp_ms();
    assert!(spot > 0, EZeroSpot);
    assert!(published <= landed, EFutureSourceUpdate);

    feed.minutes.record(minute_history::new_data_point(spot, published, landed));

    let expiry = update.expiry_ms();
    let fresh_surface =
        !feed.expiries.contains(expiry) || published > feed.expiries.borrow(expiry).source_timestamp_ms;
    if (fresh_surface) {
        let forward = update.forward();
        let sigma = update.svi_sigma();
        assert!(forward > 0, EZeroForward);
        // |rho| <= 1: the SVI no-arbitrage bound consumers rely on for a convex,
        // well-defined total-variance smile.
        assert!(update.svi_rho_magnitude() <= math::float_scaling!(), EInvalidSviRho);
        assert!(
            sigma >= constants::svi_sigma_min!() && sigma <= constants::svi_sigma_max!(),
            EInvalidSviSigma,
        );
        let svi = SVIParams {
            a: update.svi_a(),
            b: update.svi_b(),
            rho: i64::from_parts(update.svi_rho_magnitude(), update.svi_rho_is_negative()),
            m: i64::from_parts(update.svi_m_magnitude(), update.svi_m_is_negative()),
            sigma,
        };
        feed.upsert_surface(expiry, spot, forward, svi, published, landed);
    };
}

/// Migrate this feed to the running package version. Forward-only:
/// `current_version!()` is compiled into each package version's bytecode (callers
/// cannot inject an arbitrary version), and the strictly-greater check blocks
/// downgrade griefing. Every package upgrade MUST bump `current_version!()`.
public fun migrate(feed: &mut BlockScholesFeed) {
    assert!(constants::current_version!() > feed.version, ENotNewerVersion);
    feed.version = constants::current_version!();
}

// === Private Functions ===

/// Create the surface row for `expiry_ms` if absent, else overwrite it in place,
/// then emit the surface-updated event. In-place field assignment avoids needing
/// `drop` on `Surface`.
fun upsert_surface(
    feed: &mut BlockScholesFeed,
    expiry_ms: u64,
    spot: u64,
    forward: u64,
    svi: SVIParams,
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
) {
    if (feed.expiries.contains(expiry_ms)) {
        let surface = feed.expiries.borrow_mut(expiry_ms);
        surface.spot = spot;
        surface.forward = forward;
        surface.svi = svi;
        surface.source_timestamp_ms = source_timestamp_ms;
        surface.update_timestamp_ms = update_timestamp_ms;
    } else {
        feed
            .expiries
            .add(
                expiry_ms,
                Surface { spot, forward, svi, source_timestamp_ms, update_timestamp_ms },
            );
    };
    bs_events::emit_block_scholes_surface_updated(
        feed.id(),
        expiry_ms,
        spot,
        forward,
        svi.a,
        svi.b,
        svi.rho,
        svi.m,
        svi.sigma,
        source_timestamp_ms,
        update_timestamp_ms,
    );
}
