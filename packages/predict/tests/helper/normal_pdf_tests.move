// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::normal_pdf_tests;

use deepbook_predict::{i64, math};
use std::unit_test::assert_eq;

const FS: u64 = 1_000_000_000;

fun assert_close(actual: u64, expected: u64, tol: u64) {
    let diff = if (actual >= expected) actual - expected else expected - actual;
    assert!(diff <= tol);
}

#[test]
fun pdf_at_zero_equals_inv_sqrt_2pi() {
    // n(0) = 1/√(2π) ≈ 0.398942280.
    let zero = i64::zero();
    assert_eq!(math::normal_pdf(&zero), 398_942_280);
}

#[test]
fun pdf_is_symmetric_around_zero() {
    let one = i64::from_u64(FS);
    let neg_one = one.neg();
    assert_eq!(math::normal_pdf(&one), math::normal_pdf(&neg_one));

    let two = i64::from_u64(2 * FS);
    let neg_two = two.neg();
    assert_eq!(math::normal_pdf(&two), math::normal_pdf(&neg_two));
}

#[test]
fun pdf_matches_textbook_at_one() {
    // n(1) = exp(-0.5)/√(2π) ≈ 0.241970725 → 241_970_725.
    let one = i64::from_u64(FS);
    assert_close(math::normal_pdf(&one), 241_970_725, 200);
}

#[test]
fun pdf_matches_textbook_at_two() {
    // n(2) ≈ 0.053990967 → 53_990_967.
    let two = i64::from_u64(2 * FS);
    assert_close(math::normal_pdf(&two), 53_990_967, 200);
}

#[test]
fun pdf_decays_to_zero_far_from_origin() {
    // Beyond 8σ the PDF returns 0 to skip the exp call.
    let nine = i64::from_u64(9 * FS);
    assert_eq!(math::normal_pdf(&nine), 0);
    assert_eq!(math::normal_pdf(&nine.neg()), 0);
}

#[test]
fun pdf_is_strictly_decreasing_in_magnitude() {
    let half = i64::from_u64(FS / 2);
    let one = i64::from_u64(FS);
    let two = i64::from_u64(2 * FS);
    let four = i64::from_u64(4 * FS);

    let p_zero = math::normal_pdf(&i64::zero());
    let p_half = math::normal_pdf(&half);
    let p_one = math::normal_pdf(&one);
    let p_two = math::normal_pdf(&two);
    let p_four = math::normal_pdf(&four);

    assert!(p_zero > p_half);
    assert!(p_half > p_one);
    assert!(p_one > p_two);
    assert!(p_two > p_four);
}
