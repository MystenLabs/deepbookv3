module deepbook_predict::math;

use deepbook::math;

const EInputZero: u64 = 0;

const EInputTooSmall: u64 = 1;
const LN2: u64 = 693_147_181;

/// Natural logarithm of x (in FLOAT_SCALING 1e9).
/// Returns (|result|, is_negative) in FLOAT_SCALING.
public fun ln(x: u64): (u64, bool) {
    assert!(x > 0, EInputZero);
    assert!(x >= 1_000_000_000, EInputTooSmall);
    if (x == 1_000_000_000) return (0, false);

    let (y, n) = normalize(x);
    let z = log_ratio(y);
    let ln_y = ln_series(z);
    let result = n * LN2 + ln_y;

    (result, false)
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
