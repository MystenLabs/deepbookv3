// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module propbook::lazer_decode_tests;

use propbook::lazer_decode;
use std::{option, unit_test::assert_eq};

// Decode/normalize fixtures (ported from pyth_source_lazer_tests).
const BTC_PYTH_MAGNITUDE: u64 = 6_500_012_345_678;
const BTC_NORMALIZED_SPOT: u64 = 65_000_123_456_780;
const IDENTITY_MAGNITUDE: u64 = 123_456_789;
const DIVIDE_MAGNITUDE: u64 = 12_345_678_901;
const DIVIDE_NORMALIZED_SPOT: u64 = 12_345_678;
const SUB_UNIT_MAGNITUDE: u64 = 5;
const ZERO_MAGNITUDE: u64 = 0;
const ONE_MAGNITUDE: u64 = 1;
const THREE_MAGNITUDE: u64 = 3;
const ONE_1E9_SPOT: u64 = 1_000_000_000;
const THREE_E11_SPOT: u64 = 300_000_000_000;
const EXPONENT_NEG_8: u16 = 8;
const EXPONENT_NEG_9: u16 = 9;
const EXPONENT_NEG_12: u16 = 12;
const EXPONENT_ZERO: u16 = 0;
const EXPONENT_POS_2: u16 = 2;
const EXACT_US: u64 = 2_000;
const EXACT_MS: u64 = 2;
const NON_EXACT_US: u64 = 2_001;
const NON_EXACT_MS_CEIL: u64 = 3;
const SOURCE_TIMESTAMP_ZERO_US: u64 = 0;

#[test]
fun normalize_lazer_price_parts_scales_every_exponent_branch_exactly() {
    // BTC-style: 65_000.12345678 USD as (6_500_012_345_678, -8).
    // Target shift = 9 - 8 = 1:
    //   6_500_012_345_678 * 10 = 65_000_123_456_780.
    let parts = price_parts(
        BTC_PYTH_MAGNITUDE,
        false,
        EXPONENT_NEG_8,
        true,
    );
    let normalized = lazer_decode::normalize_pyth_price_parts(&parts);
    assert_eq!(normalized, BTC_NORMALIZED_SPOT);

    // exponent = -9 exactly: target shift is zero, so magnitude passes through.
    let parts = price_parts(
        IDENTITY_MAGNITUDE,
        false,
        EXPONENT_NEG_9,
        true,
    );
    let normalized = lazer_decode::normalize_pyth_price_parts(&parts);
    assert_eq!(normalized, IDENTITY_MAGNITUDE);

    // exponent = -12: target shift = -3, so integer division floors:
    //   12_345_678_901 / 1_000 = 12_345_678.
    let parts = price_parts(
        DIVIDE_MAGNITUDE,
        false,
        EXPONENT_NEG_12,
        true,
    );
    let normalized = lazer_decode::normalize_pyth_price_parts(&parts);
    assert_eq!(normalized, DIVIDE_NORMALIZED_SPOT);

    // Sub-unit precision is lost by integer division:
    //   5 / 1_000 = 0.
    let parts = price_parts(
        SUB_UNIT_MAGNITUDE,
        false,
        EXPONENT_NEG_12,
        true,
    );
    let normalized = lazer_decode::normalize_pyth_price_parts(&parts);
    assert_eq!(normalized, ZERO_MAGNITUDE);

    // exponent = 0: target shift = 9:
    //   1 * 10^9 = 1_000_000_000.
    let parts = price_parts(
        ONE_MAGNITUDE,
        false,
        EXPONENT_ZERO,
        false,
    );
    let normalized = lazer_decode::normalize_pyth_price_parts(&parts);
    assert_eq!(normalized, ONE_1E9_SPOT);

    // exponent = +2: target shift = 11:
    //   3 * 10^11 = 300_000_000_000.
    let parts = price_parts(
        THREE_MAGNITUDE,
        false,
        EXPONENT_POS_2,
        false,
    );
    let normalized = lazer_decode::normalize_pyth_price_parts(&parts);
    assert_eq!(normalized, THREE_E11_SPOT);

    let parts = price_parts(
        ZERO_MAGNITUDE,
        false,
        EXPONENT_NEG_8,
        true,
    );
    let normalized = lazer_decode::normalize_pyth_price_parts(&parts);
    assert_eq!(normalized, ZERO_MAGNITUDE);
}

#[test]
fun us_to_ms_ceil_rounds_exact_and_non_exact_microseconds() {
    assert_eq!(lazer_decode::us_to_ms_ceil(0), 0);
    assert_eq!(lazer_decode::us_to_ms_ceil(EXACT_US), EXACT_MS);
    assert_eq!(lazer_decode::us_to_ms_ceil(NON_EXACT_US), NON_EXACT_MS_CEIL);
}

#[test, expected_failure(abort_code = lazer_decode::ELazerFeedNotFound)]
fun extract_lazer_spot_missing_feed_aborts() {
    lazer_decode::assert_lazer_feed_found_for_testing(false);
    abort 999
}

#[test, expected_failure(abort_code = lazer_decode::ELazerPriceUnavailable)]
fun extract_lazer_spot_missing_price_field_aborts() {
    lazer_decode::extract_lazer_price_for_testing(option::none());
    abort 999
}

#[test, expected_failure(abort_code = lazer_decode::ELazerPriceUnavailable)]
fun extract_lazer_spot_unavailable_price_value_aborts() {
    lazer_decode::extract_lazer_price_for_testing(option::some(option::none()));
    abort 999
}

#[test, expected_failure(abort_code = lazer_decode::ELazerPriceUnavailable)]
fun extract_lazer_spot_missing_exponent_aborts() {
    lazer_decode::extract_lazer_exponent_for_testing(option::none());
    abort 999
}

#[test, expected_failure(abort_code = lazer_decode::ELazerNegativePrice)]
fun normalize_lazer_price_negative_price_aborts() {
    let parts = price_parts(ONE_MAGNITUDE, true, EXPONENT_ZERO, false);
    lazer_decode::normalize_pyth_price_parts(&parts);
    abort 999
}

fun price_parts(
    price_magnitude: u64,
    price_is_negative: bool,
    exponent_magnitude: u16,
    exponent_is_negative: bool,
): lazer_decode::LazerPriceParts {
    lazer_decode::price_parts_for_testing(
        price_magnitude,
        price_is_negative,
        exponent_magnitude,
        exponent_is_negative,
        SOURCE_TIMESTAMP_ZERO_US,
    )
}
