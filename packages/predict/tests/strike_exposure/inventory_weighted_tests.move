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
/// A mass and payout whose product does not divide at the fixed-point scale.
/// This pair is the regression the raw representation exists for: a fold that
/// divided would floor `payout * mass / 1e9` differently on open and close and
/// ratchet the residue upward forever.
const RAGGED_MASS: u64 = 333_333_333;
const RAGGED_PAYOUT: u64 = 1_500_000_000;

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
    // `first` carries `payout * mass` raw: one contract over certainty.
    assert_eq!(flat.first(), (ONE as u128) * (ALL_MASS as u128));

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

    assert_eq!(terms.first(), (ONE as u128) * (HALF_MASS as u128));
    assert_eq!(terms.deviation(), HALF_COVERED_DEVIATION);
}

/// The fold carries raw products with no division, so opening and closing return
/// the totals bit for bit. This is the property the entropic form could not hold.
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

/// The same round trip at a payout and mass whose product does not divide at the
/// fixed-point scale. An earlier form of the fold divided inside `square` and
/// floored inside `linear`, which returned exactly on the previous test's neat
/// pair while leaking one-directional residue on this one — fifty cycles left an
/// empty book scoring 273,861.
#[test]
fun a_ragged_range_opened_and_closed_returns_the_totals_exactly() {
    let start = weighted::zero_terms();
    let opened = start.fold(0, RAGGED_MASS, RAGGED_PAYOUT, true);
    let closed = opened.fold(opened.first(), RAGGED_MASS, RAGGED_PAYOUT, false);

    assert_eq!(closed.first(), start.first());
    assert_eq!(closed.second(), start.second());
    assert_eq!(closed.deviation(), 0);
}

/// Repeated ragged cycles cannot ratchet: after any number of open-close pairs an
/// empty book is bit-for-bit empty.
#[test]
fun ragged_cycles_do_not_accumulate_residue() {
    let mut terms = weighted::zero_terms();
    let mut i = 0u64;
    while (i < 50) {
        let opened = terms.fold(terms.first(), RAGGED_MASS, RAGGED_PAYOUT, true);
        terms = opened.fold(opened.first(), RAGGED_MASS, RAGGED_PAYOUT, false);
        i = i + 1;
    };
    assert_eq!(terms.first(), 0);
    assert_eq!(terms.second(), 0);
    assert_eq!(terms.deviation(), 0);
}

/// Splitting one trade into pieces collects the same totals, because they are a
/// pure function of the book rather than of how it was reached.
#[test]
fun splitting_a_trade_reaches_the_same_totals() {
    let whole = weighted::zero_terms().fold(0, HALF_MASS, ONE, true);

    let mut split = weighted::zero_terms();
    let mut i = 0u64;
    while (i < 4) {
        split = split.fold(split.first(), HALF_MASS, ONE / 4, true);
        i = i + 1;
    };

    assert_eq!(split.first(), whole.first());
    assert_eq!(split.second(), whole.second());
}

/// Draining a stacked book range by range lands back at zero exactly, closes in a
/// different order than the opens.
#[test]
fun draining_a_stacked_book_in_reverse_order_returns_to_zero() {
    // Three disjoint ranges: their first moments never interact, so each close
    // reads only its own contribution.
    let a_mass = 250_000_000;
    let b_mass = RAGGED_MASS;
    let c_mass = 100_000_001;
    let a = (ONE as u128) * (a_mass as u128);
    let b = (RAGGED_PAYOUT as u128) * (b_mass as u128);
    let c = (7u128) * (c_mass as u128);

    let mut terms = weighted::zero_terms();
    terms = terms.fold(0, a_mass, ONE, true);
    terms = terms.fold(0, b_mass, RAGGED_PAYOUT, true);
    terms = terms.fold(0, c_mass, 7, true);
    assert_eq!(terms.first(), a + b + c);

    terms = terms.fold(b, b_mass, RAGGED_PAYOUT, false);
    terms = terms.fold(a, a_mass, ONE, false);
    terms = terms.fold(c, c_mass, 7, false);
    assert_eq!(terms.first(), 0);
    assert_eq!(terms.second(), 0);
}

#[test, expected_failure(abort_code = weighted::EWeightsExceedCertainty)]
fun a_range_mass_above_certainty_aborts() {
    weighted::zero_terms().fold(0, ALL_MASS + 1, ONE, true);
    abort 999
}
