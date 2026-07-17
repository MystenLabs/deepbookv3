// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Signed integers represented by a `u64` magnitude and a canonical nonnegative zero.
/// Scaled multiplication and division use 1e9 fixed point and truncate the result's magnitude toward zero.
module fixed_math::i64;

const EZeroDivisor: u64 = 0;
const F: u128 = 1_000_000_000;

/// A signed integer whose zero value always has `is_negative == false`.
public struct I64 has copy, drop, store {
    magnitude: u64,
    is_negative: bool,
}

// === Public Functions ===

/// Returns the absolute magnitude.
public fun magnitude(value: &I64): u64 {
    value.magnitude
}

/// Returns whether the nonzero value is negative.
public fun is_negative(value: &I64): bool {
    value.is_negative
}

/// Returns whether the magnitude is zero.
public fun is_zero(value: &I64): bool {
    value.magnitude == 0
}

/// Returns canonical zero.
public fun zero(): I64 {
    I64 {
        magnitude: 0,
        is_negative: false,
    }
}

/// Creates a nonnegative value from a magnitude.
public fun from_u64(value: u64): I64 {
    I64 {
        magnitude: value,
        is_negative: false,
    }
}

/// Creates a value from its parts, normalizing zero to nonnegative.
public fun from_parts(magnitude: u64, is_negative: bool): I64 {
    if (magnitude == 0) {
        zero()
    } else {
        I64 {
            magnitude,
            is_negative,
        }
    }
}

/// Negates a value without creating negative zero.
public fun neg(value: &I64): I64 {
    if (value.magnitude == 0) {
        zero()
    } else {
        I64 {
            magnitude: value.magnitude,
            is_negative: !value.is_negative,
        }
    }
}

/// Add two signed values.
public fun add(a: &I64, b: &I64): I64 {
    if (a.is_negative == b.is_negative) {
        from_parts(a.magnitude + b.magnitude, a.is_negative)
    } else if (a.magnitude >= b.magnitude) {
        from_parts(a.magnitude - b.magnitude, a.is_negative)
    } else {
        from_parts(b.magnitude - a.magnitude, b.is_negative)
    }
}

/// Subtract `b` from `a`.
public fun sub(a: &I64, b: &I64): I64 {
    let neg_b = neg(b);
    add(a, &neg_b)
}

/// Multiplies two 1e9-scaled values and truncates the result's magnitude toward zero.
public fun mul_scaled(a: &I64, b: &I64): I64 {
    let product = ((a.magnitude as u128) * (b.magnitude as u128)) / F;
    from_parts((product as u64), a.is_negative != b.is_negative)
}

/// Divides two 1e9-scaled values and truncates the result's magnitude toward zero.
/// Aborts when the divisor is zero or the quotient does not fit in `u64`.
public fun div_scaled(a: &I64, b: &I64): I64 {
    assert!(b.magnitude > 0, EZeroDivisor);
    let quotient = ((a.magnitude as u128) * F) / (b.magnitude as u128);
    from_parts((quotient as u64), a.is_negative != b.is_negative)
}

/// Squares a 1e9-scaled value and returns a nonnegative result.
public fun square_scaled(value: &I64): u64 {
    mul_scaled(value, value).magnitude
}
