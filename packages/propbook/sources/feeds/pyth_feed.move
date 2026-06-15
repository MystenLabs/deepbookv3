// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pyth Lazer spot oracle. It decodes verified Lazer updates into source-native
/// payloads, then stores them through a generic Propbook oracle lane. Feed
/// uniqueness per Pyth Lazer source feed is enforced by `registry`.
///
/// Fully permissionless: anyone can create, update, and migrate feeds — the
/// verified `Update` is its own provenance proof. Predict-unaware: it owns no
/// DUSDC conversion, forward derivation, freshness policy, or market-settlement
/// valuation; callers own feed binding and freshness over timestamped reads.
module propbook::pyth_feed;

use fixed_math::math;
use propbook::{constants, oracle_lane::{Self, OracleLane, OracleRead}};
use pyth_lazer::{i16::I16 as LazerI16, i64::I64 as LazerI64, update::Update as LazerUpdate};
use std::option::{Self, Option};
use sui::clock::Clock;

const EWrongVersion: u64 = 0;
const ENotNewerVersion: u64 = 1;
const ERawSpotNotFound: u64 = 2;
const ELazerFeedNotFound: u64 = 3;
const ELazerPriceUnavailable: u64 = 4;
const EInsertTimestampNotExactMillisecond: u64 = 5;

/// Source-native Pyth Lazer spot fields for this feed. The generic oracle lane
/// stores Propbook's canonical millisecond timestamps around this payload;
/// Pyth's native microsecond timestamp remains here for provenance.
public struct RawSpot has copy, drop, store {
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
    lane: OracleLane<RawSpot>,
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

/// Return the package version this feed runs at.
public fun version(feed: &PythFeed): u64 {
    feed.version
}

/// Latest raw Pyth spot read. Aborts `ERawSpotNotFound` if no live update has landed.
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

/// Exact raw Pyth spot read for `timestamp_ms`.
public fun raw_spot_at(feed: &PythFeed, timestamp_ms: u64): OracleRead<RawSpot> {
    let read = feed.lane.read_at(timestamp_ms);
    assert!(read.is_some(), ERawSpotNotFound);
    read.destroy_some()
}

/// Exact Propbook-normalized spot in 1e9 price scaling for `timestamp_ms`.
public fun normalized_spot_at(feed: &PythFeed, timestamp_ms: u64): Option<OracleRead<u64>> {
    let read = feed.lane.read_at(timestamp_ms);
    if (read.is_none()) return option::none();
    normalized_spot_from_read(&read.destroy_some())
}

public fun raw_pyth_source_id(raw: &RawSpot): u32 {
    raw.pyth_source_id
}

public fun raw_price_magnitude(raw: &RawSpot): u64 {
    raw.price_magnitude
}

public fun raw_price_is_negative(raw: &RawSpot): bool {
    raw.price_is_negative
}

public fun raw_exponent_magnitude(raw: &RawSpot): u16 {
    raw.exponent_magnitude
}

public fun raw_exponent_is_negative(raw: &RawSpot): bool {
    raw.exponent_is_negative
}

public fun raw_source_timestamp_us(raw: &RawSpot): u64 {
    raw.source_timestamp_us
}

// === Write Functions ===

/// Decode a verified Pyth Lazer spot update, store it through the feed's generic
/// oracle lane, then emit the update event.
public fun update(feed: &mut PythFeed, update: LazerUpdate, clock: &Clock) {
    assert!(feed.version == constants::current_version!(), EWrongVersion);
    let read = feed.new_read(&update, clock.timestamp_ms());
    let id = feed.id();
    feed.lane.update(id, read);
}

/// Insert an exact Pyth Lazer spot observation keyed by its exact millisecond
/// source timestamp. Aborts `EInsertTimestampNotExactMillisecond` if the signed
/// source timestamp is not a whole millisecond, so the exact-history key is an
/// unambiguous millisecond a consumer can look up by equality. This does not
/// mutate `latest`.
public fun insert_at(feed: &mut PythFeed, update: LazerUpdate, clock: &Clock) {
    assert!(feed.version == constants::current_version!(), EWrongVersion);
    let read = feed.new_insert_read(&update, clock.timestamp_ms());
    let id = feed.id();
    feed.lane.insert_at(id, read);
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
    new_raw_insert_read(raw, update_timestamp_ms)
}

fun raw_spot_from_update(update: &LazerUpdate, pyth_source_id: u32): RawSpot {
    let source_timestamp_us = update.timestamp();
    let feeds = update.feeds_ref();
    let idx_opt = feeds.find_index!(|f| f.feed_id() == pyth_source_id);
    assert_lazer_feed_found(idx_opt.is_some());
    let feed = &feeds[idx_opt.destroy_some()];

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
        source_timestamp_us,
    )
}

fun new_raw_spot(
    pyth_source_id: u32,
    price_magnitude: u64,
    price_is_negative: bool,
    exponent_magnitude: u16,
    exponent_is_negative: bool,
    source_timestamp_us: u64,
): RawSpot {
    RawSpot {
        pyth_source_id,
        price_magnitude,
        price_is_negative,
        exponent_magnitude,
        exponent_is_negative,
        source_timestamp_us,
    }
}

fun new_raw_read(raw: RawSpot, update_timestamp_ms: u64): OracleRead<RawSpot> {
    let source_timestamp_us = raw.source_timestamp_us;
    oracle_lane::new_read(us_to_ms_ceil(source_timestamp_us), update_timestamp_ms, raw)
}

fun new_raw_insert_read(raw: RawSpot, update_timestamp_ms: u64): OracleRead<RawSpot> {
    let source_timestamp_us = raw.source_timestamp_us;
    assert!(
        source_timestamp_us % 1000 == 0,
        EInsertTimestampNotExactMillisecond,
    );
    oracle_lane::new_read(source_timestamp_us / 1000, update_timestamp_ms, raw)
}

fun assert_lazer_feed_found(feed_found: bool) {
    assert!(feed_found, ELazerFeedNotFound);
}

fun extract_lazer_price(price_outer: Option<Option<LazerI64>>): LazerI64 {
    // Both Option layers must be Some: the field must exist in the update, and
    // the value must be present (Lazer returns None without enough publishers).
    assert!(price_outer.is_some(), ELazerPriceUnavailable);
    let price_inner = price_outer.destroy_some();
    assert!(price_inner.is_some(), ELazerPriceUnavailable);
    price_inner.destroy_some()
}

fun extract_lazer_exponent(exp_outer: Option<LazerI16>): LazerI16 {
    assert!(exp_outer.is_some(), ELazerPriceUnavailable);
    exp_outer.destroy_some()
}

fun us_to_ms_ceil(timestamp_us: u64): u64 {
    let ms = timestamp_us / 1000;
    if (timestamp_us % 1000 == 0) ms else ms + 1
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

/// Derived 1e9 normalization from source-native Pyth fields. Returns `none`
/// when the raw source fields have no positive Propbook-normalized spot.
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
    source_timestamp_us: u64,
    update_timestamp_ms: u64,
    insert_at: bool,
) {
    assert!(feed.version == constants::current_version!(), EWrongVersion);
    let raw = new_raw_spot(
        feed.pyth_source_id,
        price_magnitude,
        price_is_negative,
        exponent_magnitude,
        exponent_is_negative,
        source_timestamp_us,
    );
    let read = if (insert_at) {
        new_raw_insert_read(raw, update_timestamp_ms)
    } else {
        new_raw_read(raw, update_timestamp_ms)
    };
    let id = feed.id();
    if (insert_at) {
        feed.lane.insert_at(id, read);
    } else {
        feed.lane.update(id, read);
    };
}

#[test_only]
public fun set_version_for_testing(feed: &mut PythFeed, version: u64) {
    feed.version = version;
}
