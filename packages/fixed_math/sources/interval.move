// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Sound interval arithmetic over non-negative 1e9-scaled fixed-point values.
///
/// An `Interval` carries a lower and upper bound on a derived quantity; the
/// soundness contract is that whenever every input's true value lies inside its
/// interval, the output's true value lies inside the output interval. Bounds are
/// maintained with directed rounding (`math::mul`/`math::mul_up`,
/// `math::div`/`math::div_up`), so each side absorbs its own rounding and no
/// separate error tracking is needed. Exact protocol atoms (quantities, floors,
/// balances) enter as zero-width intervals; consumers collapse to a scalar by
/// reading one side (`lo` for protocol outflows, `hi` for inflows, liabilities,
/// and reserves) at explicit, auditable call sites.
///
/// `Interval` deliberately has no `store` ability: envelopes are transaction-
/// local by construction, and persistent state stores exact scalars only.
///
/// An operation aborts when its upper bound cannot be represented (u64 overflow
/// on the hi side, or a subtraction whose result is definitely negative); the
/// lower bound alone never aborts — underflow on the lo side clamps to zero,
/// which is sound because every modeled quantity is non-negative.
module fixed_math::interval;

use fixed_math::math;

const EInvalidBounds: u64 = 0;
const EDefinitelyNegative: u64 = 1;

/// Non-negative bounds with `lo <= hi`; width `hi - lo` is the carried error.
public struct Interval has copy, drop {
    lo: u64,
    hi: u64,
}

/// Create an interval from validated bounds.
public fun new(lo: u64, hi: u64): Interval {
    assert!(lo <= hi, EInvalidBounds);
    Interval { lo, hi }
}

/// Embed an exact value as a zero-width interval.
public fun exact(value: u64): Interval {
    Interval { lo: value, hi: value }
}

/// Lower bound: the collapse side for protocol outflows.
public fun lo(self: &Interval): u64 {
    self.lo
}

/// Upper bound: the collapse side for protocol inflows, liabilities, reserves.
public fun hi(self: &Interval): u64 {
    self.hi
}

/// Carried error: `hi - lo`.
public fun width(self: &Interval): u64 {
    self.hi - self.lo
}

/// Widen both sides by an absolute error bound; the lower side clamps at zero.
/// Used to fold a certified evaluation-error constant into a computed value.
public fun widen(self: &Interval, err: u64): Interval {
    let lo = if (self.lo > err) self.lo - err else 0;
    Interval { lo, hi: self.hi + err }
}

/// Sum: widths add.
public fun add(self: &Interval, other: &Interval): Interval {
    Interval { lo: self.lo + other.lo, hi: self.hi + other.hi }
}

/// Difference: `[lo - other.hi, hi - other.lo]`; widths add. The lower side
/// clamps at zero (the true value may still be positive when the bounds cross);
/// aborts only when the difference is definitely negative — for a quantity known
/// non-negative that means broken inputs, not dust.
public fun sub(self: &Interval, other: &Interval): Interval {
    assert!(self.hi >= other.lo, EDefinitelyNegative);
    let lo = if (self.lo > other.hi) self.lo - other.hi else 0;
    Interval { lo, hi: self.hi - other.lo }
}

/// Scaled product: lo side rounds down, hi side rounds up (+1 ulp width).
public fun mul(self: &Interval, other: &Interval): Interval {
    Interval {
        lo: math::mul(self.lo, other.lo),
        hi: math::mul_up(self.hi, other.hi),
    }
}

/// Scaled quotient: divides the lo side by the divisor's hi and the hi side by
/// the divisor's lo. A divisor whose lower bound is zero might be zero and
/// aborts (`math::EInputZero`).
public fun div(self: &Interval, other: &Interval): Interval {
    Interval {
        lo: math::div(self.lo, other.hi),
        hi: math::div_up(self.hi, other.lo),
    }
}

/// Pointwise minimum: sound because min is monotone in both arguments.
public fun min(self: &Interval, other: &Interval): Interval {
    Interval { lo: self.lo.min(other.lo), hi: self.hi.min(other.hi) }
}

/// Pointwise maximum: sound because max is monotone in both arguments.
public fun max(self: &Interval, other: &Interval): Interval {
    Interval { lo: self.lo.max(other.lo), hi: self.hi.max(other.hi) }
}
