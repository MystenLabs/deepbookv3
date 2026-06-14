// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Shared assertion helpers for Predict math tests.
#[test_only]
module fixed_math::test_helpers;

/// Assert `actual` is within `max_abs_diff` of an independently-derived
/// `reference`.
public fun assert_within(actual: u64, reference: u64, max_abs_diff: u64) {
    let diff = if (actual > reference) actual - reference else reference - actual;
    assert!(diff <= max_abs_diff);
}

/// Assert `actual` is within a relative budget of an independently-derived
/// `reference`. `rel_budget` is in parts per 1e9, e.g. 100 = 1e-7.
public fun assert_within_relative(actual: u64, reference: u64, rel_budget: u64) {
    let rel_tol = (reference as u128) * (rel_budget as u128) / 1_000_000_000;
    let tol = if (rel_tol < 1) 1
    else (rel_tol as u64);
    let diff = if (actual > reference) actual - reference else reference - actual;
    assert!(diff <= tol);
}
