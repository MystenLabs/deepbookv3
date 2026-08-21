// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The entropic inventory statistic: how much more than its fair value the pool's
/// payout book is worth to a risk-averse holder of it.
///
/// `W(S)` is what the pool owes if the market settles at tick `S`, and `q` is the
/// risk-neutral probability of settling there, frozen when the market is created.
/// The book's certainty-equivalent cost under exponential utility is
///
/// ```text
/// C(W) = b * ln( sum_S q(S) * exp(W(S)/b) )
/// ```
///
/// and the statistic is that cost less the book's fair value:
///
/// ```text
/// D(W) = C(W) - sum_S q(S) * W(S)
/// ```
///
/// `D` is zero when the pool owes the same at every price and grows with how
/// unevenly the book is distributed, weighted by where settlement is actually
/// likely. `b` is the risk tolerance: large `b` approaches `Var(W)/(2b)` and small
/// `b` approaches the worst case.
///
/// Two properties this shape has that a standard deviation does not. Adding a
/// constant everywhere raises `C` and the fair value by the same amount, so `D` is
/// unchanged — buying every outcome costs nothing, exactly. And because the total
/// a trade pays is `(1 - rate) * fair value + rate * C`, a convex combination of
/// two monotone functions, no rate in `[0, 1]` can price a strictly worse book
/// lower; the mean-plus-deviation form admits no such rate on a fine ladder.
///
/// This module owns only the arithmetic. The accumulators are maintained by
/// `strike_exposure`, and the range reads they need come from the payout index.
module deepbook_predict::inventory_entropic;

use fixed_math::{i64, math};

/// `exp` cannot return a value that leaves `u64`, so the exponent is bounded well
/// inside its input ceiling. `b` is derived from the market's allocation to keep
/// `W/b` under this by construction rather than by hoping.
const MAX_EXPONENT_SCALED: u64 = 10_000_000_000;

const EExponentOutOfRange: u64 = 0;
const EInvalidRiskTolerance: u64 = 1;

/// Running totals over the settlement ladder, both weighted by the frozen
/// probability of each run. `expo` is `sum q * exp(W/b)` and `mean` is
/// `sum q * W`; an empty book carries `expo = 1` and `mean = 0`.
public struct EntropicTerms has copy, drop, store {
    expo: u128,
    mean: u128,
}

public(package) fun zero_terms(): EntropicTerms {
    EntropicTerms { expo: (math::float_scaling!() as u128), mean: 0 }
}

public(package) fun expo(terms: &EntropicTerms): u128 { terms.expo }

public(package) fun mean(terms: &EntropicTerms): u128 { terms.mean }

public(package) fun new_terms(expo: u128, mean: u128): EntropicTerms {
    EntropicTerms { expo, mean }
}

/// `D(W)`, in payout units. Zero for a book that owes the same everywhere.
public(package) fun deviation(terms: &EntropicTerms, risk_tolerance: u64): u64 {
    assert!(risk_tolerance > 0, EInvalidRiskTolerance);
    // `exp(W/b) >= 1` for every non-negative payout, so `expo >= 1` and the
    // logarithm is non-negative.
    let ln_expo = math::ln((terms.expo as u64));
    let certainty_equivalent = math::mul_down(risk_tolerance, ln_expo.magnitude());
    // Jensen puts the certainty equivalent at or above the fair value, so the true
    // difference is never negative — but both terms are floored independently, and
    // on a book that owes the same everywhere they are the same number, where the
    // flooring can leave the logarithm a unit short. Clamping rather than aborting
    // is the policy: the exact answer there is zero, and the clamp can only bind
    // within the rounding error of a book that carries no unevenness at all.
    certainty_equivalent.saturating_sub((terms.mean as u64))
}

/// Fold one range change into the totals.
///
/// Adding `payout` across a range multiplies that range's share of `expo` by
/// `exp(payout/b)` and leaves the rest untouched, which is why the read the caller
/// supplies is the range's own `sum q * exp(W/b)` rather than anything about the
/// whole book. `range_mass` is the range's frozen probability.
public(package) fun fold(
    terms: &EntropicTerms,
    range_expo: u128,
    range_mass: u64,
    payout: u64,
    risk_tolerance: u64,
    adding: bool,
): EntropicTerms {
    assert!(risk_tolerance > 0, EInvalidRiskTolerance);
    if (payout == 0 || range_mass == 0) return *terms;

    let exponent = math::div_down(payout, risk_tolerance);
    assert!(exponent <= MAX_EXPONENT_SCALED, EExponentOutOfRange);
    let scale = (math::float_scaling!() as u128);

    if (adding) {
        let multiplier = (math::exp(&i64::from_u64(exponent)) as u128);
        // `expo + range_expo * (multiplier - 1)`, with the subtraction taken on the
        // scaled multiplier so no intermediate leaves `u128`.
        let lifted = range_expo * multiplier / scale;
        EntropicTerms {
            expo: terms.expo + lifted - range_expo,
            mean: terms.mean + ((math::mul_down(range_mass, payout)) as u128),
        }
    } else {
        let multiplier = (math::exp(&i64::from_parts(exponent, true)) as u128);
        // Removing shrinks the same share, so the range's post-trade contribution
        // is what scales down; the result is exact for a book that carries it.
        let lowered = range_expo * multiplier / scale;
        EntropicTerms {
            expo: terms.expo + lowered - range_expo,
            mean: terms.mean - ((math::mul_down(range_mass, payout)) as u128),
        }
    }
}
