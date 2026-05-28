// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pyth Lazer decode helpers for the predict oracle.
///
/// Takes a verified Lazer `Update` (trust root: the type can only be
/// constructed inside the `pyth_lazer` package) and returns the spot price
/// for a given feed id in predict's 1e9 scaling, alongside the publisher's
/// microsecond timestamp embedded in the payload.
module deepbook_predict::lazer_helper;

use deepbook_predict::{constants, math as predict_math};
use pyth_lazer::{i16::I16 as LazerI16, i64::I64 as LazerI64, update::Update as LazerUpdate};

const ELazerFeedNotFound: u64 = 0;
const ELazerPriceUnavailable: u64 = 1;
const ELazerNegativePrice: u64 = 2;

// === Public Functions ===

/// Decode `feed_id`'s spot out of a verified Lazer `Update`. Returns
/// `(spot_1e9, lazer_published_at_us)`. Aborts if the feed is missing,
/// the price/exponent is unavailable, or the price is negative.
public fun extract_spot(update: &LazerUpdate, feed_id: u32): (u64, u64) {
    let lazer_published_at_us = update.timestamp();
    let feeds = update.feeds_ref();
    let idx_opt = feeds.find_index!(|f| f.feed_id() == feed_id);
    assert!(idx_opt.is_some(), ELazerFeedNotFound);
    let feed = &feeds[idx_opt.destroy_some()];

    // Both Option layers must be Some: the field must exist in the update,
    // and the value must be present (Lazer returns None if there are not
    // enough publishers).
    let price_outer = feed.price();
    assert!(price_outer.is_some(), ELazerPriceUnavailable);
    let price_inner = price_outer.borrow();
    assert!(price_inner.is_some(), ELazerPriceUnavailable);
    let price = *price_inner.borrow();

    let exp_outer = feed.exponent();
    assert!(exp_outer.is_some(), ELazerPriceUnavailable);
    let exponent = *exp_outer.borrow();

    (normalize_pyth_price(price, exponent), lazer_published_at_us)
}

// === Private Functions ===

/// Convert a Pyth Lazer `(price, exponent)` pair to the predict package's
/// 1e9-scaled u64. Target scaling is `price_1e9 = magnitude * 10^(exponent + 9)`.
/// Aborts on negative price (crypto spot is always positive). Shift bounds
/// are enforced inside `predict_math::pow10` (real feeds use exponents in
/// [-12, -4], so shifts stay well within u64).
fun normalize_pyth_price(price: LazerI64, exponent: LazerI16): u64 {
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
            magnitude / predict_math::pow10(exp_mag - target)
        }
    } else {
        scale_up(magnitude, target + exp_mag)
    }
}

fun scale_up(magnitude: u64, shift: u64): u64 {
    let factor = predict_math::pow10(shift);
    magnitude * factor
}

// === Test-Only Functions ===

/// Expose the private `normalize_pyth_price` so the price/exponent
/// normalization logic can be exercised directly. `extract_spot`'s feed
/// walk requires a `pyth_lazer::Update`, which is `public(package)` in the
/// upstream package and cannot be constructed from a test module here.
#[test_only]
public fun normalize_pyth_price_for_testing(price: LazerI64, exponent: LazerI16): u64 {
    normalize_pyth_price(price, exponent)
}
