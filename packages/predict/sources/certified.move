// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A nonnegative fixed-point amount paired with a certified absolute error radius
/// (both raw 1e9 units), for the few places a value and its bound must cross a
/// module boundary together.
///
/// This is a label, not an arithmetic type. Everything downstream of a price is
/// linear with exact coefficients — the payout walk, the leveraged correction,
/// marked liability, market NAV, and pool NAV contain no product of two uncertain
/// values, no division, and no transcendental — so the radius of a composed
/// quantity is just `Σ term_error(quantity, price_radius)` over the terms a
/// traversal visits. Traversals therefore accumulate a plain `u64` as they go and
/// compose values with the ordinary `i64` and `std::u64` operations, rather than
/// threading a numeric wrapper that re-exports those operations with a rider.
///
/// The two fields are the same type, so a positional swap would compile and
/// misprice. Values that travel between modules use this struct for that reason;
/// values local to one function stay as plain locals.
module deepbook_predict::certified;

use fixed_math::math;

/// A certified nonnegative amount: `value` with a bound of `error` on its distance
/// from the true quantity.
public struct Certified has copy, drop, store {
    value: u64,
    error: u64,
}

// A scaled product, a floored quotient, and the scaled `i64` ops each carry at most
// one raw unit of rounding.
macro fun round_leaf(): u64 { 1 }

public fun new(value: u64, error: u64): Certified {
    Certified { value, error }
}

/// An exactly known amount.
public fun exact(value: u64): Certified {
    Certified { value, error: 0 }
}

public fun value(certified: &Certified): u64 {
    certified.value
}

public fun error(certified: &Certified): u64 {
    certified.error
}

/// The radius contributed by scaling a certified price by an exact quantity.
///
/// The general product rule `d(ab) = |a| db + |b| da + da db` keeps only its
/// `|quantity| * d(price)` term because the quantity is exact, rounded up, plus one
/// raw unit for the scaled product's own truncation. Either zero is absorbing: an
/// exact zero quantity annihilates the term, and a price certified as exactly zero
/// contributes nothing to scale.
///
/// This is the single derivation every traversal calls. Re-expressing it per site
/// would let two accumulations of the same aggregate disagree.
public fun term_error(quantity: u64, price: u64, price_error: u64): u64 {
    if (quantity == 0 || (price == 0 && price_error == 0)) {
        return 0
    };
    ceil_mul(quantity, price_error).saturating_add(round_leaf!())
}

/// Whether every amount in `[value - error, value + error]` is within
/// `max_deviation` (relative, 1e9-scaled) of the true quantity. The worst
/// denominator is `value - error`, so certification requires
/// `error <= max_deviation * (value - error) / 1e9`.
///
/// Callers own the bound, the abort code, and any zero-value policy. The products
/// use u128 so every pair of u64 operands is representable without saturation.
public fun relative_deviation_within(certified: &Certified, max_deviation: u64): bool {
    if (certified.error > certified.value) return false;
    (certified.error as u128) * (math::float_scaling!() as u128)
        <= (max_deviation as u128) * ((certified.value - certified.error) as u128)
}

/// `ceil(x * y / 1e9)`, saturating to `u64::MAX` when the result does not fit in
/// `u64`. Scaled error products round up.
fun ceil_mul(x: u64, y: u64): u64 {
    math::try_mul_div_up(x, y, math::float_scaling!()).destroy_or!(std::u64::max_value!())
}
