// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Decodes verifier-produced Pyth Lazer spot updates and stores their source-native fields in a shared Propbook oracle lane.
/// Writes are permissionless because possession of `LazerUpdate` carries the upstream verification result; the registry separately owns source uniqueness and canonical binding.
/// A Lazer update carries two distinct clocks: the envelope `timestamp()` is when the signed update was published, and the per-feed `feed_update_timestamp()` is when the price it carries was generated. They are equal only when the update carries a freshly generated aggregate; when Pyth has no new aggregate it carries the previous price forward under a newer envelope. `latest` keys on the generation time so a carried price ages by its true age, while the exact-history key stays on the envelope so a settlement tick resolves to the canonical price as of that tick.
/// This module normalizes positive prices to 1e9 scale but leaves freshness and market-use policy to consumers.
module propbook::pyth_feed;

use fixed_math::math;
use propbook::{constants, oracle_lane::{Self, OracleLane, OracleRead}};
use pyth_lazer::{i16::I16 as LazerI16, i64::I64 as LazerI64, update::Update as LazerUpdate};
use sui::clock::Clock;

const EWrongVersion: u64 = 0;
const ENotNewerVersion: u64 = 1;
const ERawSpotNotFound: u64 = 2;
const ELazerFeedNotFound: u64 = 3;
const ELazerValueUnavailable: u64 = 4;
const EInsertTimestampNotExactMillisecond: u64 = 5;
const EFeedTimestampAfterEnvelope: u64 = 6;

/// Source-native Pyth Lazer spot fields, including the microsecond time at which Pyth generated this price.
/// The lane adds Propbook's millisecond ordering key and on-chain recording time around this payload.
public struct RawSpot has copy, drop, store {
    pyth_source_id: u32,
    price_magnitude: u64,
    price_is_negative: bool,
    exponent_magnitude: u16,
    exponent_is_negative: bool,
    feed_update_timestamp_us: u64,
}

/// A versioned Pyth Lazer feed bound to one source ID.
public struct PythFeed has key {
    id: UID,
    pyth_source_id: u32,
    /// Package version this feed runs at; updates require an exact match and
    /// `migrate` advances it forward-only after a package upgrade.
    version: u64,
    lane: OracleLane<RawSpot>,
}

// === Read Functions ===

// Raw reads expose signed source fields for external inspection; normalized reads expose a positive 1e9-scaled spot when the source value is representable.

/// Returns the feed identity for external composition and canonical-binding discovery.
public fun id(feed: &PythFeed): ID {
    feed.id.to_inner()
}

/// Returns the immutable Pyth source ID for external feed inspection.
public fun pyth_source_id(feed: &PythFeed): u32 {
    feed.pyth_source_id
}

/// Returns the write-gating storage version for external feed inspection.
public fun version(feed: &PythFeed): u64 {
    feed.version
}

/// Latest raw Pyth spot for external inspection; aborts if none has landed.
public fun raw_spot(feed: &PythFeed): OracleRead<RawSpot> {
    let read = feed.lane.latest_read();
    assert!(read.is_some(), ERawSpotNotFound);
    read.destroy_some()
}

/// Latest Propbook-normalized spot in 1e9 price scaling.
public fun normalized_spot(feed: &PythFeed): Option<OracleRead<u64>> {
    let read = feed.lane.latest_read();
    if (read.is_none()) return option::none();
    normalized_spot_from_read(&read.destroy_some())
}

/// Exact raw Pyth spot for external timestamp inspection.
public fun raw_spot_at(feed: &PythFeed, source_timestamp_ms: u64): OracleRead<RawSpot> {
    let read = feed.lane.read_at(source_timestamp_ms);
    assert!(read.is_some(), ERawSpotNotFound);
    read.destroy_some()
}

/// Exact Propbook-normalized spot in 1e9 price scaling for `source_timestamp_ms`.
public fun normalized_spot_at(feed: &PythFeed, source_timestamp_ms: u64): Option<OracleRead<u64>> {
    let read = feed.lane.read_at(source_timestamp_ms);
    if (read.is_none()) return option::none();
    normalized_spot_from_read(&read.destroy_some())
}

/// Return the Pyth source ID for external raw-feed inspection.
public fun raw_pyth_source_id(raw: &RawSpot): u32 {
    raw.pyth_source_id
}

/// Return the unsigned price magnitude for external raw-feed inspection.
public fun raw_price_magnitude(raw: &RawSpot): u64 {
    raw.price_magnitude
}

/// Return the price sign for external raw-feed inspection.
public fun raw_price_is_negative(raw: &RawSpot): bool {
    raw.price_is_negative
}

/// Return the unsigned exponent magnitude for external raw-feed inspection.
public fun raw_exponent_magnitude(raw: &RawSpot): u16 {
    raw.exponent_magnitude
}

/// Return the exponent sign for external raw-feed inspection.
public fun raw_exponent_is_negative(raw: &RawSpot): bool {
    raw.exponent_is_negative
}

/// Return the microsecond time at which Pyth generated this price, for external raw-feed inspection.
/// This is the price's true age; it can be older than the envelope that delivered it.
public fun raw_feed_update_timestamp_us(raw: &RawSpot): u64 {
    raw.feed_update_timestamp_us
}

// === Write Functions ===

/// Decode and record a verifier-produced Pyth Lazer update when its generation
/// timestamp advances. A zero, future, duplicate, or stale generation timestamp is
/// ignored without changing `latest` or emitting an event; a price Pyth carried
/// forward therefore leaves `latest` untouched, so redelivery cannot renew a
/// consumer's freshness window. The raw observation may be stored even when its
/// positive normalized projection is unavailable.
public fun update(feed: &mut PythFeed, update: LazerUpdate, clock: &Clock) {
    assert!(feed.version == constants::current_version!(), EWrongVersion);
    let read = feed.new_read(&update, clock.timestamp_ms());
    let id = feed.id();
    feed.lane.update(read, id);
}

/// Insert an exact Pyth Lazer spot observation keyed by its exact millisecond
/// envelope timestamp. Aborts `EInsertTimestampNotExactMillisecond` if the
/// envelope timestamp is not a whole millisecond, so the exact-history key is an
/// unambiguous millisecond a consumer can look up by equality. This does not
/// mutate `latest`. The first lane-valid raw observation owns the key and cannot
/// be replaced, even if its normalized projection is unavailable.
public fun insert_at(feed: &mut PythFeed, update: LazerUpdate, clock: &Clock) {
    assert!(feed.version == constants::current_version!(), EWrongVersion);
    let read = feed.new_insert_read(&update, clock.timestamp_ms());
    let id = feed.id();
    feed.lane.insert_at(read, id);
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
        lane: oracle_lane::new(ctx),
    };
    let id = feed.id();
    transfer::share_object(feed);
    id
}

// === Private Functions ===

fun new_read(feed: &PythFeed, update: &LazerUpdate, update_timestamp_ms: u64): OracleRead<RawSpot> {
    let raw = raw_spot_from_update(update, feed.pyth_source_id);
    new_raw_read(raw, update_timestamp_ms)
}

fun new_insert_read(
    feed: &PythFeed,
    update: &LazerUpdate,
    update_timestamp_ms: u64,
): OracleRead<RawSpot> {
    let raw = raw_spot_from_update(update, feed.pyth_source_id);
    new_raw_insert_read(raw, update.timestamp(), update_timestamp_ms)
}

fun raw_spot_from_update(update: &LazerUpdate, pyth_source_id: u32): RawSpot {
    let envelope_timestamp_us = update.timestamp();
    let feeds = update.feeds_ref();
    let idx_opt = feeds.find_index!(|f| f.feed_id() == pyth_source_id);
    assert!(idx_opt.is_some(), ELazerFeedNotFound);
    let feed = &feeds[idx_opt.destroy_some()];

    let feed_update_timestamp_us = extract_lazer_feed_update_timestamp(feed.feed_update_timestamp());
    // Pyth generates a price at or before the envelope that delivers it; a later
    // generation time means the payload does not describe a realizable observation.
    assert!(feed_update_timestamp_us <= envelope_timestamp_us, EFeedTimestampAfterEnvelope);
    let price = extract_lazer_price(feed.price());
    let exponent = extract_lazer_exponent(feed.exponent());
    let price_is_negative = price.get_is_negative();
    let price_magnitude = if (price_is_negative) {
        price.get_magnitude_if_negative()
    } else {
        price.get_magnitude_if_positive()
    };
    let exponent_is_negative = exponent.get_is_negative();
    let exponent_magnitude = if (exponent_is_negative) {
        exponent.get_magnitude_if_negative()
    } else {
        exponent.get_magnitude_if_positive()
    };

    new_raw_spot(
        pyth_source_id,
        price_magnitude,
        price_is_negative,
        exponent_magnitude,
        exponent_is_negative,
        feed_update_timestamp_us,
    )
}

fun new_raw_spot(
    pyth_source_id: u32,
    price_magnitude: u64,
    price_is_negative: bool,
    exponent_magnitude: u16,
    exponent_is_negative: bool,
    feed_update_timestamp_us: u64,
): RawSpot {
    RawSpot {
        pyth_source_id,
        price_magnitude,
        price_is_negative,
        exponent_magnitude,
        exponent_is_negative,
        feed_update_timestamp_us,
    }
}

/// Keys `latest` by the time Pyth generated the price, so a price carried forward
/// under a newer envelope keeps its true age and ages out of a consumer's freshness
/// window instead of being refreshed by redelivery.
fun new_raw_read(raw: RawSpot, update_timestamp_ms: u64): OracleRead<RawSpot> {
    let feed_update_timestamp_us = raw.feed_update_timestamp_us;
    // Rounding source microseconds up prevents the millisecond key from preceding the observation; its apparent age can be less than the true age by under one millisecond.
    oracle_lane::new_read(feed_update_timestamp_us.div_ceil(1000), update_timestamp_ms, raw)
}

/// Keys exact history by the envelope, not the generation time: the envelope at a
/// tick carries Pyth's canonical price as of that tick, which is the mark a consumer
/// settling at that tick wants even when the price was generated earlier. The stored
/// payload retains the generation time so the settled price's true age stays legible.
fun new_raw_insert_read(
    raw: RawSpot,
    envelope_timestamp_us: u64,
    update_timestamp_ms: u64,
): OracleRead<RawSpot> {
    assert!(envelope_timestamp_us % 1000 == 0, EInsertTimestampNotExactMillisecond);
    oracle_lane::new_read(envelope_timestamp_us / 1000, update_timestamp_ms, raw)
}

fun extract_lazer_price(price_outer: Option<Option<LazerI64>>): LazerI64 {
    // Both Option layers must be Some: the field must exist in the update, and
    // the value must be present (Lazer returns None without enough publishers).
    assert!(price_outer.is_some(), ELazerValueUnavailable);
    let price_inner = price_outer.destroy_some();
    assert!(price_inner.is_some(), ELazerValueUnavailable);
    price_inner.destroy_some()
}

fun extract_lazer_exponent(exp_outer: Option<LazerI16>): LazerI16 {
    assert!(exp_outer.is_some(), ELazerValueUnavailable);
    exp_outer.destroy_some()
}

fun extract_lazer_feed_update_timestamp(timestamp_outer: Option<Option<u64>>): u64 {
    // Both Option layers must be Some: the subscribing client must request the
    // property, and Pyth must have a generation time for this feed's value.
    assert!(timestamp_outer.is_some(), ELazerValueUnavailable);
    let timestamp_inner = timestamp_outer.destroy_some();
    assert!(timestamp_inner.is_some(), ELazerValueUnavailable);
    timestamp_inner.destroy_some()
}

fun normalized_spot_from_read(read: &OracleRead<RawSpot>): Option<OracleRead<u64>> {
    let raw = read.read_value();
    let spot = normalize_raw_spot(&raw);
    if (spot.is_none()) {
        option::none()
    } else {
        option::some(
            oracle_lane::new_read(
                read.read_source_timestamp_ms(),
                read.read_update_timestamp_ms(),
                spot.destroy_some(),
            ),
        )
    }
}

/// Normalizes source-native Pyth fields to a positive 1e9-scaled spot.
/// Returns `none` for negative or zero values, unsupported decimal shifts, or a result outside `u64`.
fun normalize_raw_spot(raw: &RawSpot): Option<u64> {
    if (raw.price_is_negative) return option::none();

    let target = constants::float_scaling_decimals!();
    let exp_mag = raw.exponent_magnitude as u64;

    let normalized = if (raw.exponent_is_negative) {
        if (exp_mag <= target) {
            let scaled = scale_up(raw.price_magnitude, target - exp_mag);
            if (scaled.is_none()) return option::none();
            scaled.destroy_some()
        } else {
            // Round down when the source has finer precision than Propbook's 1e9 scale.
            let shift = exp_mag - target;
            if (shift > 18) return option::none();
            raw.price_magnitude / math::pow10(shift)
        }
    } else {
        let scaled = scale_up(raw.price_magnitude, target + exp_mag);
        if (scaled.is_none()) return option::none();
        scaled.destroy_some()
    };
    if (normalized == 0) {
        option::none()
    } else {
        option::some(normalized)
    }
}

fun scale_up(magnitude: u64, shift: u64): Option<u64> {
    if (shift > 18) return option::none();
    let factor = math::pow10(shift);
    let scaled = (magnitude as u128) * (factor as u128);
    if (scaled > (std::u64::max_value!() as u128)) {
        option::none()
    } else {
        option::some(scaled as u64)
    }
}

// === Test-Only Functions ===

#[test_only]
public fun record_raw_for_testing(
    feed: &mut PythFeed,
    price_magnitude: u64,
    price_is_negative: bool,
    exponent_magnitude: u16,
    exponent_is_negative: bool,
    feed_update_timestamp_us: u64,
    envelope_timestamp_us: u64,
    update_timestamp_ms: u64,
    insert_at: bool,
) {
    assert!(feed.version == constants::current_version!(), EWrongVersion);
    assert!(feed_update_timestamp_us <= envelope_timestamp_us, EFeedTimestampAfterEnvelope);
    let raw = new_raw_spot(
        feed.pyth_source_id,
        price_magnitude,
        price_is_negative,
        exponent_magnitude,
        exponent_is_negative,
        feed_update_timestamp_us,
    );
    let read = if (insert_at) {
        new_raw_insert_read(raw, envelope_timestamp_us, update_timestamp_ms)
    } else {
        new_raw_read(raw, update_timestamp_ms)
    };
    let id = feed.id();
    if (insert_at) {
        feed.lane.insert_at(read, id);
    } else {
        feed.lane.update(read, id);
    };
}
