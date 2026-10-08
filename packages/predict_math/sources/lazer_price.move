// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A Pyth Lazer price decoded from a verified update, for Predict's order-flow
/// commit.
///
/// A `LazerPrice` is built only from a `pyth_lazer::update::Update`, which only
/// Pyth's verifier produces, so holding one proves a Pyth signature over its
/// feed, channel, timestamps, and price. It has `copy` and `drop` but not
/// `store`, so it lives within one transaction. The decode is Predict v4's queue
/// commit decode: it aborts on an update that does not carry the requested feed
/// or lacks its price, exponent, or feed-update-time property, because the
/// caller then passed the wrong update, and it returns `none` only when the feed
/// has no usable price at that tick: an empty price or update time, or a price
/// that does not normalize to Predict's pricing-safe 1e9 spot.
module deepbook_predict_math::lazer_price;

use fixed_math::math;
use pyth_lazer::{i16::I16, i64::I64, update::Update};

const EPropertyNotRequested: u64 = 0;
const EGenerationAfterEnvelope: u64 = 1;
const EFeedMissing: u64 = 2;

/// A decoded, normalized price for one feed of one verified Lazer update.
public struct LazerPrice has copy, drop {
    feed_id: u32,
    /// A Lazer channel id: `channel_fixed_rate_50ms!()`,
    /// `channel_fixed_rate_200ms!()`, or `1` for real-time.
    channel: u8,
    /// The update's timestamp, in µs.
    envelope_us: u64,
    /// The feed's own update time, in µs. Never after the envelope.
    generation_us: u64,
    /// The price normalized to 1e9, rounded down when the source is finer;
    /// positive and at most `u64::MAX / 100`.
    spot: u64,
}

// === Channels ===

/// Lazer channel id of `fixed_rate@50ms`.
public macro fun channel_fixed_rate_50ms(): u8 { 2 }

/// Lazer channel id of `fixed_rate@200ms`.
public macro fun channel_fixed_rate_200ms(): u8 { 3 }

/// Tick period of a fixed-rate channel, in ms: 50 for `fixed_rate@50ms`, else 200.
public macro fun channel_tick_ms($channel: u8): u64 {
    if ($channel == channel_fixed_rate_50ms!()) 50 else 200
}

/// Decimal exponent of Predict's 1e9 spot scale.
macro fun spot_decimals(): u64 { 9 }

/// Predict's pricing-safe spot ceiling, `u64::MAX / 100`.
macro fun max_spot(): u64 { std::u64::max_value!() / 100 }

// === Public Functions ===

/// Decode `feed_id` from a verified Lazer update. `none` when the feed's price or
/// update time is empty at this tick, or its price does not normalize to a
/// pricing-safe spot. Aborts `EFeedMissing` when the update does not carry the
/// feed and `EPropertyNotRequested` when the feed lacks the price, exponent, or
/// update-time property, because the caller then passed the wrong update, and
/// `EGenerationAfterEnvelope` when the feed claims an update time after the
/// envelope that carries it.
///
/// Uses Lazer's v1 `Update`, which Pyth marked deprecated on Mainnet but still
/// serves; a later library upgrade adds a constructor for v2.
#[allow(deprecated_usage)]
public fun from_update(update: &Update, feed_id: u32): Option<LazerPrice> {
    let channel = update.channel();
    let channel = if (channel.is_fixed_rate_50ms()) {
        channel_fixed_rate_50ms!()
    } else if (channel.is_fixed_rate_200ms()) {
        channel_fixed_rate_200ms!()
    } else {
        1
    };
    let feeds = update.feeds_ref();
    let feed = &feeds[feed_index(&feeds.map_ref!(|feed| feed.feed_id()), feed_id)];
    from_parts(
        feed_id,
        channel,
        update.timestamp(),
        feed.price(),
        feed.exponent(),
        feed.feed_update_timestamp(),
    )
}

// === Getters ===

public fun feed_id(price: &LazerPrice): u32 { price.feed_id }

public fun channel(price: &LazerPrice): u8 { price.channel }

public fun envelope_us(price: &LazerPrice): u64 { price.envelope_us }

public fun generation_us(price: &LazerPrice): u64 { price.generation_us }

public fun spot(price: &LazerPrice): u64 { price.spot }

// === Public-Package Functions ===

/// The position of `feed_id` among an update's feed IDs. Aborts `EFeedMissing`
/// when the update does not carry it.
public(package) fun feed_index(feed_ids: &vector<u32>, feed_id: u32): u64 {
    let index = feed_ids.find_index!(|id| *id == feed_id);
    assert!(index.is_some(), EFeedMissing);
    index.destroy_some()
}

/// `from_update` over one feed's decoded properties, in Lazer's own `Option`
/// layers: an outer `none` means the property was not requested, an inner `none`
/// that it was requested but empty.
public(package) fun from_parts(
    feed_id: u32,
    channel: u8,
    envelope_us: u64,
    price: Option<Option<I64>>,
    exponent: Option<I16>,
    update_time: Option<Option<u64>>,
): Option<LazerPrice> {
    assert!(
        price.is_some() && exponent.is_some() && update_time.is_some(),
        EPropertyNotRequested,
    );
    let generation_us = update_time.destroy_some();
    if (generation_us.is_none()) return option::none();
    let generation_us = generation_us.destroy_some();
    assert!(generation_us <= envelope_us, EGenerationAfterEnvelope);
    let price = price.destroy_some();
    if (price.is_none()) return option::none();
    let price = price.destroy_some();
    let exponent = exponent.destroy_some();
    let exponent_is_negative = exponent.get_is_negative();
    let exponent_magnitude = if (exponent_is_negative) {
        exponent.get_magnitude_if_negative()
    } else {
        exponent.get_magnitude_if_positive()
    };
    let is_negative = price.get_is_negative();
    let magnitude = if (is_negative) {
        price.get_magnitude_if_negative()
    } else {
        price.get_magnitude_if_positive()
    };
    normalize_spot(magnitude, is_negative, exponent_magnitude, exponent_is_negative).map!(
        |spot| LazerPrice { feed_id, channel, envelope_us, generation_us, spot },
    )
}

/// Normalize a Lazer price and exponent to the 1e9 spot scale, rounding down
/// when the source is finer. `none` for a zero or negative price, a decimal
/// shift past 18, a result that rounds to zero, or a spot above the
/// pricing-safe ceiling (which also covers overflow).
public(package) fun normalize_spot(
    magnitude: u64,
    is_negative: bool,
    exponent_magnitude: u16,
    exponent_is_negative: bool,
): Option<u64> {
    if (is_negative) return option::none();
    let target = spot_decimals!();
    let exponent = exponent_magnitude as u64;
    let spot = if (exponent_is_negative && exponent > target) {
        let shift = exponent - target;
        if (shift > 18) return option::none();
        (magnitude / math::pow10(shift)) as u128
    } else {
        let shift = if (exponent_is_negative) target - exponent else target + exponent;
        if (shift > 18) return option::none();
        (magnitude as u128) * (math::pow10(shift) as u128)
    };
    if (spot == 0 || spot > (max_spot!() as u128)) return option::none();
    option::some(spot as u64)
}

// === Test-Only Functions ===

#[test_only]
public fun new_for_testing(
    feed_id: u32,
    channel: u8,
    envelope_us: u64,
    generation_us: u64,
    spot: u64,
): LazerPrice {
    LazerPrice { feed_id, channel, envelope_us, generation_us, spot }
}
