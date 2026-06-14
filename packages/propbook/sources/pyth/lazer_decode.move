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

// === Public-Package Functions ===

/// Decode `pyth_source_id`'s source-native price fields out of a verified
/// Lazer `Update`. Returns `(price_magnitude, price_is_negative,
/// exponent_magnitude, exponent_is_negative, lazer_published_at_us)`. Aborts if
/// the feed is missing or the price/exponent is unavailable.
public(package) fun extract_source_price(
    update: &LazerUpdate,
    pyth_source_id: u32,
): (u64, bool, u16, bool, u64) {
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

    (
        price_magnitude,
        price_is_negative,
        exponent_magnitude,
        exponent_is_negative,
        lazer_published_at_us,
    )
}

/// Ceil-rounding collapses sub-millisecond publisher timestamps onto the same
/// millisecond, and the feed's strict-monotonic check then drops a second update
/// in that window. Accepted bound: one dropped update only matters if a feed ever
/// publishes at a finer-than-1ms cadence.
public(package) fun us_to_ms_ceil(timestamp_us: u64): u64 {
    let ms = timestamp_us / 1000;
    if (timestamp_us % 1000 == 0) ms else ms + 1
}

public(package) fun assert_lazer_feed_found(feed_found: bool) {
    assert!(feed_found, ELazerFeedNotFound);
}

public(package) fun extract_lazer_price(price_outer: Option<Option<LazerI64>>): LazerI64 {
    // Both Option layers must be Some: the field must exist in the update, and
    // the value must be present (Lazer returns None without enough publishers).
    assert!(price_outer.is_some(), ELazerPriceUnavailable);
    let price_inner = price_outer.borrow();
    assert!(price_inner.is_some(), ELazerPriceUnavailable);
    *price_inner.borrow()
}

public(package) fun extract_lazer_exponent(exp_outer: Option<LazerI16>): LazerI16 {
    assert!(exp_outer.is_some(), ELazerPriceUnavailable);
    *exp_outer.borrow()
}

/// Derived 1e9 normalization from source-native fields stored by `PythFeed`.
/// Aborts on negative prices; Propbook stores source facts, and consumers decide
/// whether the derived value is usable.
public(package) fun normalize_pyth_price_parts(
    price_magnitude: u64,
    price_is_negative: bool,
    exponent_magnitude: u16,
    exponent_is_negative: bool,
): u64 {
    assert!(!price_is_negative, ELazerNegativePrice);

    let target = constants::float_scaling_decimals!();
    let exp_mag = exponent_magnitude as u64;

    if (exponent_is_negative) {
        if (exp_mag <= target) {
            scale_up(price_magnitude, target - exp_mag)
        } else {
            price_magnitude / math::pow10(exp_mag - target)
        }
    } else {
        scale_up(price_magnitude, target + exp_mag)
    }
}

// === Private Functions ===

fun scale_up(magnitude: u64, shift: u64): u64 {
    let factor = math::pow10(shift);
    magnitude * factor
}
