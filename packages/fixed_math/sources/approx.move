// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A 1e9-scaled fixed-point value carried with a certified numerical-error bound —
/// a center-radius "ball". `value` is the canonical fixed-point result selected by
/// its caller; `error` bounds continuous numerical approximation along that path.
/// The ball does not choose protocol policy or represent counterfactual outcomes
/// from taking another branch: consequence-owning call sites either use the center
/// or enforce a bound on the radius.
///
/// Leaf error comes from each `math` primitive's documented accuracy; continuous
/// propagation uses derivative bounds or endpoint evaluation. Every error term
/// rounds UP, the quotient-rule term is computed division-first so it cannot
/// underflow, and error arithmetic saturates at `u64::MAX` rather than overflowing.
module fixed_math::approx;

use fixed_math::{i64::{Self, I64}, math};

/// A fixed-point value with a certified absolute error radius (raw 1e9 units).
public struct Approx has copy, drop {
    value: I64,
    error: u64,
}

// Leaf approximation error of each `math` primitive, in raw 1e9 units, taken from
// the primitive's documented accuracy in `fixed_math::math`.
macro fun cdf_leaf(): u64 { 20 }

macro fun pdf_leaf(): u64 { 50 }

macro fun sqrt_leaf(): u64 { 1 }

// `mul_down`/`div_down` and the scaled `i64` ops carry at most one raw unit of rounding.
macro fun round_leaf(): u64 { 1 }

// Global bound on `|phi'(x)| = |x| * phi(x)`, maximized at `|x| = 1`
// (`phi(1) = 0.241971`), rounded up. Bounds `normal_pdf`'s sensitivity to its input.
macro fun max_pdf_slope(): u64 { 242_000_000 }

// === Constructors and accessors ===

/// A ball with zero error: an exact signed input.
public fun exact(value: I64): Approx {
    Approx { value, error: 0 }
}

/// A ball with zero error from a nonnegative u64 input.
public fun exact_u64(value: u64): Approx {
    Approx { value: i64::from_u64(value), error: 0 }
}

/// A ball from a canonical value and its certified explicit error radius.
public fun from_certified_parts(value: I64, error: u64): Approx {
    Approx { value, error }
}

public fun value(a: &Approx): I64 {
    a.value
}

public fun error(a: &Approx): u64 {
    a.error
}

/// The magnitude of the center value (its error is unaffected by the sign).
public fun magnitude(a: &Approx): u64 {
    a.value.magnitude()
}

public fun is_negative(a: &Approx): bool {
    a.value.is_negative()
}

/// Whether every value in the ball is within `max_deviation` (relative, 1e9-scaled)
/// of its possible true value. For nonnegative protocol values the worst denominator
/// is `center - error`, so certification requires
/// `error <= max_deviation * (center - error) / 1e9`.
///
/// Callers own the bound, abort code, and any zero-magnitude policy. The products
/// use u128 so every pair of u64 operands is representable without saturation.
public fun true_relative_deviation_within(a: &Approx, max_deviation: u64): bool {
    let center = a.value.magnitude();
    if (a.error > center) return false;
    (a.error as u128) * (math::float_scaling!() as u128)
        <= (max_deviation as u128) * ((center - a.error) as u128)
}

/// Clamp to zero. This continuous projection is 1-Lipschitz, so it retains the
/// numerical radius even when the canonical center is on the zero branch.
public fun clamp_nonnegative(a: &Approx): Approx {
    if (a.value.is_negative()) {
        Approx { value: i64::zero(), error: a.error }
    } else {
        *a
    }
}

/// Clamp a probability to `[0, 1]`; both continuous projections retain radius.
public fun clamp_unit_interval(a: &Approx): Approx {
    let nonnegative = a.clamp_nonnegative();
    nonnegative.clamp_upper(math::float_scaling!())
}

/// Clamp to an exact upper bound. Negative centers already lie below every
/// nonnegative upper bound; the continuous projection retains radius.
public fun clamp_upper(a: &Approx, upper: u64): Approx {
    if (!a.value.is_negative() && a.value.magnitude() > upper) {
        Approx {
            value: i64::from_u64(upper),
            error: a.error,
        }
    } else {
        *a
    }
}

// === Linear operations ===

/// Sum. Absolute errors add (saturating).
public fun add(a: &Approx, b: &Approx): Approx {
    Approx { value: a.value.add(&b.value), error: a.error.saturating_add(b.error) }
}

/// Difference. Absolute errors add (subtraction cannot cancel uncertainty).
public fun sub(a: &Approx, b: &Approx): Approx {
    Approx { value: a.value.sub(&b.value), error: a.error.saturating_add(b.error) }
}

/// Negation. The error radius is unchanged.
public fun neg(a: &Approx): Approx {
    Approx { value: a.value.neg(), error: a.error }
}

/// Exact doubling: value and error both double (integer addition, no truncation).
public fun double(a: &Approx): Approx {
    add(a, a)
}

/// Halving by an exact factor of two. The value truncates toward zero (one raw
/// unit); the error is kept in full — a sound over-estimate of the true half-error,
/// negligible where used (the `d2` numerator, dominated by the `1/sqrt(w)` term).
public fun half(a: &Approx): Approx {
    Approx {
        value: i64::from_parts(a.value.magnitude() / 2, a.value.is_negative()),
        error: a.error.saturating_add(round_leaf!()),
    }
}

// === Scaled multiplicative operations ===

/// Scaled product. Propagates via the product rule
/// `d(ab) = |a| db + |b| da + da db`, each term rounded up, plus one raw unit.
public fun mul_scaled(a: &Approx, b: &Approx): Approx {
    let ma = a.value.magnitude();
    let mb = b.value.magnitude();
    let error = ceil_mul(ma, b.error)
        .saturating_add(ceil_mul(mb, a.error))
        .saturating_add(ceil_mul(a.error, b.error))
        .saturating_add(round_leaf!());
    Approx { value: a.value.mul_scaled(&b.value), error }
}

/// Scaled square of a signed ball, returning a nonnegative ball.
/// Propagates via `d(x^2) = 2|x| dx + dx^2`, rounded up, plus one raw unit.
public fun square_scaled(a: &Approx): Approx {
    let m = a.value.magnitude();
    let cross = ceil_mul(m, a.error);
    let error = cross
        .saturating_add(cross)
        .saturating_add(ceil_mul(a.error, a.error))
        .saturating_add(round_leaf!());
    Approx { value: i64::from_u64(a.value.square_scaled()), error }
}

/// Scaled quotient. Propagates via the quotient rule with the denominator taken at
/// the worst corner `|b| - db`. The `|a| db / b^2` term is computed division-first
/// (`ceil(|a| db / b)` then `/ b`) so a small numerator cannot underflow it to zero.
/// The scalar center is evaluated first and aborts when `b.value == 0`. For a
/// nonzero center whose ball can reach zero (`|b| <= db`), the error saturates so
/// any downstream gate rejects it.
public fun div_scaled(a: &Approx, b: &Approx): Approx {
    let ma = a.value.magnitude();
    let mb = b.value.magnitude();
    let value = a.value.div_scaled(&b.value);
    if (mb <= b.error) {
        return Approx { value, error: std::u64::max_value!() }
    };
    let denom = mb - b.error;
    let first = ceil_div(a.error, denom); // |da / b|
    let second = ceil_div(ceil_mul_div(ma, b.error, denom), denom); // |a| |db| / b^2
    let error = first.saturating_add(second).saturating_add(round_leaf!());
    Approx { value, error }
}

/// Fused `a * b / c`, matching `math::mul_div_down`'s single-floor magnitude so
/// the center stays bit-identical to the scalar path. The radius comes from exact
/// outward corner evaluation over the three input balls, not a linearization: when
/// both numerator factors retain their signs, their quotient magnitude lies in
/// `[(|a|-da)(|b|-db)/(|c|+dc), (|a|+da)(|b|+db)/(|c|-dc)]`;
/// otherwise the numerator may cross zero and either output sign is covered.
/// The scalar center is evaluated first and aborts when `c.value == 0`. For a
/// nonzero center whose denominator ball can reach zero, or an endpoint that
/// cannot be represented in the u64 error domain, the error saturates so every
/// downstream precision gate rejects it.
public fun mul_div_down(a: &Approx, b: &Approx, c: &Approx): Approx {
    let ma = a.value.magnitude();
    let mb = b.value.magnitude();
    let mc = c.value.magnitude();
    let value_magnitude = math::mul_div_down(ma, mb, mc);
    let value = i64::from_parts(
        value_magnitude,
        a.value.is_negative() != b.value.is_negative() != c.value.is_negative(),
    );
    if (mc <= c.error) {
        return Approx { value, error: std::u64::max_value!() }
    };
    let max = std::u64::max_value!();
    if (ma > max - a.error || mb > max - b.error) {
        return Approx { value, error: max }
    };

    let upper = ceil_mul_div(ma + a.error, mb + b.error, mc - c.error);
    if (upper == max) {
        return Approx { value, error: max }
    };
    let numerator_sign_is_fixed = ma > a.error && mb > b.error;
    let error = if (numerator_sign_is_fixed) {
        let lower = if (mc > max - c.error) {
            0
        } else {
            math::mul_div_down(ma - a.error, mb - b.error, mc + c.error)
        };
        let lower_distance = value_magnitude - lower;
        let upper_distance = if (upper > value_magnitude) upper - value_magnitude else 0;
        if (lower_distance >= upper_distance) lower_distance else upper_distance
    } else {
        // Crossing either numerator factor through zero can reverse the quotient's
        // sign relative to the canonical center, so the farthest endpoint is the
        // sum of their magnitudes.
        value_magnitude.saturating_add(upper)
    };
    Approx { value, error }
}

// === Transcendental operations ===

/// `ln` of a positive u64 ball. Value error is bounded by `dx / (x - dx)`
/// (worst-corner `1/x`, rounded up) plus `ln`'s approximation error: `1e-7` relative
/// plus a three-raw-unit margin covering the near-`ln(1)` quantization regime.
public fun ln(x: u64, x_error: u64): Approx {
    let value = math::ln(x);
    let leaf = value.magnitude() / 10_000_000 + 3;
    let propagated = if (x > x_error) ceil_div(x_error, x - x_error) else std::u64::max_value!();
    Approx { value, error: propagated.saturating_add(leaf) }
}

/// `ln(numerator / denominator)` for exact positive u64 inputs. The ordinary
/// 1e9 quotient path preserves its established center and error. Ratios whose
/// floored quotient cannot keep a positive lower corner instead subtract the two
/// certified logarithms, so every finite ratio remains finite.
public fun ln_ratio(numerator: u64, denominator: u64): Approx {
    let ratio_opt = math::try_div_down(numerator, denominator);
    if (ratio_opt.is_some()) {
        let ratio = ratio_opt.destroy_some();
        if (ratio > 1) return ln(ratio, 1)
    };

    let numerator_log = ln(numerator, 0);
    let denominator_log = ln(denominator, 0);
    numerator_log.sub(&denominator_log)
}

/// `sqrt` of a nonnegative ball (operand scale 1e9). Monotone, so the true value is
/// enclosed by `[sqrt(x - dx), sqrt(x + dx)]`; the error is the larger endpoint
/// deviation from `sqrt(x)`, plus one raw unit for `sqrt_down`'s own rounding. Uses the
/// center magnitude; callers guard nonnegativity of the center.
public fun sqrt(a: &Approx): Approx {
    let x = a.value.magnitude();
    let root = math::sqrt_down(x);
    let low = if (x > a.error) math::sqrt_down(x - a.error) else 0;
    let upper = if (a.error > std::u64::max_value!() - x) std::u64::max_value!() else x + a.error;
    let high = math::sqrt_down(upper);
    let spread = if (root - low >= high - root) { root - low } else { high - root };
    Approx { value: i64::from_u64(root), error: spread + sqrt_leaf!() }
}

/// `Phi(x)` for a signed ball. `Phi' = phi`, maximized over the ball at the point
/// nearest zero. The PDF primitive's own error is added before using it as an upper
/// derivative bound; `phi_upper * dx` is rounded up, then the CDF leaf error is added.
public fun normal_cdf(a: &Approx): Approx {
    let value = i64::from_u64(math::normal_cdf(&a.value));
    let m = a.value.magnitude();
    let nearest = if (m > a.error) i64::from_u64(m - a.error) else i64::zero();
    let sup_phi = math::normal_pdf(&nearest).saturating_add(pdf_leaf!());
    let error = ceil_mul(sup_phi, a.error).saturating_add(cdf_leaf!());
    Approx { value, error }
}

/// `phi(x)` for a signed ball. `|phi'|` is bounded globally by `max_pdf_slope`, so
/// `max_pdf_slope * dx` (rounded up) bounds the propagated error, plus `normal_pdf`'s
/// own approximation error.
public fun normal_pdf(a: &Approx): Approx {
    let value = i64::from_u64(math::normal_pdf(&a.value));
    let error = ceil_mul(max_pdf_slope!(), a.error).saturating_add(pdf_leaf!());
    Approx { value, error }
}

// === Private ===

/// `ceil(x * y / 1e9)`, saturating to `u64::MAX`. Scaled error products round up.
fun ceil_mul(x: u64, y: u64): u64 {
    ceil_mul_div(x, y, math::float_scaling!())
}

/// `ceil(x * 1e9 / y)`, saturating to `u64::MAX`. Scaled error quotients round up.
fun ceil_div(x: u64, y: u64): u64 {
    ceil_mul_div(x, math::float_scaling!(), y)
}

/// `ceil(x * y / d)`, saturating to `u64::MAX` when the denominator is zero or
/// the result does not fit in `u64`.
fun ceil_mul_div(x: u64, y: u64, d: u64): u64 {
    math::try_mul_div_up(x, y, d).destroy_or!(std::u64::max_value!())
}
