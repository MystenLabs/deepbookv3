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

const EInputZero: u64 = 0;

const LN2: u64 = 693_147_181;

/// Natural logarithm of x (in FLOAT_SCALING 1e9).
/// Returns (|result|, is_negative) in FLOAT_SCALING.
public fun ln(x: u64): (u64, bool) {
    assert!(x > 0, EInputZero);
    if (x == 1_000_000_000) return (0, false);

    if (x < 1_000_000_000) {
        let inv = math::div(1_000_000_000, x);
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
    if (x == 0) return 1_000_000_000;

    let (r, n) = reduce_exp(x);
    let exp_r = exp_series(r);

    if (x_negative) {
        // e^(-x) = (1/e^r) / 2^n
        let mut result = math::div(1_000_000_000, exp_r);
        let mut j: u64 = 0;
        while (j < n) {
            result = result / 2;
            if (result == 0) return 0;
            j = j + 1;
        };
        result
    } else {
        // e^x = e^r * 2^n
        let mut result = exp_r;
        let mut j: u64 = 0;
        while (j < n) {
            result = result * 2;
            j = j + 1;
        };
        result
    }
}

/// Standard normal CDF Φ(±x) using Abramowitz & Stegun (26.2.17).
public fun normal_cdf(x: u64, x_negative: bool): u64 {
    if (x > 8_000_000_000) {
        return if (x_negative) { 0 } else { 1_000_000_000 }
    };

    let t = cdf_t(x);
    let poly = cdf_poly(t);
    let pdf = cdf_pdf(x);
    let complement = math::mul(pdf, poly);

    let cdf = if (1_000_000_000 > complement) {
        1_000_000_000 - complement
    } else {
        0
    };

    if (x_negative) { 1_000_000_000 - cdf } else { cdf }
}

/// t = 1 / (1 + 0.2316419 * x)
fun cdf_t(x: u64): u64 {
    math::div(1_000_000_000, 1_000_000_000 + math::mul(231_641_900, x))
}

/// φ(x) = exp(-x²/2) * (1/√(2π))
fun cdf_pdf(x: u64): u64 {
    let x_sq_half = math::mul(x, x) / 2;
    math::mul(exp(x_sq_half, true), 398_942_280)
}

/// A&S polynomial with positive/negative coefficient split.
fun cdf_poly(t: u64): u64 {
    let t2 = math::mul(t, t);
    let t3 = math::mul(t2, t);
    let t4 = math::mul(t3, t);
    let t5 = math::mul(t4, t);

    let pos =
        math::mul(319_381_530, t)
        + math::mul(1_781_477_937, t3)
        + math::mul(1_330_274_429, t5);

    let neg = math::mul(356_563_782, t2)
        + math::mul(1_821_255_978, t4);

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
    let mut sum = 1_000_000_000;
    let mut term = 1_000_000_000;
    let mut k: u64 = 1;
    while (k <= 12) {
        term = math::div(math::mul(term, r), k * 1_000_000_000);
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
        sum = sum + math::div(term, k * 1_000_000_000);
        term = math::mul(term, z2);
        k = k + 2;
    };
    math::mul(2_000_000_000, sum)
}

/// Compute z = (y - 1) / (y + 1) where y is in FLOAT_SCALING.
fun log_ratio(y: u64): u64 {
    math::div(y - 1_000_000_000, y + 1_000_000_000)
}

/// Normalize x into [FLOAT_SCALING, 2*FLOAT_SCALING) by halving.
/// Returns (y, n) where x = y * 2^n.
fun normalize(x: u64): (u64, u64) {
    let mut y = x;
    let mut n: u64 = 0;
    while (y >= 2_000_000_000) {
        y = y / 2;
        n = n + 1;
    };
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
    let is_negative = a_neg != b_neg; // XOR for sign
    (product, is_negative)
}
