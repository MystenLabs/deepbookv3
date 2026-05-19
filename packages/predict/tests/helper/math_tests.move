// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::math_tests;

use deepbook_predict::{constants, i64, math};

#[test]
fun test_ln() {
    // ln(1) = 0
    let res = math::ln(constants::float_scaling!());
    assert!(res.magnitude() == 0, 0);

    // ln(e) ≈ 1
    // e ≈ 2.718281828
    let res = math::ln(2_718_281_828);
    assert!(res.magnitude() >= 999_999_999 && res.magnitude() <= 1_000_000_001, 1);

    // ln(2) ≈ 0.693147180
    let res = math::ln(2_000_000_000);
    assert!(res.magnitude() >= 693_147_179 && res.magnitude() <= 693_147_181, 2);

    // ln(0.5) ≈ -0.693147180
    let res = math::ln(500_000_000);
    assert!(res.is_negative(), 3);
    assert!(res.magnitude() >= 693_147_179 && res.magnitude() <= 693_147_181, 4);
}

#[test]
fun test_exp() {
    // exp(0) = 1
    let res = math::exp(&i64::zero());
    assert!(res == constants::float_scaling!(), 0);

    // exp(1) ≈ 2.718281828
    let res = math::exp(&i64::from_u64(constants::float_scaling!()));
    assert!(res >= 2_718_281_827 && res <= 2_718_281_829, 1);

    // exp(ln(2)) = 2
    let ln2 = math::ln(2_000_000_000);
    let res = math::exp(&ln2);
    assert!(res >= 1_999_999_999 && res <= 2_000_000_001, 2);

    // exp(-ln(2)) = 0.5
    let ln2 = math::ln(2_000_000_000);
    let res = math::exp(&ln2.neg());
    assert!(res >= 499_999_999 && res <= 500_000_001, 3);
}

#[test]
fun test_sqrt() {
    // sqrt(4) = 2
    let res = math::sqrt(4 * constants::float_scaling!(), 1);
    assert!(res == 2 * constants::float_scaling!(), 0);

    // sqrt(2) ≈ 1.414213562
    let res = math::sqrt(2 * constants::float_scaling!(), 1);
    assert!(res >= 1_414_213_561 && res <= 1_414_213_563, 1);
}

#[test]
fun test_normal_cdf() {
    // Φ(0) = 0.5
    let res = math::normal_cdf(&i64::zero());
    assert!(res == 500_000_000, 0);

    // Φ(1.96) ≈ 0.841344746 (Wait, Φ(1) ≈ 0.841)
    // Φ(1) ≈ 0.841344746
    let res = math::normal_cdf(&i64::from_u64(constants::float_scaling!()));
    assert!(res >= 841_344_740 && res <= 841_344_752, 1);

    // Φ(-1) = 1 - Φ(1) ≈ 0.158655254
    let res = math::normal_cdf(&i64::from_u64(constants::float_scaling!()).neg());
    assert!(res >= 158_655_248 && res <= 158_655_260, 2);
}
