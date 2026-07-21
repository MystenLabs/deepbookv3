// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module fixed_math::interval_tests;

use fixed_math::{interval, math::{Self, float_scaling as float}};
use std::unit_test::assert_eq;

// Expected values are hand-derived (comments show the work) — never computed
// through the module under test (unit-tests rule 1). The algebra's soundness
// laws (truth-containment under directed rounding, width addition, abort
// semantics) were validated against an exact-rational reference implementation
// by property fuzzing before this module was written; the cases here pin the
// Move implementation at exact hand-checkable points.

#[test]
fun exact_has_zero_width() {
    let x = interval::exact(5);
    assert_eq!(x.lo(), 5);
    assert_eq!(x.hi(), 5);
    assert_eq!(x.width(), 0);
}

#[test]
fun new_keeps_bounds() {
    let x = interval::new(2, 3);
    assert_eq!(x.lo(), 2);
    assert_eq!(x.hi(), 3);
    assert_eq!(x.width(), 1);
}

#[test, expected_failure(abort_code = interval::EInvalidBounds)]
fun new_inverted_bounds_aborts() {
    interval::new(3, 2);
    abort 999
}

#[test]
fun add_sums_bounds_and_widths() {
    // [2,3] + [10,20] = [12,23]; width 1 + 10 = 11
    let s = interval::new(2, 3).add(&interval::new(10, 20));
    assert_eq!(s.lo(), 12);
    assert_eq!(s.hi(), 23);
    assert_eq!(s.width(), 11);
}

#[test]
fun sub_crosses_bounds_and_widths_add() {
    // [10,20] - [2,3] = [10-3, 20-2] = [7,18]; width 10 + 1 = 11
    let d = interval::new(10, 20).sub(&interval::new(2, 3));
    assert_eq!(d.lo(), 7);
    assert_eq!(d.hi(), 18);
    assert_eq!(d.width(), 11);
}

#[test]
fun sub_of_self_clamps_lo_and_keeps_width() {
    // X - X where X = [2,3]: true difference is 0, but the algebra cannot see
    // correlation: [2-3 -> clamp 0, 3-2] = [0,1] (the dependency-problem witness)
    let x = interval::new(2, 3);
    let d = x.sub(&x);
    assert_eq!(d.lo(), 0);
    assert_eq!(d.hi(), 1);
}

#[test, expected_failure(abort_code = interval::EDefinitelyNegative)]
fun sub_definitely_negative_aborts() {
    // hi(3) < other.lo(10): every point of the difference is negative
    interval::new(2, 3).sub(&interval::new(10, 20));
    abort 999
}

#[test]
fun mul_directs_rounding_outward() {
    // [2,3] * [5,7] raw: lo = floor(2*5/1e9) = 0, hi = ceil(3*7/1e9) = 1
    let p = interval::new(2, 3).mul(&interval::new(5, 7));
    assert_eq!(p.lo(), 0);
    assert_eq!(p.hi(), 1);
}

#[test]
fun mul_exact_operands_stay_tight() {
    // [1e9,2e9] * [3e9,4e9] = [3e9, 8e9] exactly (1.0*3.0=3.0, 2.0*4.0=8.0)
    let p = interval::new(float!(), 2 * float!()).mul(&interval::new(3 * float!(), 4 * float!()));
    assert_eq!(p.lo(), 3 * float!());
    assert_eq!(p.hi(), 8 * float!());
}

#[test]
fun mul_of_one_raw_unit_carries_one_ulp() {
    // exact(1) * exact(1): true product 1e-9 raw; lo floors to 0, hi ceils to 1
    let p = interval::exact(1).mul(&interval::exact(1));
    assert_eq!(p.lo(), 0);
    assert_eq!(p.hi(), 1);
}

#[test]
fun div_crosses_divisor_bounds() {
    // [6e9,8e9] / [2e9,4e9]: lo = floor(6/4 * 1e9) = 1.5e9, hi = ceil(8/2 * 1e9) = 4e9
    let q = interval::new(6 * float!(), 8 * float!()).div(&interval::new(2 * float!(), 4 * float!()));
    assert_eq!(q.lo(), 1_500_000_000);
    assert_eq!(q.hi(), 4 * float!());
}

#[test, expected_failure(abort_code = math::EInputZero)]
fun div_by_possibly_zero_divisor_aborts() {
    // divisor lo == 0: the divisor might be zero, hi side must abort
    interval::new(1, 2).div(&interval::new(0, float!()));
    abort 999
}

#[test]
fun min_is_pointwise() {
    // min([2,10],[5,7]) = [2,7]
    let m = interval::new(2, 10).min(&interval::new(5, 7));
    assert_eq!(m.lo(), 2);
    assert_eq!(m.hi(), 7);
}

#[test]
fun max_is_pointwise() {
    // max([2,10],[5,7]) = [5,10]
    let m = interval::new(2, 10).max(&interval::new(5, 7));
    assert_eq!(m.lo(), 5);
    assert_eq!(m.hi(), 10);
}

#[test]
fun widen_extends_both_sides() {
    // [5,10] widened by 3 = [2,13]
    let w = interval::new(5, 10).widen(3);
    assert_eq!(w.lo(), 2);
    assert_eq!(w.hi(), 13);
}

#[test]
fun widen_clamps_lo_at_zero() {
    // [1,10] widened by 5: lo clamps to 0, hi = 15
    let w = interval::new(1, 10).widen(5);
    assert_eq!(w.lo(), 0);
    assert_eq!(w.hi(), 15);
}
