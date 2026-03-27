// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Math utilities for fixed-point arithmetic (FLOAT_SCALING = 1e9).
///
/// Provides:
/// - ln(x): natural logarithm
/// - exp(x): exponential function
/// - normal_cdf(x): standard normal CDF (Cody rational Chebyshev approximation)
/// - Signed arithmetic helpers (add, sub, mul for (magnitude, is_negative) pairs)
///
/// Public functions take u64; internal math uses u128 to minimize truncation.
module deepbook_predict::math;

use deepbook_predict::constants;

const EInputZero: u64 = 0;

// u128 constants for internal math
const F: u128 = 1_000_000_000;
const LN2_U128: u128 = 693_147_180;

// Cody rational approximation coefficients (scaled to F = 1e9)
// Source: W.J. Cody (1969), as implemented in GSL gauss.c

// Small range (|x| < 0.66291): Φ(x) = 0.5 + x * P(x²) / Q(x²)
const SMALL_THRESHOLD: u128 = 662_910_000;
const A0: u128 = 2_235_252_035;
const A1: u128 = 161_028_231_069;
const A2: u128 = 1_067_689_485_460;
const A3: u128 = 18_154_981_253_344;
const A4: u128 = 65_682_338;
const B0: u128 = 47_202_581_905;
const B1: u128 = 976_098_551_738;
const B2: u128 = 10_260_932_208_619;
const B3: u128 = 45_507_789_335_027;

// Medium range (0.66291 ≤ |x| < √32): Φ = exp(-x²/2) * P(|x|) / Q(|x|)
const MEDIUM_THRESHOLD: u128 = 5_656_854_249;
const C0: u128 = 398_941_512;
const C1: u128 = 8_883_149_794;
const C2: u128 = 93_506_656_132;
const C3: u128 = 597_270_276_395;
const C4: u128 = 2_494_537_585_290;
const C5: u128 = 6_848_190_450_536;
const C6: u128 = 11_602_651_437_647;
const C7: u128 = 9_842_714_838_384;
const C8: u128 = 11;
const D0: u128 = 22_266_688_044;
const D1: u128 = 235_387_901_782;
const D2: u128 = 1_519_377_599_408;
const D3: u128 = 6_485_558_298_267;
const D4: u128 = 18_615_571_640_885;
const D5: u128 = 34_900_952_721_146;
const D6: u128 = 38_912_003_286_093;
const D7: u128 = 19_685_429_676_860;

// ============================================================
// Public API (u64 in, u64 out)
// ============================================================

/// Natural logarithm of x (in FLOAT_SCALING 1e9).
/// Returns (|result|, is_negative) in FLOAT_SCALING.
public fun ln(x: u64): (u64, bool) {
    assert!(x > 0, EInputZero);
    if (x == constants::float_scaling!()) return (0, false);

    if (x < constants::float_scaling!()) {
        // ln(x) = -ln(1/x). Compute inv in u128 to avoid truncation.
        let inv = ((F * F / (x as u128)) as u64);
        let (result, _) = ln(inv);
        return (result, true)
    };

    // normalize needs u64 bit shifts
    let (y, n) = normalize(x);
    let result = ln_u128((y as u128), (n as u128));
    ((result as u64), false)
}

/// Exponential function. Returns e^(±x) in FLOAT_SCALING.
public fun exp(x: u64, x_negative: bool): u64 {
    if (x == 0) return constants::float_scaling!();

    // Range reduction needs u64 division
    let n = x / (LN2_U128 as u64);
    let r = x - n * (LN2_U128 as u64);
    (exp_u128((r as u128), (n as u128), x_negative) as u64)
}

/// Standard normal CDF Φ(±x) using Cody's rational Chebyshev approximation.
/// Three piecewise ranges for high accuracy (~1e-15 in float, <5 units at 1e9).
public fun normal_cdf(x: u64, x_negative: bool): u64 {
    if (x > 8 * constants::float_scaling!()) {
        return if (x_negative) { 0 } else { constants::float_scaling!() }
    };
    (normal_cdf_u128((x as u128), x_negative) as u64)
}

// ============================================================
// u128 internal functions
// ============================================================

/// ln(y) where y is normalized to [F, 2F) and n is the shift count.
/// Computes: n * ln(2) + 2 * (z + z³/3 + z⁵/5 + ... + z¹³/13)
/// where z = (y - F) / (y + F).
fun ln_u128(y: u128, n: u128): u128 {
    // log_ratio: z = (y - F) * F / (y + F)
    let z = (y - F) * F / (y + F);

    // ln_series: 2 * (z + z³/3 + z⁵/5 + ... + z¹³/13)
    let z2 = z * z / F;
    let mut term = z;
    let mut sum: u128 = 0;
    let mut k: u128 = 1;
    while (k <= 13) {
        sum = sum + term / k;
        term = term * z2 / F;
        k = k + 2;
    };
    let ln_y = 2 * sum;

    n * LN2_U128 + ln_y
}

/// e^(±x) where r is the reduced remainder and n is the shift count.
/// Computes: e^r * 2^(±n).
fun exp_u128(r: u128, n: u128, x_negative: bool): u128 {
    let exp_r = exp_series_u128(r);

    if (x_negative) {
        let mut result = F * F / exp_r;
        let mut n = n;
        if (n >= 32) { result = result >> 32; if (result == 0) return 0; n = n - 32; };
        if (n >= 16) { result = result >> 16; if (result == 0) return 0; n = n - 16; };
        if (n >= 8) { result = result >> 8; if (result == 0) return 0; n = n - 8; };
        if (n >= 4) { result = result >> 4; if (result == 0) return 0; n = n - 4; };
        if (n >= 2) { result = result >> 2; if (result == 0) return 0; n = n - 2; };
        if (n >= 1) { result = result >> 1; };
        result
    } else {
        let mut result = exp_r;
        let mut n = n;
        if (n >= 32) { result = result << 32; n = n - 32; };
        if (n >= 16) { result = result << 16; n = n - 16; };
        if (n >= 8) { result = result << 8; n = n - 8; };
        if (n >= 4) { result = result << 4; n = n - 4; };
        if (n >= 2) { result = result << 2; n = n - 2; };
        if (n >= 1) { result = result << 1; };
        result
    }
}

/// Taylor series: e^r = 1 + r + r²/2! + r³/3! + ...
fun exp_series_u128(r: u128): u128 {
    let mut sum = F;
    let mut term = F;
    let mut k: u128 = 1;
    while (k <= 12) {
        term = term * r / (k * F);
        if (term == 0) break;
        sum = sum + term;
        k = k + 1;
    };
    sum
}

/// Φ(±x) using Cody's rational Chebyshev approximation in u128.
/// Source: W.J. Cody (1969), as implemented in GSL gauss.c.
fun normal_cdf_u128(x: u128, x_negative: bool): u128 {
    if (x < SMALL_THRESHOLD) {
        // Small range: Φ(x) = 0.5 + x * P(x²) / Q(x²)
        let xsq = x * x / F;
        // Horner evaluation following GSL pattern
        let mut xnum = A4 * xsq / F;
        let mut xden = xsq;
        xnum = (xnum + A0) * xsq / F;
        xden = (xden + B0) * xsq / F;
        xnum = (xnum + A1) * xsq / F;
        xden = (xden + B1) * xsq / F;
        xnum = (xnum + A2) * xsq / F;
        xden = (xden + B2) * xsq / F;
        let ratio = (xnum + A3) * F / (xden + B3);
        let term = x * ratio / F;
        if (x_negative) { F / 2 - term } else { F / 2 + term }
    } else if (x < MEDIUM_THRESHOLD) {
        // Medium range: complement = exp(-x²/2) * P(|x|) / Q(|x|)
        let mut xnum = C8 * x / F;
        let mut xden = x;
        xnum = (xnum + C0) * x / F;
        xden = (xden + D0) * x / F;
        xnum = (xnum + C1) * x / F;
        xden = (xden + D1) * x / F;
        xnum = (xnum + C2) * x / F;
        xden = (xden + D2) * x / F;
        xnum = (xnum + C3) * x / F;
        xden = (xden + D3) * x / F;
        xnum = (xnum + C4) * x / F;
        xden = (xden + D4) * x / F;
        xnum = (xnum + C5) * x / F;
        xden = (xden + D5) * x / F;
        xnum = (xnum + C6) * x / F;
        xden = (xden + D6) * x / F;
        let rational = (xnum + C7) * F / (xden + D7);

        let x_sq_half = x * x / (F * 2);
        let n = x_sq_half / LN2_U128;
        let r = x_sq_half - n * LN2_U128;
        let exp_val = exp_u128(r, n, true);
        let complement = exp_val * rational / F;

        if (x_negative) { complement } else { F - complement }
    } else {
        // Large range: |x| >= sqrt(32) ≈ 5.657, extreme tail
        // Values are < 10 units at F scale. Clamp to 0/F.
        if (x_negative) { 0 } else { F }
    }
}

// ============================================================
// u64 helpers
// ============================================================

/// Normalize x into [FLOAT_SCALING, 2*FLOAT_SCALING) via binary search.
/// Returns (y, n) where x = y * 2^n.
fun normalize(x: u64): (u64, u64) {
    let mut y = x;
    let mut n: u64 = 0;
    let scale = constants::float_scaling!();

    if (y >> 32 >= scale) { y = y >> 32; n = n + 32; };
    if (y >> 16 >= scale) { y = y >> 16; n = n + 16; };
    if (y >> 8 >= scale) { y = y >> 8; n = n + 8; };
    if (y >> 4 >= scale) { y = y >> 4; n = n + 4; };
    if (y >> 2 >= scale) { y = y >> 2; n = n + 2; };
    if (y >> 1 >= scale) { y = y >> 1; n = n + 1; };

    (y, n)
}

// ============================================================
// Signed arithmetic (u64)
// ============================================================

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

/// (a * b) / c using u128 intermediate for full precision. Rounds down.
public fun mul_div_round_down(a: u64, b: u64, c: u64): u64 {
    ((a as u128) * (b as u128) / (c as u128)) as u64
}

/// (a * b) / c using u128 intermediate for full precision. Rounds up.
public fun mul_div_round_up(a: u64, b: u64, c: u64): u64 {
    let numerator = (a as u128) * (b as u128);
    let denominator = c as u128;
    let result = numerator / denominator;
    let round = if (numerator % denominator == 0) 0 else 1;
    (result + round) as u64
}

public fun mul_signed_u64(a: u64, a_neg: bool, b: u64, b_neg: bool): (u64, bool) {
    let product = ((a as u128) * (b as u128) / F as u64);
    if (product == 0) return (0, false);
    let is_negative = a_neg != b_neg;
    (product, is_negative)
}
