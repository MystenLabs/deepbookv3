// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The probability-weighted inventory statistic: how unevenly the pool's payout
/// book sits, counting each settlement price by how likely it is to happen.
///
/// `W(S)` is what the pool owes if the market settles at tick `S`, and `q(S)` is
/// the probability of settling there under the surface frozen at the market's
/// first mint, summing to one across the ladder. The statistic is the standard
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
/// Both totals are carried raw — payout times 1e9-scaled probability mass, with
/// the division by the scale deferred to `deviation` — so a fold is integer sums
/// and products with no division at all. That, not intent, is what makes a range
/// opened and closed return the totals bit for bit: a fold that divided would
/// floor differently on the way in and the way out, and the residue would only
/// ever accumulate upward.
module deepbook_predict::inventory_weighted;

use fixed_math::math;

const EWeightsExceedCertainty: u64 = 0;

/// Running totals over the settlement ladder, both weighted by the frozen
/// probability of each tick and carried at the raw mass scale: `first` is
/// `sum q*W * 1e9` and `second` is `sum q*W^2 * 1e9`. An empty book carries zero
/// in both.
///
/// Width audit, with `p <= u64::MAX` a payout and `m <= 1e9` a range mass:
/// `first` is at most `sum(p) * 1e9`, and the payout index carries `sum(p)` in
/// `u64`, so `first < 2^94`. `second` is at most `max(W)^2 * 1e9 < 2^158`, and
/// the largest fold intermediate, the cross term `2 * p * first`, stays below
/// `2^159` — all inside `u256` with headroom.
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
///
/// The variance is taken in the single-division form `(M*S2 - S1^2) / M^2` with
/// `M` the 1e9 total mass, mirroring the raw scale the totals carry. Dividing
/// each total first would lose the fractional part of the mean before squaring —
/// an error of order `max(W)` rather than of order one.
///
/// The subtraction is floored at zero rather than exact. For totals built from a
/// non-negative per-tick measure it cannot go negative, by Cauchy-Schwarz; the
/// frozen surface's floored probabilities can carry inversion dust of a few raw
/// units on adjacent boundaries, and flooring absorbs that dust instead of
/// aborting every quote on the book that exposes it.
public(package) fun deviation(terms: &WeightedTerms): u64 {
    let mass = (math::float_scaling!() as u256);
    let sum = (terms.first as u256);
    let scaled_second = mass * terms.second;
    let squared_sum = sum * sum;
    // Clamp, not abort: surface inversion dust must not brick every quote.
    let numerator = scaled_second.saturating_sub(squared_sum);
    // `variance <= max(W)^2 <= (2^64 - 1)^2 < u128::MAX`, so the narrowing is
    // total, and its root fits `u64`.
    let variance = numerator / (mass * mass);
    (math::sqrt_u128_down(variance as u128) as u64)
}

/// Fold one range change into the totals.
///
/// `range_mass` is the range's frozen probability at the 1e9 scale and
/// `range_first` its own raw `sum q*W` before the change. Adding `payout` across
/// the range moves the first total by `payout * mass` and the second by
/// `2*payout*range_first + payout^2*mass`; removal inverts only the cross term.
/// Every operand is an exact integer product, so removal at the range's
/// post-open `range_first` restores both totals exactly.
public(package) fun fold(
    terms: &WeightedTerms,
    range_first: u128,
    range_mass: u64,
    payout: u64,
    adding: bool,
): WeightedTerms {
    assert!(range_mass <= math::float_scaling!(), EWeightsExceedCertainty);
    if (payout == 0 || range_mass == 0) return *terms;

    let quantity = (payout as u256);
    let mass = (range_mass as u256);
    let linear = (payout as u128) * (range_mass as u128);
    let cross = 2 * quantity * (range_first as u256);
    let square = quantity * quantity * mass;

    if (adding) {
        WeightedTerms {
            first: terms.first + linear,
            second: terms.second + cross + square,
        }
    } else {
        // `square` joins before `cross` leaves so no intermediate goes negative:
        // the range's own contribution to the second total is a sum of squares,
        // which cannot be less than zero. The outer subtraction floors at zero
        // for the same reason `deviation`'s does — surface inversion dust can
        // undercut it by a few raw units on a book that is truly at zero, and an
        // abort there would strand the close.
        WeightedTerms {
            first: terms.first - linear,
            second: (terms.second + square).saturating_sub(cross),
        }
    }
}
