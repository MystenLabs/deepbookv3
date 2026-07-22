// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module fixed_math::wide_math_tests;

use fixed_math::math;
use std::unit_test::assert_eq;

/// Verify the defining floor-square-root inequalities without relying on a
/// second square-root implementation or on products that can overflow u128.
fun assert_isqrt_floor(x: u128) {
    let root = math::sqrt_u128(x);
    if (x == 0) {
        assert_eq!(root, 0);
    } else {
        assert!(root > 0);
        assert!(root <= x / root);
        let successor = root + 1;
        assert!(successor > x / successor);
    }
}

#[test]
fun sqrt_u128_satisfies_floor_contract_at_every_bit_boundary() {
    let mut bit: u8 = 0;
    while (bit < 128) {
        let boundary = 1u128 << bit;
        assert_isqrt_floor(boundary - 1);
        assert_isqrt_floor(boundary);
        if (boundary < std::u128::max_value!()) {
            assert_isqrt_floor(boundary + 1);
        };
        bit = bit + 1;
    };
}

#[test]
fun sqrt_u128_satisfies_floor_contract_around_large_perfect_squares() {
    let mut bit: u8 = 0;
    while (bit < 64) {
        let root = 1u128 << bit;
        let square = root * root;
        if (square > 0) {
            assert_isqrt_floor(square - 1);
        };
        assert_isqrt_floor(square);
        if (square < std::u128::max_value!()) {
            assert_isqrt_floor(square + 1);
        };
        bit = bit + 1;
    };

    let largest_u64 = std::u64::max_value!() as u128;
    let square = largest_u64 * largest_u64;
    assert_isqrt_floor(square - 1);
    assert_isqrt_floor(square);
    assert_isqrt_floor(square + 1);
}

#[test]
fun sqrt_u128_satisfies_floor_contract_at_wide_extremes() {
    assert_isqrt_floor(123_456_789_012_345_678_901_234_567_890);
    assert_isqrt_floor(1u128 << 127);
    assert_isqrt_floor(std::u128::max_value!() - 1);
    assert_isqrt_floor(std::u128::max_value!());
}
