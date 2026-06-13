// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pure Pyth Lazer payload decoding for `pyth_feed`: pull a feed's spot out of a
/// verified `Update` and normalize the `(price, exponent)` pair to 1e9 scaling.
/// Side-effect-free — no object state, just decode and fixed-point math — so the
/// feed module can keep validation and storage as its single chokepoint.
module propbook::lazer_decode;

use predict_math::math;
use propbook::constants;
use pyth_lazer::{i16::I16 as LazerI16, i64::I64 as LazerI64, update::Update as LazerUpdate};
use std::option::Option;

const ELazerFeedNotFound: u64 = 0;
const ELazerPriceUnavailable: u64 = 1;
const ELazerNegativePrice: u64 = 2;

// === Public-Package Functions ===

/// Decode `feed_id`'s spot out of a verified Lazer `Update`. Returns
/// `(spot_1e9, lazer_published_at_us)`. Aborts if the feed is missing, the
/// price/exponent is unavailable, or the price is negative.
public(package) fun extract_spot(update: &LazerUpdate, feed_id: u32): (u64, u64) {
    let lazer_published_at_us = update.timestamp();
    let feeds = update.feeds_ref();
    let idx_opt = feeds.find_index!(|f| f.feed_id() == feed_id);
    assert_lazer_feed_found(idx_opt.is_some());
    let feed = &feeds[idx_opt.destroy_some()];

    let price = extract_lazer_price(feed.price());
    let exponent = extract_lazer_exponent(feed.exponent());

    (normalize_pyth_price(price, exponent), lazer_published_at_us)
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

/// Convert a Pyth Lazer `(price, exponent)` pair to a 1e9-scaled u64:
/// `price_1e9 = magnitude * 10^(exponent + 9)`. Aborts on a negative price
/// (crypto spot is always positive). Shift bounds are enforced inside
/// `math::pow10` (real feeds use exponents in [-12, -4]).
public(package) fun normalize_pyth_price(price: LazerI64, exponent: LazerI16): u64 {
    assert!(!price.get_is_negative(), ELazerNegativePrice);
    let magnitude = price.get_magnitude_if_positive();

    let exp_is_neg = exponent.get_is_negative();
    let exp_mag = if (exp_is_neg) {
        exponent.get_magnitude_if_negative() as u64
    } else {
        exponent.get_magnitude_if_positive() as u64
    };

    let target = constants::float_scaling_decimals!();

    if (exp_is_neg) {
        if (exp_mag <= target) {
            scale_up(magnitude, target - exp_mag)
        } else {
            magnitude / math::pow10(exp_mag - target)
        }
    } else {
        scale_up(magnitude, target + exp_mag)
    }
}

// === Private Functions ===

fun scale_up(magnitude: u64, shift: u64): u64 {
    let factor = math::pow10(shift);
    magnitude * factor
}
