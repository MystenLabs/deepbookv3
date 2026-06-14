// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pure Pyth Lazer payload decoding for `pyth_feed`: pull one feed's source-native
/// `(price, exponent)` fields out of a verified `Update`, and provide a derived
/// 1e9-normalization helper for Propbook reads.
module propbook::lazer_decode;

use fixed_math::math;
use propbook::constants;
use pyth_lazer::{i16::I16 as LazerI16, i64::I64 as LazerI64, update::Update as LazerUpdate};
use std::option::Option;

const ELazerFeedNotFound: u64 = 0;
const ELazerPriceUnavailable: u64 = 1;
const ELazerNegativePrice: u64 = 2;

/// Source-native Pyth Lazer price fields extracted from one feed in a verified
/// update.
public struct LazerPriceParts has copy, drop {
    price_magnitude: u64,
    price_is_negative: bool,
    exponent_magnitude: u16,
    exponent_is_negative: bool,
    source_timestamp_us: u64,
}

// === Public-Package Functions ===

/// Decode `pyth_source_id`'s source-native price fields out of a verified
/// Lazer `Update`. Aborts if the feed is missing or the price/exponent is
/// unavailable.
public(package) fun extract_source_price(
    update: &LazerUpdate,
    pyth_source_id: u32,
): LazerPriceParts {
    let lazer_published_at_us = update.timestamp();
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

    new_price_parts(
        price_magnitude,
        price_is_negative,
        exponent_magnitude,
        exponent_is_negative,
        lazer_published_at_us,
    )
}

public(package) fun new_price_parts(
    price_magnitude: u64,
    price_is_negative: bool,
    exponent_magnitude: u16,
    exponent_is_negative: bool,
    source_timestamp_us: u64,
): LazerPriceParts {
    LazerPriceParts {
        price_magnitude,
        price_is_negative,
        exponent_magnitude,
        exponent_is_negative,
        source_timestamp_us,
    }
}

/// Ceil-rounding collapses sub-millisecond publisher timestamps onto the same
/// millisecond, and the feed's strict-monotonic check then drops a second update
/// in that window. Accepted bound: one dropped update only matters if a feed ever
/// publishes at a finer-than-1ms cadence.
public(package) fun us_to_ms_ceil(timestamp_us: u64): u64 {
    let ms = timestamp_us / 1000;
    if (timestamp_us % 1000 == 0) ms else ms + 1
}

public(package) fun price_magnitude(parts: &LazerPriceParts): u64 {
    parts.price_magnitude
}

public(package) fun price_is_negative(parts: &LazerPriceParts): bool {
    parts.price_is_negative
}

public(package) fun exponent_magnitude(parts: &LazerPriceParts): u16 {
    parts.exponent_magnitude
}

public(package) fun exponent_is_negative(parts: &LazerPriceParts): bool {
    parts.exponent_is_negative
}

public(package) fun source_timestamp_us(parts: &LazerPriceParts): u64 {
    parts.source_timestamp_us
}

/// Derived 1e9 normalization from source-native fields stored by `PythFeed`.
/// Aborts on negative prices; Propbook stores source facts, and consumers decide
/// whether the derived value is usable.
public(package) fun normalize_pyth_price_parts(parts: &LazerPriceParts): u64 {
    assert!(!parts.price_is_negative, ELazerNegativePrice);

    let target = constants::float_scaling_decimals!();
    let exp_mag = parts.exponent_magnitude as u64;

    if (parts.exponent_is_negative) {
        if (exp_mag <= target) {
            scale_up(parts.price_magnitude, target - exp_mag)
        } else {
            // Round down when the source has finer precision than Propbook's 1e9 scale.
            parts.price_magnitude / math::pow10(exp_mag - target)
        }
    } else {
        scale_up(parts.price_magnitude, target + exp_mag)
    }
}

// === Private Functions ===

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

fun scale_up(magnitude: u64, shift: u64): u64 {
    let factor = math::pow10(shift);
    magnitude * factor
}

// === Test-Only Functions ===

#[test_only]
public fun price_parts_for_testing(
    price_magnitude: u64,
    price_is_negative: bool,
    exponent_magnitude: u16,
    exponent_is_negative: bool,
    source_timestamp_us: u64,
): LazerPriceParts {
    new_price_parts(
        price_magnitude,
        price_is_negative,
        exponent_magnitude,
        exponent_is_negative,
        source_timestamp_us,
    )
}

#[test_only]
public fun assert_lazer_feed_found_for_testing(feed_found: bool) {
    assert_lazer_feed_found(feed_found)
}

#[test_only]
public fun extract_lazer_price_for_testing(price_outer: Option<Option<LazerI64>>): LazerI64 {
    extract_lazer_price(price_outer)
}

#[test_only]
public fun extract_lazer_exponent_for_testing(exp_outer: Option<LazerI16>): LazerI16 {
    extract_lazer_exponent(exp_outer)
}
