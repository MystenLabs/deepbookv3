// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Optimized replacements for expensive math in `deepbook_predict::math`.
///
/// Provides:
/// - ln(x): Horner-form evaluation (no loop, no runtime divisions)
/// - normal_cdf(x): 16-segment piecewise cubic (no exp, no loops)
/// - sqrt(x, precision): Newton-Raphson with bit-length initial guess (no loop)
///
/// All other helpers (add/sub/mul_signed_u64, exp) remain in `math.move`.
/// normal_cdf max error: 0.0108 bp (1.08e-6).
module deepbook_predict::math_optimized;

use deepbook::math;
use deepbook_predict::constants;

const EInputZero: u64 = 0;
const EInvalidPrecision: u64 = 1;

// === Precomputed reciprocals for ln Horner evaluation ===
// 1/k scaled by float_scaling() for k = 3, 5, 7, 9, 11, 13
const INV_3: u64 = 333_333_333;
const INV_5: u64 = 200_000_000;
const INV_7: u64 = 142_857_143;
const INV_9: u64 = 111_111_111;
const INV_11: u64 = 90_909_091;
const INV_13: u64 = 76_923_077;

const LN2: u64 = 693_147_181;

// === Piecewise cubic CDF: segment boundaries ===
// 16 equal-width segments of 0.25 covering [0.00, 4.00]
const B1: u64 = 250_000_000;
const B2: u64 = 500_000_000;
const B3: u64 = 750_000_000;
const B4: u64 = 1_000_000_000;
const B5: u64 = 1_250_000_000;
const B6: u64 = 1_500_000_000;
const B7: u64 = 1_750_000_000;
const B8: u64 = 2_000_000_000;
const B9: u64 = 2_250_000_000;
const B10: u64 = 2_500_000_000;
const B11: u64 = 2_750_000_000;
const B12: u64 = 3_000_000_000;
const B13: u64 = 3_250_000_000;
const B14: u64 = 3_500_000_000;
const B15: u64 = 3_750_000_000;
const B16: u64 = 4_000_000_000;

// === Piecewise cubic CDF: polynomial coefficients ===
// P(x) = A + B*x - C*x² ± D*x³
// Segments 0-3: D is negative. Segments 4-15: D is positive.
// Max overall error across all 16 segments: 1.08e-6 (0.0108 bp).

// Segment 0: [0.00, 0.25)
const SEG0_A: u64 = 500_000_000;
const SEG0_B: u64 = 398_959_382;
const SEG0_C: u64 = 342_324;
const SEG0_D: u64 = 64_775_978;
// Segment 1: [0.25, 0.50)
const SEG1_A: u64 = 499_761_907;
const SEG1_B: u64 = 401_511_291;
const SEG1_C: u64 = 9_648_560;
const SEG1_D: u64 = 53_143_610;
// Segment 2: [0.50, 0.75)
const SEG2_A: u64 = 497_133_021;
const SEG2_B: u64 = 416_853_721;
const SEG2_C: u64 = 39_744_461;
const SEG2_D: u64 = 33_290_441;
// Segment 3: [0.75, 1.00)
const SEG3_A: u64 = 487_476_319;
const SEG3_B: u64 = 455_175_156;
const SEG3_C: u64 = 90_640_087;
const SEG3_D: u64 = 10_666_642;
// Segment 4: [1.00, 1.25)
const SEG4_A: u64 = 467_658_510;
const SEG4_B: u64 = 514_628_277;
const SEG4_C: u64 = 150_230_514;
const SEG4_D: u64 = 9_288_472;
// Segment 5: [1.25, 1.50)
const SEG5_A: u64 = 441_591_165;
const SEG5_B: u64 = 577_514_264;
const SEG5_C: u64 = 200_874_199;
const SEG5_D: u64 = 22_902_870;
// Segment 6: [1.50, 1.75)
const SEG6_A: u64 = 421_718_550;
const SEG6_B: u64 = 617_779_320;
const SEG6_C: u64 = 228_092_746;
const SEG6_D: u64 = 29_041_170;
// Segment 7: [1.75, 2.00)
const SEG7_A: u64 = 424_017_101;
const SEG7_B: u64 = 614_362_991;
const SEG7_C: u64 = 226_439_343;
const SEG7_D: u64 = 28_783_020;
// Segment 8: [2.00, 2.25)
const SEG8_A: u64 = 459_580_671;
const SEG8_B: u64 = 561_390_896;
const SEG8_C: u64 = 200_125_111;
const SEG8_D: u64 = 24_423_481;
// Segment 9: [2.25, 2.50)
const SEG9_A: u64 = 528_577_709;
const SEG9_B: u64 = 469_553_831;
const SEG9_C: u64 = 159_360_886;
const SEG9_D: u64 = 18_389_349;
// Segment 10: [2.50, 2.75)
const SEG10_A: u64 = 620_281_598;
const SEG10_B: u64 = 359_479_049;
const SEG10_C: u64 = 115_302_692;
const SEG10_D: u64 = 12_508_988;
// Segment 11: [2.75, 3.00)
const SEG11_A: u64 = 718_393_440;
const SEG11_B: u64 = 252_302_607;
const SEG11_C: u64 = 76_264_638;
const SEG11_D: u64 = 7_767_799;
// Segment 12: [3.00, 3.25)
const SEG12_A: u64 = 807_823_203;
const SEG12_B: u64 = 162_690_160;
const SEG12_C: u64 = 46_325_191;
const SEG12_D: u64 = 4_432_709;
// Segment 13: [3.25, 3.50)
const SEG13_A: u64 = 879_247_088;
const SEG13_B: u64 = 96_594_701;
const SEG13_C: u64 = 25_932_625;
const SEG13_D: u64 = 2_335_009;
// Segment 14: [3.50, 3.75)
const SEG14_A: u64 = 930_058_550;
const SEG14_B: u64 = 52_917_673;
const SEG14_C: u64 = 13_415_550;
const SEG14_D: u64 = 1_139_066;
// Segment 15: [3.75, 4.00)
const SEG15_A: u64 = 962_605_687;
const SEG15_B: u64 = 26_798_937;
const SEG15_C: u64 = 6_427_775;
const SEG15_D: u64 = 515_801;

// ============================================================
// Optimized ln(x)
// ============================================================

/// Natural logarithm of x (in float_scaling).
/// Drop-in replacement for `math::ln`. Horner form — no loop, no div() calls.
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
    let ln_y = ln_horner(z);
    let result = n * LN2 + ln_y;

    (result, false)
}

// ============================================================
// Optimized normal_cdf(x, x_negative)
// ============================================================

/// Standard normal CDF Φ(±x) using piecewise cubic polynomials.
/// Drop-in replacement for `math::normal_cdf`. No exp(), no loops.
/// Max error: 0.0108 bp across all 16 segments.
public fun normal_cdf(x: u64, x_negative: bool): u64 {
    if (x >= B16) {
        return if (x_negative) { 0 } else { constants::float_scaling!() }
    };

    let x2 = math::mul(x, x);
    let x3 = math::mul(x2, x);

    let result = if (x < B1) {
        eval_neg_d(x, x2, x3, SEG0_A, SEG0_B, SEG0_C, SEG0_D)
    } else if (x < B2) {
        eval_neg_d(x, x2, x3, SEG1_A, SEG1_B, SEG1_C, SEG1_D)
    } else if (x < B3) {
        eval_neg_d(x, x2, x3, SEG2_A, SEG2_B, SEG2_C, SEG2_D)
    } else if (x < B4) {
        eval_neg_d(x, x2, x3, SEG3_A, SEG3_B, SEG3_C, SEG3_D)
    } else if (x < B5) {
        eval_pos_d(x, x2, x3, SEG4_A, SEG4_B, SEG4_C, SEG4_D)
    } else if (x < B6) {
        eval_pos_d(x, x2, x3, SEG5_A, SEG5_B, SEG5_C, SEG5_D)
    } else if (x < B7) {
        eval_pos_d(x, x2, x3, SEG6_A, SEG6_B, SEG6_C, SEG6_D)
    } else if (x < B8) {
        eval_pos_d(x, x2, x3, SEG7_A, SEG7_B, SEG7_C, SEG7_D)
    } else if (x < B9) {
        eval_pos_d(x, x2, x3, SEG8_A, SEG8_B, SEG8_C, SEG8_D)
    } else if (x < B10) {
        eval_pos_d(x, x2, x3, SEG9_A, SEG9_B, SEG9_C, SEG9_D)
    } else if (x < B11) {
        eval_pos_d(x, x2, x3, SEG10_A, SEG10_B, SEG10_C, SEG10_D)
    } else if (x < B12) {
        eval_pos_d(x, x2, x3, SEG11_A, SEG11_B, SEG11_C, SEG11_D)
    } else if (x < B13) {
        eval_pos_d(x, x2, x3, SEG12_A, SEG12_B, SEG12_C, SEG12_D)
    } else if (x < B14) {
        eval_pos_d(x, x2, x3, SEG13_A, SEG13_B, SEG13_C, SEG13_D)
    } else if (x < B15) {
        eval_pos_d(x, x2, x3, SEG14_A, SEG14_B, SEG14_C, SEG14_D)
    } else {
        eval_pos_d(x, x2, x3, SEG15_A, SEG15_B, SEG15_C, SEG15_D)
    };

    if (x_negative) { constants::float_scaling!() - result } else { result }
}

// ============================================================
// Optimized sqrt(x, precision)
// ============================================================

/// Fixed-point square root. Drop-in replacement for `deepbook::math::sqrt`.
/// Uses bit-length initial guess + 7 unrolled Newton-Raphson steps. No loop.
public fun sqrt(x: u64, precision: u64): u64 {
    assert!(precision <= constants::float_scaling!(), EInvalidPrecision);
    let multiplier = (constants::float_scaling!() / precision) as u128;
    let scaled = (x as u128) * multiplier * (constants::float_scaling!() as u128);
    (sqrt_u128(scaled) / multiplier) as u64
}

// ============================================================
// Private helpers
// ============================================================

/// Horner-form: 2*(z + z³/3 + z⁵/5 + z⁷/7 + z⁹/9 + z¹¹/11 + z¹³/13)
/// = 2*z*(1 + w*(1/3 + w*(1/5 + w*(1/7 + w*(1/9 + w*(1/11 + w/13))))))
/// where w = z². Reciprocals precomputed — no div() calls.
fun ln_horner(z: u64): u64 {
    let scale = constants::float_scaling!() as u128;
    let z = z as u128;
    let w = mul_scaled_u128(z, z);
    let mut h = mul_scaled_u128(w, INV_13 as u128);
    h = mul_scaled_u128((INV_11 as u128) + h, w);
    h = mul_scaled_u128((INV_9 as u128) + h, w);
    h = mul_scaled_u128((INV_7 as u128) + h, w);
    h = mul_scaled_u128((INV_5 as u128) + h, w);
    h = mul_scaled_u128((INV_3 as u128) + h, w);
    let f = scale + h;
    mul_scaled_u128(mul_scaled_u128(2 * scale, z), f) as u64
}

/// Normalize x into [float_scaling, 2*float_scaling) via bit-shift binary search.
/// Replaces the original while-loop. No loop; 6 conditional right-shifts.
fun normalize(x: u64): (u64, u64) {
    let scale = constants::float_scaling!();
    let mut y = x;
    let mut n: u64 = 0;
    if (y >> 32 >= scale) { y = y >> 32; n = n + 32; };
    if (y >> 16 >= scale) { y = y >> 16; n = n + 16; };
    if (y >> 8 >= scale) { y = y >> 8; n = n + 8; };
    if (y >> 4 >= scale) { y = y >> 4; n = n + 4; };
    if (y >> 2 >= scale) { y = y >> 2; n = n + 2; };
    if (y >> 1 >= scale) { y = y >> 1; n = n + 1; };
    (y, n)
}

fun log_ratio(y: u64): u64 {
    math::div(y - constants::float_scaling!(), y + constants::float_scaling!())
}

fun mul_scaled_u128(x: u128, y: u128): u128 {
    x * y / (constants::float_scaling!() as u128)
}

/// Integer sqrt of u128 via bit-length initial guess + 7 unrolled Newton steps.
/// Each Newton step doubles bits of precision; 7 steps cover all u128 inputs.
fun sqrt_u128(x: u128): u128 {
    if (x == 0) return 0;
    if (x < 4) return 1;
    let mut g = initial_guess(x);
    g = (g + x / g) / 2;
    g = (g + x / g) / 2;
    g = (g + x / g) / 2;
    g = (g + x / g) / 2;
    g = (g + x / g) / 2;
    g = (g + x / g) / 2;
    g = (g + x / g) / 2;
    if (g * g > x) { g = g - 1; };
    g
}

/// 2^((bit_length(x)+1)/2) — within 2× of true sqrt(x).
fun initial_guess(x: u128): u128 {
    let mut bits: u8 = 0;
    let mut val = x;
    if (val >= 1u128 << 64) { val = val >> 64; bits = bits + 64; };
    if (val >= 1u128 << 32) { val = val >> 32; bits = bits + 32; };
    if (val >= 1u128 << 16) { val = val >> 16; bits = bits + 16; };
    if (val >= 1u128 << 8) { val = val >> 8; bits = bits + 8; };
    if (val >= 1u128 << 4) { val = val >> 4; bits = bits + 4; };
    if (val >= 1u128 << 2) { val = val >> 2; bits = bits + 2; };
    if (val >= 1u128 << 1) { bits = bits + 1; };
    1u128 << (((bits + 1) / 2) as u8)
}

/// Segs 0-3: P(x) = A + B*x - C*x² - D*x³
fun eval_neg_d(x: u64, x2: u64, x3: u64, a: u64, b: u64, c: u64, d: u64): u64 {
    let pos = a + math::mul(b, x);
    let neg = math::mul(c, x2) + math::mul(d, x3);
    if (pos > neg) { pos - neg } else { 0 }
}

/// Segs 4-15: P(x) = A + B*x - C*x² + D*x³
fun eval_pos_d(x: u64, x2: u64, x3: u64, a: u64, b: u64, c: u64, d: u64): u64 {
    let pos = a + math::mul(b, x) + math::mul(d, x3);
    let neg = math::mul(c, x2);
    if (pos > neg) { pos - neg } else { 0 }
}
