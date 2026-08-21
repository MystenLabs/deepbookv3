// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit coverage for the entropic inventory statistic. Expected values are
/// derived from the definition by hand or in Python against `math.log`/`math.exp`,
/// never from the contract.
#[test_only]
module deepbook_predict::inventory_entropic_tests;

use deepbook_predict::inventory_entropic as entropic;
use std::unit_test::assert_eq;

/// One unit at the fixed-point scale, used as both the risk tolerance and the
/// trade size so the exponent is exactly 1 and `e` appears undivided.
const ONE: u64 = 1_000_000_000;
/// The whole settlement ladder's probability, and half of it.
const ALL_MASS: u64 = 1_000_000_000;
const HALF_MASS: u64 = 500_000_000;
/// `b*ln(0.5*(1+e)) - 0.5` at the fixed-point scale, computed independently.
const HALF_COVERED_DEVIATION: u64 = 120_114_506;
/// `exp` and `ln` are fixed-point approximations whose precision this repository
/// does not document, so this case is asserted within a bound rather than exactly.
/// The bound is granularity-derived, not fitted: the exponential carries at most a
/// few units of error at the fixed-point scale, the logarithm turns that into a
/// comparable absolute error, and the risk tolerance scales it by one. Every
/// mathematically exact property of the statistic is pinned by the other tests
/// here, which assert zero.
const APPROXIMATION_BOUND: u64 = 32;

#[test]
fun an_empty_book_owes_the_same_everywhere_and_scores_zero() {
    assert_eq!(entropic::zero_terms().deviation(ONE), 0);
}

/// The property the whole design rests on: a payout added at every settlement
/// price raises the fair value and the certainty equivalent by the same amount, so
/// buying every outcome is free. Exact, not approximate.
#[test]
fun adding_the_same_payout_everywhere_leaves_the_statistic_at_zero() {
    let terms = entropic::zero_terms();
    let full_ladder = terms.expo();

    let after = terms.fold(full_ladder, ALL_MASS, ONE, ONE, true);

    assert_eq!(after.deviation(ONE), 0);
    // The fair value moved by the whole payout even though the statistic did not.
    assert_eq!(after.mean(), (ONE as u128));
}

/// A book that owes on half the probability and nothing on the other half.
/// `expo = 0.5*(1 + e)`, `mean = 0.5`, and the statistic is the gap between the
/// certainty equivalent and the fair value.
#[test]
fun a_half_covered_book_carries_the_gap_between_cost_and_value() {
    let terms = entropic::zero_terms();
    let half_ladder = (HALF_MASS as u128);

    let after = terms.fold(half_ladder, HALF_MASS, ONE, ONE, true);

    assert_eq!(after.mean(), (HALF_MASS as u128));
    let deviation = after.deviation(ONE);
    assert!(deviation <= HALF_COVERED_DEVIATION);
    assert!(HALF_COVERED_DEVIATION - deviation <= APPROXIMATION_BOUND);
}

/// Opening and closing the same range returns the totals, so a round trip collects
/// nothing. This is what makes the charge refundable.
#[test]
fun a_range_opened_and_closed_returns_the_totals() {
    let terms = entropic::zero_terms();
    let half_ladder = (HALF_MASS as u128);

    let opened = terms.fold(half_ladder, HALF_MASS, ONE, ONE, true);
    // The close reads the range's post-trade share, which is what it now carries.
    let range_after = opened.expo() - ((ALL_MASS - HALF_MASS) as u128);
    let closed = opened.fold(range_after, HALF_MASS, ONE, ONE, false);

    assert_eq!(closed.mean(), 0);
    assert_eq!(closed.deviation(ONE), 0);
}

#[test, expected_failure(abort_code = entropic::EExponentOutOfRange)]
fun a_payout_far_beyond_the_risk_tolerance_aborts() {
    let terms = entropic::zero_terms();
    terms.fold((ALL_MASS as u128), ALL_MASS, 11 * ONE, ONE, true);
    abort 999
}

#[test, expected_failure(abort_code = entropic::EInvalidRiskTolerance)]
fun a_zero_risk_tolerance_aborts() {
    entropic::zero_terms().deviation(0);
    abort 999
}
