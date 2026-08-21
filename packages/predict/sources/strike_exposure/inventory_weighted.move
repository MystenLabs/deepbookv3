// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The probability-weighted inventory statistic: how unevenly the pool's payout
/// book sits, counting each settlement price by how likely it is to happen.
///
/// `W(S)` is what the pool owes if the market settles at tick `S`, and `q(S)` is
/// the risk-neutral probability of settling there, frozen when the market is
/// created and summing to one across the ladder. The statistic is the standard
/// deviation of the payout profile under that measure:
///
/// ```text
/// D(W) = sqrt( sum q(S) * W(S)^2  -  ( sum q(S) * W(S) )^2 )
/// ```
///
/// It is zero exactly when the pool owes the same at every price it could settle
/// at, and grows with how unevenly the book is distributed across the prices that
/// actually carry probability.
///
/// The unweighted form this replaces has to bound the ladder with a window,
/// because counting every tick equally over an unbounded ladder is meaningless.
/// Weighting by probability removes the need: a price the market will almost
/// certainly never reach contributes almost nothing without being excluded. So
/// there is no window to size, to freeze in the wrong place, to round down to no
/// ticks at all, or to rescale every charge when it changes.
///
/// Both totals are plain sums with no division, so a trade's fold is exact and a
/// range opened and closed returns them bit for bit. That is what makes the charge
/// refundable rather than approximately refundable.
module deepbook_predict::inventory_weighted;

use fixed_math::math;

const EWeightsExceedCertainty: u64 = 0;

/// Running totals over the settlement ladder, both weighted by the frozen
/// probability of each run: `first` is `sum q*W` and `second` is `sum q*W^2`.
/// An empty book carries zero in both.
public struct WeightedTerms has copy, drop, store {
    first: u128,
    second: u256,
}

public(package) fun zero_terms(): WeightedTerms {
    WeightedTerms { first: 0, second: 0 }
}

public(package) fun first(terms: &WeightedTerms): u128 { terms.first }

public(package) fun second(terms: &WeightedTerms): u256 { terms.second }

/// `D(W)`, in payout units. Zero for a book that owes the same at every price.
public(package) fun deviation(terms: &WeightedTerms): u64 {
    // Both totals already carry the weighting, so `first` is the mean and `second`
    // the second moment of the same distribution and no rescaling stands between
    // them. Variance is non-negative by Cauchy-Schwarz, so the subtraction is
    // exact rather than clamped.
    let mean = (terms.first as u256);
    let variance = terms.second - mean * mean;
    (math::sqrt_u128_down((variance as u128)) as u64)
}

/// Fold one range change into the totals.
///
/// `range_mass` is the range's frozen probability and `range_first` its own
/// `sum q*W` before the change. Adding `payout` across the range moves the first
/// moment by `payout * mass` and the second by `2*payout*range_first +
/// payout^2*mass`; removal inverts only the cross term.
public(package) fun fold(
    terms: &WeightedTerms,
    range_first: u128,
    range_mass: u64,
    payout: u64,
    adding: bool,
): WeightedTerms {
    assert!(range_mass <= math::float_scaling!(), EWeightsExceedCertainty);
    if (payout == 0 || range_mass == 0) return *terms;

    let scale = (math::float_scaling!() as u256);
    let quantity = (payout as u256);
    let mass = (range_mass as u256);
    let linear = ((math::mul_down(range_mass, payout)) as u128);
    let cross = 2 * quantity * (range_first as u256);
    let square = quantity * quantity * mass / scale;

    if (adding) {
        WeightedTerms {
            first: terms.first + linear,
            second: terms.second + cross + square,
        }
    } else {
        // `square` is added before `cross` is taken off so no intermediate goes
        // negative: the identity behind it is that the range's own contribution
        // stays a sum of squares, which cannot be less than zero.
        WeightedTerms {
            first: terms.first - linear,
            second: terms.second + square - cross,
        }
    }
}
