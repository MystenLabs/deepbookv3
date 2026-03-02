// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Math utilities for fixed-point arithmetic (FLOAT_SCALING = 1e9).
///
/// Provides:
/// - ln(x): natural logarithm
/// - exp(x): exponential function
/// - normal_cdf(x): standard normal CDF (Abramowitz & Stegun 26.2.17)
/// - Signed arithmetic helpers (add, sub, mul for (magnitude, is_negative) pairs)
module deepbook_predict::math;

use deepbook::math;
use deepbook_predict::constants;

const EInputZero: u64 = 0;

const LN2: u64 = 693_147_181;

/// Natural logarithm of x (in FLOAT_SCALING 1e9).
/// Returns (|result|, is_negative) in FLOAT_SCALING.
public fun ln(x: u64): (u64, bool) {
    assert!(x > 0, EInputZero);
    if (x == constants::float_scaling!()) return (0, false);

    if (x < constants::float_scaling!()) {
        let inv = math::div(constants::float_scaling!(), x);
        let (result, _) = ln(inv);
        return (result, true)
    };

    let (y, n) = normalize(x);
    let z = log_ratio(y);
    let ln_y = ln_series(z);
    let result = n * LN2 + ln_y;

    (result, false)
}

/// Exponential function. Returns e^(±x) in FLOAT_SCALING.
public fun exp(x: u64, x_negative: bool): u64 {
    if (x == 0) return constants::float_scaling!();

    let (r, n) = reduce_exp(x);
    let exp_r = exp_series(r);

    if (x_negative) {
        // e^(-x) = (1/e^r) / 2^n
        let result = math::div(constants::float_scaling!(), exp_r);
        result >> (n as u8)
    } else {
        // e^x = e^r * 2^n
        exp_r << (n as u8)
    }
}

/// Standard normal CDF Φ(±x) using Abramowitz & Stegun (26.2.17).
public fun normal_cdf(x: u64, x_negative: bool): u64 {
    if (x > 8 * constants::float_scaling!()) {
        return if (x_negative) { 0 } else { constants::float_scaling!() }
    };

    let t = cdf_t(x);
    let poly = cdf_poly(t);
    let pdf = cdf_pdf(x);
    let complement = math::mul(pdf, poly);

    let cdf = if (constants::float_scaling!() > complement) {
        constants::float_scaling!() - complement
    } else {
        0
    };

    if (x_negative) { constants::float_scaling!() - cdf } else { cdf }
}

/// t = 1 / (1 + 0.2316419 * x)
fun cdf_t(x: u64): u64 {
    math::div(constants::float_scaling!(), constants::float_scaling!() + math::mul(231_641_900, x))
}

/// φ(x) = exp(-x²/2) * (1/√(2π))
fun cdf_pdf(x: u64): u64 {
    let x_sq_half = math::mul(x, x) / 2;
    math::mul(exp(x_sq_half, true), 398_942_280)
}

/// A&S polynomial using grouped Horner's method.
/// pos = t * (a1 + t² * (a3 + t² * a5))
/// neg = t² * (a2 + t² * a4)
fun cdf_poly(t: u64): u64 {
    let t2 = math::mul(t, t);

    let pos = math::mul(
        t,
        319_381_530
        + math::mul(t2, 1_781_477_937
            + math::mul(t2, 1_330_274_429)),
    );

    let neg = math::mul(t2, 356_563_782
        + math::mul(t2, 1_821_255_978));

    pos - neg
}

/// Range reduction: split x into n*ln(2) + r where r in [0, ln2).
fun reduce_exp(x: u64): (u64, u64) {
    let n = x / LN2;
    let r = x - n * LN2;
    (r, n)
}

/// Taylor series: e^r = 1 + r + r²/2! + r³/3! + ...
fun exp_series(r: u64): u64 {
    let mut sum = constants::float_scaling!();
    let mut term = constants::float_scaling!();
    let mut k: u64 = 1;
    while (k <= 12) {
        term = math::div(math::mul(term, r), k * constants::float_scaling!());
        if (term == 0) break;
        sum = sum + term;
        k = k + 1;
    };
    sum
}

/// Compute 2 * (z + z³/3 + z⁵/5 + ... + z¹³/13) in FLOAT_SCALING.
fun ln_series(z: u64): u64 {
    let z2 = math::mul(z, z);
    let mut term = z;
    let mut sum = 0;
    let mut k: u64 = 1;
    while (k <= 13) {
        sum = sum + math::div(term, k * constants::float_scaling!());
        term = math::mul(term, z2);
        k = k + 2;
    };
    math::mul(2 * constants::float_scaling!(), sum)
}

/// Compute z = (y - 1) / (y + 1) where y is in FLOAT_SCALING.
fun log_ratio(y: u64): u64 {
    math::div(y - constants::float_scaling!(), y + constants::float_scaling!())
}

/// Normalize x into [FLOAT_SCALING, 2*FLOAT_SCALING) via binary search.
/// Returns (y, n) where x = y * 2^n.
fun normalize(x: u64): (u64, u64) {
    let mut y = x;
    let mut n: u64 = 0;
    let scale = constants::float_scaling!();

    if (y >= scale << 32) { y = y >> 32; n = n + 32; };
    if (y >= scale << 16) { y = y >> 16; n = n + 16; };
    if (y >= scale << 8) { y = y >> 8; n = n + 8; };
    if (y >= scale << 4) { y = y >> 4; n = n + 4; };
    if (y >= scale << 2) { y = y >> 2; n = n + 2; };
    if (y >= scale << 1) { y = y >> 1; n = n + 1; };

    (y, n)
}

/// Represents a signed integer as (magnitude, is_negative).
/// Computes: (a, a_neg) - (b, b_neg) and returns (magnitude, is_negative).
public fun sub_signed_u64(a: u64, a_neg: bool, b: u64, b_neg: bool): (u64, bool) {
    // a - b  ==  a + (-b)
    let b_neg2 = !b_neg;
    add_signed_u64(a, a_neg, b, b_neg2)
}

/// Computes: (a, a_neg) + (b, b_neg) using only + and - on u64.
public fun add_signed_u64(a: u64, a_neg: bool, b: u64, b_neg: bool): (u64, bool) {
    // Same sign: magnitudes add, sign preserved.
    if (a_neg == b_neg) {
        let sum = a + b;
        // Normalize -0 to +0
        if (sum == 0) (0, false) else (sum, a_neg)
    } else {
        // Different signs: subtract smaller magnitude from larger.
        // Result sign is the sign of the larger magnitude term.
        if (a >= b) {
            let diff = a - b; // safe because a >= b
            if (diff == 0) (0, false) else (diff, a_neg)
        } else {
            let diff = b - a; // safe because b > a
            if (diff == 0) (0, false) else (diff, b_neg)
        }
    }
}

public fun mul_signed_u64(a: u64, a_neg: bool, b: u64, b_neg: bool): (u64, bool) {
    let product = math::mul(a, b);
    if (product == 0) return (0, false);
    let is_negative = a_neg != b_neg; // XOR for sign
    (product, is_negative)
}
