// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit tests for signed u64 arithmetic.
#[test_only]
module deepbook_predict::i64_tests;

use deepbook_predict::{constants, i64};
use std::unit_test::assert_eq;

const HALF: u64 = 500_000_000;
const QUARTER: u64 = 250_000_000;

fun assert_parts(value: &i64::I64, magnitude: u64, is_negative: bool) {
    assert_eq!(i64::magnitude(value), magnitude);
    assert_eq!(i64::is_negative(value), is_negative);
}

fun signed(magnitude: u64, is_negative: bool): i64::I64 {
    i64::from_parts(magnitude, is_negative)
}

#[test]
fun from_parts_zero_normalizes_sign() {
    let value = i64::from_parts(0, true);
    assert_parts(&value, 0, false);
}

#[test]
fun neg_zero_preserves_positive_zero() {
    let value = i64::neg(&i64::zero());
    assert_parts(&value, 0, false);
}

#[test]
fun sub_pos_minus_smaller_pos() {
    let result = i64::sub(&signed(5, false), &signed(3, false));
    assert_parts(&result, 2, false);
}

#[test]
fun sub_smaller_pos_minus_larger_pos() {
    let result = i64::sub(&signed(3, false), &signed(5, false));
    assert_parts(&result, 2, true);
}

#[test]
fun sub_neg_minus_neg_larger_a() {
    let result = i64::sub(&signed(5, true), &signed(3, true));
    assert_parts(&result, 2, true);
}

#[test]
fun sub_neg_minus_neg_larger_b() {
    let result = i64::sub(&signed(3, true), &signed(5, true));
    assert_parts(&result, 2, false);
}

#[test]
fun sub_pos_minus_neg() {
    let result = i64::sub(&signed(5, false), &signed(3, true));
    assert_parts(&result, 8, false);
}

#[test]
fun sub_neg_minus_pos() {
    let result = i64::sub(&signed(5, true), &signed(3, false));
    assert_parts(&result, 8, true);
}

#[test]
fun sub_equal_values() {
    let result = i64::sub(&signed(5, false), &signed(5, false));
    assert_parts(&result, 0, false);
}

#[test]
fun sub_neg_equal_values_normalizes_to_positive_zero() {
    let result = i64::sub(&signed(5, true), &signed(5, true));
    assert_parts(&result, 0, false);
}

#[test]
fun add_pos_plus_pos() {
    let result = i64::add(&signed(5, false), &signed(3, false));
    assert_parts(&result, 8, false);
}

#[test]
fun add_neg_plus_neg() {
    let result = i64::add(&signed(5, true), &signed(3, true));
    assert_parts(&result, 8, true);
}

#[test]
fun add_pos_plus_neg_larger_pos() {
    let result = i64::add(&signed(5, false), &signed(3, true));
    assert_parts(&result, 2, false);
}

#[test]
fun add_pos_plus_neg_larger_neg() {
    let result = i64::add(&signed(3, false), &signed(5, true));
    assert_parts(&result, 2, true);
}

#[test]
fun add_neg_plus_pos_larger_pos() {
    let result = i64::add(&signed(3, true), &signed(5, false));
    assert_parts(&result, 2, false);
}

#[test]
fun add_neg_plus_pos_larger_neg() {
    let result = i64::add(&signed(5, true), &signed(3, false));
    assert_parts(&result, 2, true);
}

#[test]
fun add_opposite_sign_equal_magnitude() {
    let result = i64::add(&signed(5, false), &signed(5, true));
    assert_parts(&result, 0, false);
}

#[test]
fun add_zero_normalization() {
    let result = i64::add(&signed(0, true), &signed(0, false));
    assert_parts(&result, 0, false);
}

#[test]
fun add_large_same_sign() {
    let result = i64::add(
        &signed(5 * constants::float_scaling!(), false),
        &signed(3 * constants::float_scaling!(), false),
    );
    assert_parts(&result, 8 * constants::float_scaling!(), false);
}

#[test]
fun mul_scaled_pos_times_pos() {
    let result = i64::mul_scaled(
        &signed(2 * constants::float_scaling!(), false),
        &signed(3 * constants::float_scaling!(), false),
    );
    assert_parts(&result, 6 * constants::float_scaling!(), false);
}

#[test]
fun mul_scaled_pos_times_neg() {
    let result = i64::mul_scaled(
        &signed(2 * constants::float_scaling!(), false),
        &signed(3 * constants::float_scaling!(), true),
    );
    assert_parts(&result, 6 * constants::float_scaling!(), true);
}

#[test]
fun mul_scaled_neg_times_neg() {
    let result = i64::mul_scaled(
        &signed(2 * constants::float_scaling!(), true),
        &signed(3 * constants::float_scaling!(), true),
    );
    assert_parts(&result, 6 * constants::float_scaling!(), false);
}

#[test]
fun mul_scaled_anything_times_zero() {
    let result = i64::mul_scaled(
        &signed(5 * constants::float_scaling!(), false),
        &signed(0, false),
    );
    assert_parts(&result, 0, false);
}

#[test]
fun mul_scaled_fractional() {
    let result = i64::mul_scaled(
        &signed(HALF, false),
        &signed(HALF, false),
    );
    assert_parts(&result, QUARTER, false);
}

#[test]
fun mul_scaled_one_times_value() {
    let result = i64::mul_scaled(
        &signed(constants::float_scaling!(), false),
        &signed(42 * constants::float_scaling!(), true),
    );
    assert_parts(&result, 42 * constants::float_scaling!(), true);
}

#[test, expected_failure(abort_code = i64::EOverflow)]
fun add_overflow_aborts() {
    i64::add(&signed(18_446_744_073_709_551_615, false), &signed(1, false));
    abort 999
}

#[test]
fun square_scaled_negates_sign_information() {
    assert_eq!(
        i64::square_scaled(&signed(2 * constants::float_scaling!(), true)),
        4 * constants::float_scaling!(),
    );
}

#[test]
fun div_scaled_preserves_sign() {
    let result = i64::div_scaled(
        &signed(6 * constants::float_scaling!(), true),
        &signed(2 * constants::float_scaling!(), false),
    );
    assert_parts(&result, 3 * constants::float_scaling!(), true);
}

#[test, expected_failure(abort_code = i64::EZeroDivisor)]
fun div_scaled_zero_divisor_aborts() {
    i64::div_scaled(&signed(constants::float_scaling!(), false), &signed(0, false));
    abort 999
}
