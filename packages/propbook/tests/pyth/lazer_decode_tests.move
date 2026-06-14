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

#[test]
fun normalize_lazer_price_parts_scales_every_exponent_branch_exactly() {
    // BTC-style: 65_000.12345678 USD as (6_500_012_345_678, -8).
    // Target shift = 9 - 8 = 1:
    //   6_500_012_345_678 * 10 = 65_000_123_456_780.
    let normalized = lazer_decode::normalize_pyth_price_parts(
        BTC_PYTH_MAGNITUDE,
        false,
        EXPONENT_NEG_8,
        true,
    );
    assert_eq!(normalized, BTC_NORMALIZED_SPOT);

    // exponent = -9 exactly: target shift is zero, so magnitude passes through.
    let normalized = lazer_decode::normalize_pyth_price_parts(
        IDENTITY_MAGNITUDE,
        false,
        EXPONENT_NEG_9,
        true,
    );
    assert_eq!(normalized, IDENTITY_MAGNITUDE);

    // exponent = -12: target shift = -3, so integer division floors:
    //   12_345_678_901 / 1_000 = 12_345_678.
    let normalized = lazer_decode::normalize_pyth_price_parts(
        DIVIDE_MAGNITUDE,
        false,
        EXPONENT_NEG_12,
        true,
    );
    assert_eq!(normalized, DIVIDE_NORMALIZED_SPOT);

    // Sub-unit precision is lost by integer division:
    //   5 / 1_000 = 0.
    let normalized = lazer_decode::normalize_pyth_price_parts(
        SUB_UNIT_MAGNITUDE,
        false,
        EXPONENT_NEG_12,
        true,
    );
    assert_eq!(normalized, ZERO_MAGNITUDE);

    // exponent = 0: target shift = 9:
    //   1 * 10^9 = 1_000_000_000.
    let normalized = lazer_decode::normalize_pyth_price_parts(
        ONE_MAGNITUDE,
        false,
        EXPONENT_ZERO,
        false,
    );
    assert_eq!(normalized, ONE_1E9_SPOT);

    // exponent = +2: target shift = 11:
    //   3 * 10^11 = 300_000_000_000.
    let normalized = lazer_decode::normalize_pyth_price_parts(
        THREE_MAGNITUDE,
        false,
        EXPONENT_POS_2,
        false,
    );
    assert_eq!(normalized, THREE_E11_SPOT);

    let normalized = lazer_decode::normalize_pyth_price_parts(
        ZERO_MAGNITUDE,
        false,
        EXPONENT_NEG_8,
        true,
    );
    assert_eq!(normalized, ZERO_MAGNITUDE);
}

#[test, expected_failure(abort_code = lazer_decode::ELazerFeedNotFound)]
fun extract_lazer_spot_missing_feed_aborts() {
    lazer_decode::assert_lazer_feed_found(false);
    abort 999
}

#[test, expected_failure(abort_code = lazer_decode::ELazerPriceUnavailable)]
fun extract_lazer_spot_missing_price_field_aborts() {
    lazer_decode::extract_lazer_price(option::none());
    abort 999
}

#[test, expected_failure(abort_code = lazer_decode::ELazerPriceUnavailable)]
fun extract_lazer_spot_unavailable_price_value_aborts() {
    lazer_decode::extract_lazer_price(option::some(option::none()));
    abort 999
}

#[test, expected_failure(abort_code = lazer_decode::ELazerPriceUnavailable)]
fun extract_lazer_spot_missing_exponent_aborts() {
    lazer_decode::extract_lazer_exponent(option::none());
    abort 999
}

#[test, expected_failure(abort_code = lazer_decode::ELazerNegativePrice)]
fun normalize_lazer_price_negative_price_aborts() {
    lazer_decode::normalize_pyth_price_parts(ONE_MAGNITUDE, true, EXPONENT_ZERO, false);
    abort 999
}
