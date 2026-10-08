// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// `lazer_price`: the 1e9 spot normalization (Predict v4's
/// `normalize_lazer_spot`, hand-derived cases) and the per-feed decode behind
/// `from_update`. A real Lazer `Update` has no Move test constructor, so the
/// decode is driven through `from_parts` with Lazer's own `Option` layers.
#[test_only]
module deepbook_predict_math::lazer_price_tests;

use deepbook_predict_math::lazer_price;
use pyth_lazer::{i16, i64};
use std::unit_test::assert_eq;

// === normalize_spot (hand-derived) ===

/// Lazer's usual exponent: $70,000.12345678 at 1e-8 becomes 70_000_123_456_780 at 1e-9.
const EXPONENT_NEG_8: u16 = 8;
const PRICE_AT_NEG_8: u64 = 7_000_012_345_678;
const SPOT_FROM_NEG_8: u64 = 70_000_123_456_780;
const EXPONENT_NEG_9: u16 = 9;
/// 1e-12 is finer than 1e-9: $7,000.123456789012 drops three digits, rounding down
/// (`...789.012` -> `...789`).
const EXPONENT_NEG_12: u16 = 12;
const PRICE_AT_NEG_12: u64 = 7_000_123_456_789_012;
const SPOT_FROM_NEG_12: u64 = 7_000_123_456_789;
/// At 1e-12, 999 rounds to zero (none) and 1_000 to one raw unit.
const ROUNDS_TO_ZERO_AT_NEG_12: u64 = 999;
const ROUNDS_TO_ONE_AT_NEG_12: u64 = 1_000;
/// 7 at 1e+2 is 700 = 700_000_000_000 at 1e-9; 5 at 1e0 is 5_000_000_000.
const EXPONENT_POS_2: u16 = 2;
const PRICE_AT_POS_2: u64 = 7;
const SPOT_FROM_POS_2: u64 = 700_000_000_000;
const EXPONENT_ZERO: u16 = 0;
const PRICE_AT_ZERO_EXPONENT: u64 = 5;
const SPOT_FROM_ZERO_EXPONENT: u64 = 5_000_000_000;
const ZERO_PRICE: u64 = 0;
const ONE_RAW_UNIT: u64 = 1;
/// 1e-27 needs an 18-digit drop (`u64::MAX / 1e18 = 18`); 1e-28 needs 19, past the
/// supported shift, even though the quotient would be 1.
const EXPONENT_NEG_27: u16 = 27;
const EXPONENT_NEG_28: u16 = 28;
const U64_MAX_AT_NEG_27: u64 = 18;
/// 1 at 1e+8 is 1e17, under the 1.84e17 ceiling; 2 at 1e+8 is over it.
const EXPONENT_POS_8: u16 = 8;
const PRICE_UNDER_CEILING_AT_POS_8: u64 = 1;
const PRICE_OVER_CEILING_AT_POS_8: u64 = 2;
const SPOT_FROM_POS_8: u64 = 100_000_000_000_000_000;
/// u64::MAX / 100, Predict's pricing-safe spot ceiling.
const MAX_PRICING_SPOT: u64 = 184_467_440_737_095_516;

// === normalize_spot ===

#[test]
fun normalize_spot_scales_every_exponent_to_1e9() {
    assert_eq!(
        lazer_price::normalize_spot(PRICE_AT_NEG_8, false, EXPONENT_NEG_8, true),
        option::some(SPOT_FROM_NEG_8),
    );
    assert_eq!(
        lazer_price::normalize_spot(SPOT_FROM_NEG_8, false, EXPONENT_NEG_9, true),
        option::some(SPOT_FROM_NEG_8),
    );
    assert_eq!(
        lazer_price::normalize_spot(PRICE_AT_NEG_12, false, EXPONENT_NEG_12, true),
        option::some(SPOT_FROM_NEG_12),
    );
    assert_eq!(
        lazer_price::normalize_spot(PRICE_AT_POS_2, false, EXPONENT_POS_2, false),
        option::some(SPOT_FROM_POS_2),
    );
    // Lazer may sign a zero exponent either way.
    assert_eq!(
        lazer_price::normalize_spot(PRICE_AT_ZERO_EXPONENT, false, EXPONENT_ZERO, false),
        option::some(SPOT_FROM_ZERO_EXPONENT),
    );
    assert_eq!(
        lazer_price::normalize_spot(PRICE_AT_ZERO_EXPONENT, false, EXPONENT_ZERO, true),
        option::some(SPOT_FROM_ZERO_EXPONENT),
    );
}

#[test]
fun normalize_spot_rounds_finer_prices_down_and_rejects_zero() {
    assert_eq!(
        lazer_price::normalize_spot(ROUNDS_TO_ONE_AT_NEG_12, false, EXPONENT_NEG_12, true),
        option::some(ONE_RAW_UNIT),
    );
    assert!(
        lazer_price::normalize_spot(
            ROUNDS_TO_ZERO_AT_NEG_12,
            false,
            EXPONENT_NEG_12,
            true,
        ).is_none(),
    );
    assert!(lazer_price::normalize_spot(ZERO_PRICE, false, EXPONENT_NEG_8, true).is_none());
}

#[test]
fun normalize_spot_rejects_a_negative_price() {
    assert!(lazer_price::normalize_spot(PRICE_AT_NEG_8, true, EXPONENT_NEG_8, true).is_none());
}

/// Decimal shifts are supported up to 18 digits each way.
#[test]
fun normalize_spot_rejects_a_shift_past_18_digits() {
    let max = std::u64::max_value!();
    assert_eq!(
        lazer_price::normalize_spot(max, false, EXPONENT_NEG_27, true),
        option::some(U64_MAX_AT_NEG_27),
    );
    assert!(lazer_price::normalize_spot(max, false, EXPONENT_NEG_28, true).is_none());
}

/// The pricing-safe ceiling is inclusive, and it also bounds overflow: `u64::MAX` at
/// 1e-8 would scale past `u64`.
#[test]
fun normalize_spot_caps_at_the_pricing_safe_ceiling() {
    assert_eq!(
        lazer_price::normalize_spot(MAX_PRICING_SPOT, false, EXPONENT_NEG_9, true),
        option::some(MAX_PRICING_SPOT),
    );
    assert!(
        lazer_price::normalize_spot(MAX_PRICING_SPOT + 1, false, EXPONENT_NEG_9, true).is_none(),
    );
    assert_eq!(
        lazer_price::normalize_spot(PRICE_UNDER_CEILING_AT_POS_8, false, EXPONENT_POS_8, false),
        option::some(SPOT_FROM_POS_8),
    );
    assert!(
        lazer_price::normalize_spot(
            PRICE_OVER_CEILING_AT_POS_8,
            false,
            EXPONENT_POS_8,
            false,
        ).is_none(),
    );
    assert!(
        lazer_price::normalize_spot(
            std::u64::max_value!(),
            false,
            EXPONENT_NEG_8,
            true,
        ).is_none(),
    );
}

// === from_parts ===

const FEED_ID: u32 = 1;
const CHANNEL_200MS: u8 = 3;
const ENVELOPE_US: u64 = 121_000_000;
const GENERATION_US: u64 = 120_950_000;

#[test]
fun from_parts_decodes_a_usable_feed() {
    let price = lazer_price::from_parts(
        FEED_ID,
        CHANNEL_200MS,
        ENVELOPE_US,
        option::some(option::some(i64::new(PRICE_AT_NEG_8, false))),
        option::some(i16::new(EXPONENT_NEG_8, true)),
        option::some(option::some(GENERATION_US)),
    ).destroy_some();
    assert_eq!(price.feed_id(), FEED_ID);
    assert_eq!(price.channel(), CHANNEL_200MS);
    assert_eq!(price.envelope_us(), ENVELOPE_US);
    assert_eq!(price.generation_us(), GENERATION_US);
    assert_eq!(price.spot(), SPOT_FROM_NEG_8);
}

/// A requested but empty price or update time is a gap, not a caller error.
#[test]
fun from_parts_is_none_for_an_empty_price_or_update_time() {
    assert!(
        lazer_price::from_parts(
            FEED_ID,
            CHANNEL_200MS,
            ENVELOPE_US,
            option::some(option::none()),
            option::some(i16::new(EXPONENT_NEG_8, true)),
            option::some(option::some(GENERATION_US)),
        ).is_none(),
    );
    assert!(
        lazer_price::from_parts(
            FEED_ID,
            CHANNEL_200MS,
            ENVELOPE_US,
            option::some(option::some(i64::new(PRICE_AT_NEG_8, false))),
            option::some(i16::new(EXPONENT_NEG_8, true)),
            option::some(option::none()),
        ).is_none(),
    );
}

#[test]
fun from_parts_is_none_for_a_price_that_does_not_normalize() {
    assert!(
        lazer_price::from_parts(
            FEED_ID,
            CHANNEL_200MS,
            ENVELOPE_US,
            option::some(option::some(i64::new(PRICE_AT_NEG_8, true))),
            option::some(i16::new(EXPONENT_NEG_8, true)),
            option::some(option::some(GENERATION_US)),
        ).is_none(),
    );
}

/// An unrequested property means the caller asked for the wrong update.
#[test, expected_failure(abort_code = lazer_price::EPropertyNotRequested)]
fun from_parts_aborts_on_an_unrequested_property() {
    lazer_price::from_parts(
        FEED_ID,
        CHANNEL_200MS,
        ENVELOPE_US,
        option::some(option::some(i64::new(PRICE_AT_NEG_8, false))),
        option::none(),
        option::some(option::some(GENERATION_US)),
    );
}

#[test, expected_failure(abort_code = lazer_price::EGenerationAfterEnvelope)]
fun from_parts_aborts_on_a_generation_after_the_envelope() {
    lazer_price::from_parts(
        FEED_ID,
        CHANNEL_200MS,
        ENVELOPE_US,
        option::some(option::some(i64::new(PRICE_AT_NEG_8, false))),
        option::some(i16::new(EXPONENT_NEG_8, true)),
        option::some(option::some(ENVELOPE_US + 1)),
    );
}
