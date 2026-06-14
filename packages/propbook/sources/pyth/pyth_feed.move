// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pyth Lazer spot oracle. It decodes verified Lazer updates into source-native
/// payloads, then stores them through a generic Propbook oracle lane. Feed
/// uniqueness per Pyth Lazer source feed is enforced by `registry`.
///
/// Fully permissionless: anyone can create, update, and migrate feeds — the
/// verified `Update` is its own provenance proof. Predict-unaware: it owns no
/// DUSDC conversion, forward derivation, freshness policy, or market-settlement
/// valuation; callers own feed binding and freshness (read `freshness_timestamp_ms`).
module propbook::pyth_feed;

use propbook::{constants, lazer_decode, oracle_lane::{Self, OracleLane, OracleObservation}};
use pyth_lazer::update::Update as LazerUpdate;
use sui::clock::Clock;

const EWrongVersion: u64 = 0;
const ENotNewerVersion: u64 = 1;
const ENoLatest: u64 = 2;

/// One source-native Pyth Lazer payload for this feed. The generic oracle lane
/// stores Propbook's canonical millisecond timestamps around this payload; Pyth's
/// native microsecond timestamp remains here for provenance.
public struct PythSourcePayload has copy, drop, store {
    pyth_source_id: u32,
    price_magnitude: u64,
    price_is_negative: bool,
    exponent_magnitude: u16,
    exponent_is_negative: bool,
    source_timestamp_us: u64,
}

/// One Pyth Lazer feed: version gate plus one generic oracle lane.
public struct PythFeed has key {
    id: UID,
    pyth_source_id: u32,
    /// Package version this feed runs at; updates require an exact match and
    /// `migrate` advances it forward-only after a package upgrade.
    version: u64,
    lane: OracleLane<PythSourcePayload>,
}

// === Read Functions ===

/// Return the feed object ID.
public fun id(feed: &PythFeed): ID {
    feed.id.to_inner()
}

/// Return the configured Pyth source id.
public fun pyth_source_id(feed: &PythFeed): u32 {
    feed.pyth_source_id
}

/// Whether this feed has accepted a live source observation.
public fun has_latest(feed: &PythFeed): bool {
    feed.lane.has_latest()
}

/// Return the latest positive-only normalized spot in 1e9 price scaling.
/// Aborts `ENoLatest` if no live update has landed yet, and aborts if the
/// source-native value cannot be represented as a positive Propbook spot.
public fun spot(feed: &PythFeed): u64 {
    let observation = feed.latest_observation();
    normalized_spot_1e9(&observation)
}

/// Return the publisher timestamp of the latest accepted observation, in
/// microseconds.
public fun source_timestamp_us(feed: &PythFeed): u64 {
    let observation = feed.latest_observation();
    observation_source_timestamp_us(&observation)
}

/// Return the publisher timestamp of the latest accepted observation, in
/// milliseconds.
public fun source_timestamp_ms(feed: &PythFeed): u64 {
    feed.latest_observation().source_timestamp_ms()
}

/// Return the on-chain landing timestamp of the latest accepted observation.
public fun update_timestamp_ms(feed: &PythFeed): u64 {
    feed.latest_observation().update_timestamp_ms()
}

/// Freshness reference for consumers: the latest source timestamp, or `0` if no
/// live update has landed yet.
public fun freshness_timestamp_ms(feed: &PythFeed): u64 {
    feed.lane.freshness_timestamp_ms()
}

/// Return the package version this feed runs at.
public fun version(feed: &PythFeed): u64 {
    feed.version
}

/// First-observed update recorded for `minute_ms`'s bucket. Aborts if the minute
/// was never recorded; use `has_observation` to check first.
public fun observation_at_minute(
    feed: &PythFeed,
    minute_ms: u64,
): OracleObservation<PythSourcePayload> {
    feed.lane.observation_at_minute(minute_ms)
}

/// Whether this feed has a first-observed update for `minute_ms`'s bucket.
public fun has_observation(feed: &PythFeed, minute_ms: u64): bool {
    feed.lane.has_observation(minute_ms)
}

/// Official settlement observation recorded for exact `resolution_timestamp_ms`.
/// Aborts if the official settlement timestamp was never recorded.
public fun official_observation_at_resolution(
    feed: &PythFeed,
    resolution_timestamp_ms: u64,
): OracleObservation<PythSourcePayload> {
    feed.lane.official_observation_at_resolution(resolution_timestamp_ms)
}

/// Whether this feed has official settlement data for exact
/// `resolution_timestamp_ms`.
public fun has_official_settlement(feed: &PythFeed, resolution_timestamp_ms: u64): bool {
    feed.lane.has_official_settlement(resolution_timestamp_ms)
}

/// Return the source-native latest observation. Aborts `ENoLatest` if no live
/// update has landed yet.
public fun latest_observation(feed: &PythFeed): OracleObservation<PythSourcePayload> {
    assert!(feed.has_latest(), ENoLatest);
    feed.lane.latest()
}

public fun observation_pyth_source_id(observation: &OracleObservation<PythSourcePayload>): u32 {
    observation.payload().pyth_source_id
}

public fun price_magnitude(observation: &OracleObservation<PythSourcePayload>): u64 {
    observation.payload().price_magnitude
}

public fun price_is_negative(observation: &OracleObservation<PythSourcePayload>): bool {
    observation.payload().price_is_negative
}

public fun exponent_magnitude(observation: &OracleObservation<PythSourcePayload>): u16 {
    observation.payload().exponent_magnitude
}

public fun exponent_is_negative(observation: &OracleObservation<PythSourcePayload>): bool {
    observation.payload().exponent_is_negative
}

public fun observation_source_timestamp_us(
    observation: &OracleObservation<PythSourcePayload>,
): u64 {
    observation.payload().source_timestamp_us
}

public fun observation_source_timestamp_ms(
    observation: &OracleObservation<PythSourcePayload>,
): u64 {
    observation.source_timestamp_ms()
}

public fun observation_update_timestamp_ms(
    observation: &OracleObservation<PythSourcePayload>,
): u64 {
    observation.update_timestamp_ms()
}

/// Positive-only normalized spot in 1e9 price scaling for this source
/// observation. Raw Pyth fields are available through the payload getters for
/// consumers that need source-native data instead.
public fun normalized_spot_1e9(observation: &OracleObservation<PythSourcePayload>): u64 {
    let payload = observation.payload();
    let parts = lazer_decode::new_price_parts(
        payload.price_magnitude,
        payload.price_is_negative,
        payload.exponent_magnitude,
        payload.exponent_is_negative,
        payload.source_timestamp_us,
    );
    lazer_decode::normalize_pyth_price_parts(&parts)
}

// === Write Functions ===

/// Decode a verified Pyth Lazer spot update, store it through the feed's generic
/// oracle lane, then emit the update event.
public fun update_from_lazer(feed: &mut PythFeed, update: LazerUpdate, clock: &Clock) {
    assert!(feed.version == constants::current_version!(), EWrongVersion);
    let observation = feed.new_observation_from_lazer(&update, clock.timestamp_ms());
    let id = feed.id();
    feed.lane.record_observation_if_fresh(id, observation);
}

/// Record an official settlement observation using a verified Pyth Lazer update.
/// This does not mutate `latest` or first-observed minute data; official
/// settlement is a separate write-once lane keyed by the update-derived
/// millisecond source timestamp.
public fun record_official_settlement_from_lazer(
    feed: &mut PythFeed,
    update: LazerUpdate,
    clock: &Clock,
) {
    assert!(feed.version == constants::current_version!(), EWrongVersion);
    let observation = feed.new_observation_from_lazer(&update, clock.timestamp_ms());
    let id = feed.id();
    feed.lane.record_official_settlement(id, observation);
}

/// Migrate this feed to the running package version (forward-only).
public fun migrate(feed: &mut PythFeed) {
    assert!(constants::current_version!() > feed.version, ENotNewerVersion);
    feed.version = constants::current_version!();
}

// === Public-Package Functions ===

/// Create and share a feed for `pyth_source_id`. Package-only: `registry` owns
/// source-catalog uniqueness and calls this helper after checking duplicates.
public(package) fun create_and_share(pyth_source_id: u32, ctx: &mut TxContext): ID {
    let feed = PythFeed {
        id: object::new(ctx),
        pyth_source_id,
        version: constants::current_version!(),
        lane: oracle_lane::new(empty_payload(pyth_source_id), ctx),
    };
    let id = feed.id();
    transfer::share_object(feed);
    id
}

// === Private Functions ===

fun new_observation_from_lazer(
    feed: &PythFeed,
    update: &LazerUpdate,
    update_timestamp_ms: u64,
): OracleObservation<PythSourcePayload> {
    let parts = lazer_decode::extract_source_price(update, feed.pyth_source_id);
    new_observation(feed.pyth_source_id, &parts, update_timestamp_ms)
}

fun new_observation(
    pyth_source_id: u32,
    parts: &lazer_decode::LazerPriceParts,
    update_timestamp_ms: u64,
): OracleObservation<PythSourcePayload> {
    oracle_lane::new_observation(
        PythSourcePayload {
            pyth_source_id,
            price_magnitude: parts.price_magnitude(),
            price_is_negative: parts.price_is_negative(),
            exponent_magnitude: parts.exponent_magnitude(),
            exponent_is_negative: parts.exponent_is_negative(),
            source_timestamp_us: parts.source_timestamp_us(),
        },
        source_timestamp_ms_from_us(parts.source_timestamp_us()),
        update_timestamp_ms,
    )
}

fun empty_payload(pyth_source_id: u32): PythSourcePayload {
    PythSourcePayload {
        pyth_source_id,
        price_magnitude: 0,
        price_is_negative: false,
        exponent_magnitude: 0,
        exponent_is_negative: false,
        source_timestamp_us: 0,
    }
}

fun source_timestamp_ms_from_us(source_timestamp_us: u64): u64 {
    lazer_decode::us_to_ms_ceil(source_timestamp_us)
}

// === Test-Only Functions ===

/// Apply an already-decoded source observation through the same generic lane path
/// as `update_from_lazer`, since a real `pyth_lazer::Update` has no Move-side
/// test constructor.
#[test_only]
public fun store_observation_for_testing(
    feed: &mut PythFeed,
    price_magnitude: u64,
    price_is_negative: bool,
    exponent_magnitude: u16,
    exponent_is_negative: bool,
    source_timestamp_us: u64,
    update_timestamp_ms: u64,
) {
    assert!(feed.version == constants::current_version!(), EWrongVersion);
    let parts = lazer_decode::new_price_parts(
        price_magnitude,
        price_is_negative,
        exponent_magnitude,
        exponent_is_negative,
        source_timestamp_us,
    );
    let observation = new_observation(feed.pyth_source_id, &parts, update_timestamp_ms);
    let id = feed.id();
    feed.lane.record_observation_if_fresh(id, observation);
}

#[test_only]
public fun record_official_settlement_for_testing(
    feed: &mut PythFeed,
    price_magnitude: u64,
    price_is_negative: bool,
    exponent_magnitude: u16,
    exponent_is_negative: bool,
    source_timestamp_us: u64,
    update_timestamp_ms: u64,
) {
    assert!(feed.version == constants::current_version!(), EWrongVersion);
    let parts = lazer_decode::new_price_parts(
        price_magnitude,
        price_is_negative,
        exponent_magnitude,
        exponent_is_negative,
        source_timestamp_us,
    );
    let observation = new_observation(feed.pyth_source_id, &parts, update_timestamp_ms);
    let id = feed.id();
    feed.lane.record_official_settlement(id, observation);
}

#[test_only]
public fun set_version_for_testing(feed: &mut PythFeed, version: u64) {
    feed.version = version;
}
