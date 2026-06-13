// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Block Scholes volatility-surface oracle: a thin wrapper embedding the shared
/// `FeedCore` (latest underlying spot + version gate + minute history) plus a
/// per-expiry `Table<u64, Surface>` of forward + SVI params. Mirrors `pyth_feed`
/// in shape; the `expiries` table is the only BS-specific state.
///
/// The verified `Update` is its own provenance proof (today via the
/// `block_scholes_oracle` stub verifier). Predict-unaware: it owns no settlement,
/// valuation lock, or expiry-validity policy; callers own which expiries are real
/// markets.
module propbook::block_scholes_feed;

use block_scholes_oracle::update::Update;
use predict_math::{i64::{Self, I64}, math};
use propbook::{
    block_scholes_feed_events as bs_events,
    feed_core::{Self, FeedCore},
    minute_history::DataPoint,
    registry::{Self, OracleRegistry}
};
use sui::{clock::Clock, table::{Self, Table}};

const EWrongUnderlying: u64 = 0;
const EExpiryNotFound: u64 = 1;

/// SVI smile parameters; `rho` and `m` are signed (`predict_math::i64`).
public struct SVIParams has copy, drop, store {
    a: u64,
    b: u64,
    rho: I64,
    m: I64,
    sigma: u64,
}

/// One expiry's forward + SVI row, with the timestamps that wrote it.
public struct Surface has store {
    forward: u64,
    svi: SVIParams,
    /// Publisher snapshot timestamp for this expiry's row, in milliseconds.
    source_timestamp_ms: u64,
    /// On-chain landing timestamp.
    update_timestamp_ms: u64,
}

/// One Block Scholes feed: a shared object wrapping the embedded `FeedCore` plus
/// the per-expiry surface table.
public struct BlockScholesFeed has key {
    id: UID,
    core: FeedCore,
    expiries: Table<u64, Surface>,
}

// === Read Functions ===

/// Return the feed object ID.
public fun id(feed: &BlockScholesFeed): ID {
    feed.id.to_inner()
}

/// Return the underlying this feed is bound to.
public fun underlying(feed: &BlockScholesFeed): u32 {
    feed.core.feed_id()
}

/// Return the latest underlying spot in 1e9 price scaling.
public fun spot(feed: &BlockScholesFeed): u64 {
    feed.core.spot()
}

/// Return the publisher snapshot timestamp of the latest accepted update.
public fun source_timestamp_ms(feed: &BlockScholesFeed): u64 {
    feed.core.source_timestamp_ms()
}

/// Return the on-chain landing timestamp of the latest accepted update.
public fun update_timestamp_ms(feed: &BlockScholesFeed): u64 {
    feed.core.update_timestamp_ms()
}

/// Freshness reference for consumers: the older of the publisher and on-chain
/// landing timestamps.
public fun freshness_timestamp_ms(feed: &BlockScholesFeed): u64 {
    feed.core.freshness_timestamp_ms()
}

/// Return the package version this feed runs at.
public fun version(feed: &BlockScholesFeed): u64 {
    feed.core.version()
}

/// Data point recorded for `minute_ms`'s spot bucket. Aborts if the minute was
/// never recorded; use `has_minute` to check first.
public fun price_at_minute(feed: &BlockScholesFeed, minute_ms: u64): DataPoint {
    feed.core.price_at_minute(minute_ms)
}

/// Whether a spot tick was recorded for `minute_ms`'s bucket.
public fun has_minute(feed: &BlockScholesFeed, minute_ms: u64): bool {
    feed.core.has_minute(minute_ms)
}

/// Whether a surface row exists for `expiry`.
public fun has_expiry(feed: &BlockScholesFeed, expiry: u64): bool {
    feed.expiries.contains(expiry)
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

/// Basis = forward / spot for `expiry`, 1e9-scaled. Aborts `EExpiryNotFound`.
public fun basis(feed: &BlockScholesFeed, expiry: u64): u64 {
    math::div(feed.forward(expiry), feed.core.spot())
}

/// Freshness reference for this expiry's surface row: the older of its publisher
/// and on-chain landing timestamps (the surface can lag the global spot, so it
/// carries its own freshness). Aborts `EExpiryNotFound` if no row.
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
        core: feed_core::new(underlying, ctx),
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

/// Ingest a verified BS snapshot for one expiry: validate the underlying binding,
/// then update the shared spot and this expiry's surface with *independent*
/// freshness.
///
/// Spot and surface advance separately, each no-op-on-stale (no abort): a stale
/// resend that advances neither side is a clean no-op; only the version gate, the
/// underlying binding, and a malformed payload (zero spot / future timestamp)
/// abort. Because `core` tracks the max source timestamp across all expiries, a
/// fresh spot implies a fresh surface — so "spot event without surface event"
/// never happens, while "surface event without spot event" (a lagging expiry
/// catching up) is expected.
public fun update_from_bs(feed: &mut BlockScholesFeed, update: Update, clock: &Clock) {
    assert!(update.underlying() == feed.core.feed_id(), EWrongUnderlying);

    let published = update.published_at_ms();
    let landed = clock.timestamp_ms();

    // Spot: version/zero/future gate inside even when stale; writes + records the
    // minute bucket only if this update advances the shared spot.
    let spot_advanced = feed.core.store_tick_if_fresh(update.spot(), published, landed);
    if (spot_advanced) {
        bs_events::emit_block_scholes_spot_updated(
            feed.id(),
            update.underlying(),
            update.spot(),
            published,
            landed,
        );
    };

    // Surface: independent per-expiry freshness — newer than this expiry's own row.
    let expiry = update.expiry_ms();
    let fresh_surface =
        !feed.expiries.contains(expiry) || published > feed.expiries.borrow(expiry).source_timestamp_ms;
    if (fresh_surface) {
        let svi = SVIParams {
            a: update.svi_a(),
            b: update.svi_b(),
            rho: i64::from_parts(update.svi_rho_magnitude(), update.svi_rho_is_negative()),
            m: i64::from_parts(update.svi_m_magnitude(), update.svi_m_is_negative()),
            sigma: update.svi_sigma(),
        };
        feed.upsert_surface(expiry, update.forward(), svi, published, landed);
    };
}

/// Migrate this feed to the running package version (forward-only). See
/// `feed_core::migrate`.
public fun migrate(feed: &mut BlockScholesFeed) {
    feed.core.migrate();
}

// === Private Functions ===

/// Create the surface row for `expiry_ms` if absent, else overwrite it in place,
/// then emit the surface-updated event. In-place field assignment avoids needing
/// `drop` on `Surface`.
fun upsert_surface(
    feed: &mut BlockScholesFeed,
    expiry_ms: u64,
    forward: u64,
    svi: SVIParams,
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
) {
    if (feed.expiries.contains(expiry_ms)) {
        let surface = feed.expiries.borrow_mut(expiry_ms);
        surface.forward = forward;
        surface.svi = svi;
        surface.source_timestamp_ms = source_timestamp_ms;
        surface.update_timestamp_ms = update_timestamp_ms;
    } else {
        feed
            .expiries
            .add(expiry_ms, Surface { forward, svi, source_timestamp_ms, update_timestamp_ms });
    };
    bs_events::emit_block_scholes_surface_updated(
        feed.id(),
        expiry_ms,
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
