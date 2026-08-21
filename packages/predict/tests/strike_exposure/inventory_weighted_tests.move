// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit coverage for the probability-weighted inventory statistic. Expected values
/// are derived by hand from the definition, never from the contract.
#[test_only]
module deepbook_predict::inventory_weighted_tests;

use deepbook_predict::inventory_weighted as weighted;
use std::unit_test::assert_eq;

/// Certainty at the fixed-point scale, and half of it.
const ALL_MASS: u64 = 1_000_000_000;
const HALF_MASS: u64 = 500_000_000;
/// One whole contract of payout.
const ONE: u64 = 1_000_000_000;
/// A payout of `q` over half the probability and nothing over the other half has
/// mean `q/2` and second moment `q^2/2`, so the variance is `q^2/4` and the
/// deviation is exactly half the payout.
const HALF_COVERED_DEVIATION: u64 = 500_000_000;

#[test]
fun an_empty_book_scores_zero() {
    assert_eq!(weighted::zero_terms().deviation(), 0);
}

/// The property the design rests on: a payout added at every settlement price
/// moves the mean and the second moment together and leaves the spread alone, so
/// buying every outcome is free. Exact in integers, with no clamp involved.
#[test]
fun adding_the_same_payout_everywhere_leaves_the_statistic_at_zero() {
    let flat = weighted::zero_terms().fold(0, ALL_MASS, ONE, true);
    assert_eq!(flat.deviation(), 0);
    assert_eq!(flat.first(), (ONE as u128));

    // And again on top of an uneven book: the spread is unchanged by a second
    // payout laid across the whole ladder.
    let uneven = weighted::zero_terms().fold(0, HALF_MASS, ONE, true);
    let before = uneven.deviation();
    let lifted = uneven.fold(uneven.first(), ALL_MASS, ONE, true);
    assert_eq!(lifted.deviation(), before);
}

#[test]
fun a_book_covering_half_the_probability_scores_half_its_payout() {
    let terms = weighted::zero_terms().fold(0, HALF_MASS, ONE, true);

    assert_eq!(terms.first(), (HALF_MASS as u128));
    assert_eq!(terms.deviation(), HALF_COVERED_DEVIATION);
}

/// The fold is a sum with no division, so opening and closing return the totals
/// bit for bit. This is the property the entropic form could not hold.
#[test]
fun a_range_opened_and_closed_returns_the_totals_exactly() {
    let start = weighted::zero_terms();
    let opened = start.fold(0, HALF_MASS, ONE, true);
    // The range's own first moment after the open is what the close reads.
    let closed = opened.fold(opened.first(), HALF_MASS, ONE, false);

    assert_eq!(closed.first(), start.first());
    assert_eq!(closed.second(), start.second());
    assert_eq!(closed.deviation(), 0);
}

/// Splitting one trade into pieces collects the same total, because the totals are
/// a pure function of the book rather than of how it was reached.
#[test]
fun splitting_a_trade_reaches_the_same_totals() {
    let whole = weighted::zero_terms().fold(0, HALF_MASS, ONE, true);

    let mut split = weighted::zero_terms();
    let mut i = 0;
    while (i < 4) {
        split = split.fold(split.first(), HALF_MASS, ONE / 4, true);
        i = i + 1;
    };

    assert_eq!(split.first(), whole.first());
    assert_eq!(split.second(), whole.second());
}

#[test, expected_failure(abort_code = weighted::EWeightsExceedCertainty)]
fun a_range_mass_above_certainty_aborts() {
    weighted::zero_terms().fold(0, ALL_MASS + 1, ONE, true);
    abort 999
}
