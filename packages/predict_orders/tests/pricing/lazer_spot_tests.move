// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Lazer spot normalization, moved out of Predict's `tick_pricing_tests` with
/// `normalize_lazer_spot` for the order-flow companion port. Not yet ported: it
/// still calls `pricing::normalize_lazer_spot`, which the companion re-homes.
#[test_only]
module deepbook_predict_orders::lazer_spot_tests;

use std::unit_test::assert_eq;

// === normalize_lazer_spot (hand-derived) ===

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

// === normalize_lazer_spot ===

#[test]
fun normalize_lazer_spot_scales_every_exponent_to_1e9() {
    assert_eq!(
        pricing::normalize_lazer_spot(PRICE_AT_NEG_8, false, EXPONENT_NEG_8, true),
        option::some(SPOT_FROM_NEG_8),
    );
    assert_eq!(
        pricing::normalize_lazer_spot(SPOT_FROM_NEG_8, false, EXPONENT_NEG_9, true),
        option::some(SPOT_FROM_NEG_8),
    );
    assert_eq!(
        pricing::normalize_lazer_spot(PRICE_AT_NEG_12, false, EXPONENT_NEG_12, true),
        option::some(SPOT_FROM_NEG_12),
    );
    assert_eq!(
        pricing::normalize_lazer_spot(PRICE_AT_POS_2, false, EXPONENT_POS_2, false),
        option::some(SPOT_FROM_POS_2),
    );
    // Lazer may sign a zero exponent either way.
    assert_eq!(
        pricing::normalize_lazer_spot(PRICE_AT_ZERO_EXPONENT, false, EXPONENT_ZERO, false),
        option::some(SPOT_FROM_ZERO_EXPONENT),
    );
    assert_eq!(
        pricing::normalize_lazer_spot(PRICE_AT_ZERO_EXPONENT, false, EXPONENT_ZERO, true),
        option::some(SPOT_FROM_ZERO_EXPONENT),
    );
}

#[test]
fun normalize_lazer_spot_rounds_finer_prices_down_and_rejects_zero() {
    assert_eq!(
        pricing::normalize_lazer_spot(ROUNDS_TO_ONE_AT_NEG_12, false, EXPONENT_NEG_12, true),
        option::some(ONE_RAW_UNIT),
    );
    assert!(
        pricing::normalize_lazer_spot(
            ROUNDS_TO_ZERO_AT_NEG_12,
            false,
            EXPONENT_NEG_12,
            true,
        ).is_none(),
    );
    assert!(pricing::normalize_lazer_spot(ZERO_PRICE, false, EXPONENT_NEG_8, true).is_none());
}

#[test]
fun normalize_lazer_spot_rejects_a_negative_price() {
    assert!(pricing::normalize_lazer_spot(PRICE_AT_NEG_8, true, EXPONENT_NEG_8, true).is_none());
}

/// Decimal shifts are supported up to 18 digits each way.
#[test]
fun normalize_lazer_spot_rejects_a_shift_past_18_digits() {
    let max = std::u64::max_value!();
    assert_eq!(
        pricing::normalize_lazer_spot(max, false, EXPONENT_NEG_27, true),
        option::some(U64_MAX_AT_NEG_27),
    );
    assert!(pricing::normalize_lazer_spot(max, false, EXPONENT_NEG_28, true).is_none());
}

/// The pricing-safe ceiling is inclusive, and it also bounds overflow: `u64::MAX` at
/// 1e-8 would scale past `u64`.
#[test]
fun normalize_lazer_spot_caps_at_the_pricing_safe_ceiling() {
    assert_eq!(
        pricing::normalize_lazer_spot(MAX_PRICING_SPOT, false, EXPONENT_NEG_9, true),
        option::some(MAX_PRICING_SPOT),
    );
    assert!(
        pricing::normalize_lazer_spot(MAX_PRICING_SPOT + 1, false, EXPONENT_NEG_9, true).is_none(),
    );
    assert_eq!(
        pricing::normalize_lazer_spot(PRICE_UNDER_CEILING_AT_POS_8, false, EXPONENT_POS_8, false),
        option::some(SPOT_FROM_POS_8),
    );
    assert!(
        pricing::normalize_lazer_spot(
            PRICE_OVER_CEILING_AT_POS_8,
            false,
            EXPONENT_POS_8,
            false,
        ).is_none(),
    );
    assert!(
        pricing::normalize_lazer_spot(
            std::u64::max_value!(),
            false,
            EXPONENT_NEG_8,
            true,
        ).is_none(),
    );
}
