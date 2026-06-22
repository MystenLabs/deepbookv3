// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Signed u64 magnitude with normalized zero.
module fixed_math::i64;

const EZeroDivisor: u64 = 0;
const F: u128 = 1_000_000_000;

/// Signed integer represented as magnitude plus sign.
public struct I64 has copy, drop, store {
    magnitude: u64,
    is_negative: bool,
}

// === Public Functions ===

/// Return the absolute magnitude.
public fun magnitude(value: &I64): u64 {
    value.magnitude
}

/// Return whether the value is negative.
public fun is_negative(value: &I64): bool {
    value.is_negative
}

/// Return whether the value is normalized zero.
public fun is_zero(value: &I64): bool {
    value.magnitude == 0
}

/// Return normalized zero.
public fun zero(): I64 {
    I64 {
        magnitude: 0,
        is_negative: false,
    }
}

/// Create a nonnegative value from `u64`.
public fun from_u64(value: u64): I64 {
    I64 {
        magnitude: value,
        is_negative: false,
    }
}

/// Create a value from magnitude and sign, normalizing zero to nonnegative.
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

/// Return the negated value, preserving normalized zero.
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

/// Multiplies two FLOAT_SCALING fixed-point signed values.
public fun mul_scaled(a: &I64, b: &I64): I64 {
    let product = ((a.magnitude as u128) * (b.magnitude as u128)) / F;
    from_parts((product as u64), a.is_negative != b.is_negative)
}

/// Divide two FLOAT_SCALING fixed-point signed values.
public fun div_scaled(a: &I64, b: &I64): I64 {
    assert!(b.magnitude > 0, EZeroDivisor);
    let quotient = ((a.magnitude as u128) * F) / (b.magnitude as u128);
    from_parts((quotient as u64), a.is_negative != b.is_negative)
}

/// Square a FLOAT_SCALING fixed-point signed value and return a nonnegative result.
public fun square_scaled(value: &I64): u64 {
    mul_scaled(value, value).magnitude
}
