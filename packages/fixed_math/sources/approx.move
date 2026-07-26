// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A 1e9-scaled fixed-point value carried with a certified numerical-error bound —
/// a center-radius "ball". `value` is the canonical fixed-point result selected by
/// its caller; `error` bounds continuous numerical approximation along that path.
/// The ball does not choose protocol policy or represent counterfactual outcomes
/// from taking another branch: consequence-owning call sites either use the center
/// or enforce a bound on the radius.
///
/// This is the carrier for a certificate that has already been produced, not the
/// place certificates are derived. Its operations are exactly the linear algebra a
/// certified value travels through after its producer certifies it — sums,
/// differences, exact-multiplier scaling, and 1-Lipschitz clamps — so error
/// propagation here is `Σ |k| de` and nothing more. Nonlinear propagation (roots,
/// quotients, transcendentals) belongs inline in the formula that needs it, beside
/// the value it certifies. Every error term rounds UP and saturates at `u64::MAX`
/// rather than overflowing.
module fixed_math::approx;

use fixed_math::{i64::{Self, I64}, math};

/// A fixed-point value with a certified absolute error radius (raw 1e9 units).
public struct Approx has copy, drop {
    value: I64,
    error: u64,
}

// The scaled `i64` ops carry at most one raw unit of rounding.
macro fun round_leaf(): u64 { 1 }

// === Constructors and accessors ===

/// A ball with zero error from a nonnegative u64 input.
public fun exact_u64(value: u64): Approx {
    Approx { value: i64::from_u64(value), error: 0 }
}

/// A ball from a canonical value and its certified explicit error radius.
public fun from_certified_parts(value: I64, error: u64): Approx {
    Approx { value, error }
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

/// Scaled product with an exact signed multiplier. Every product a certified value
/// travels through has one exact operand — an order quantity, a stored SVI
/// parameter — so the general product rule `d(ab) = |a| db + |b| da + da db` keeps
/// only its `|k| da` term, rounded up, plus one raw unit. Either zero is absorbing:
/// an exact zero multiplier annihilates, and a certified exact zero stays exact.
public fun mul_exact(a: &Approx, k: &I64): Approx {
    if (k.is_zero() || (a.value.is_zero() && a.error == 0)) {
        return exact_u64(0)
    };

    let error = ceil_mul(k.magnitude(), a.error).saturating_add(round_leaf!());
    Approx { value: a.value.mul_scaled(k), error }
}

// === Private ===

/// `ceil(x * y / 1e9)`, saturating to `u64::MAX` when the result does not fit in
/// `u64`. Scaled error products round up.
fun ceil_mul(x: u64, y: u64): u64 {
    math::try_mul_div_up(x, y, math::float_scaling!()).destroy_or!(std::u64::max_value!())
}
