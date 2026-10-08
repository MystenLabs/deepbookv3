// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pure pricing math for Predict, moved out of `deepbook_predict` so the
/// package stays under Sui's object-size limit.
///
/// Every function takes and returns primitives (and `fixed_math` values) and
/// reads no state, so it cannot move value or see an object. Each body is
/// Predict's own code, moved unchanged: SVI evaluation and the roll-down, the
/// pricing-safe input bounds and minimum-variance checks as booleans, the
/// Bernoulli trading-fee curve with its expiry ramp, the inventory-impact
/// potential, premium sizing, the builder fee, and the order-flow cash-need
/// formulas. Predict keeps every abort: where a check here fails, it returns a
/// boolean or `none`, and Predict asserts with its own error code.
module deepbook_predict_math::math;

use fixed_math::{i64::{Self, I64}, math as fixed};

// The codes `digital` reports beside a `none` price. They equal Predict
// pricing's `EZeroForward`, `ECannotBeNegative`, and `ENonPositiveVariance`,
// which Predict aborts with.
const ZERO_FORWARD: u64 = 0;
const NEGATIVE_INNER: u64 = 1;
const NON_POSITIVE_VARIANCE: u64 = 2;

/// Predict's pricing envelope for raw Block Scholes inputs: the forward is at
/// most this factor times the spot, and the spot at most `u64::MAX` over it.
macro fun max_basis_factor(): u64 { 100 }

macro fun max_spot(): u64 { std::u64::max_value!() / max_basis_factor!() }

// 1e-5, the floor Block Scholes recommends: SSVI surfaces narrow `sigma` toward
// expiry, so one-minute slices commonly sit below 1e-3. Any positive floor keeps
// the smile root `sqrt((k - m)^2 + sigma^2)` nonzero, so the skew slope's
// `(k - m) / root` division is safe at the smile vertex.
macro fun min_svi_sigma(): u64 { 10_000 }

macro fun max_svi_input(): u64 { 100 * fixed::float_scaling!() }

// === SVI ===

/// Scale one 1e9-scaled SVI magnitude down by the fraction of anchored time
/// remaining, returning it at 1e18.
///
/// The roll-down result is kept at 1e18 because the fraction is applied to values
/// that are themselves tiny on short-dated surfaces: a 1e9 floor here costs up to
/// a whole raw unit of `a`, and a short-dated `a` is only about ten raw units, so
/// the truncation alone moves the digital by percent-scale amounts. At 1e18 the
/// same floor is a billionth of that.
///
/// The `u256` intermediate keeps the product exact for any `expiry_ms` rather than
/// relying on a bound on the anchored horizon. The result is at most
/// `value * 1e9 < 2^64 * 1e9`, so narrowing to `u128` never truncates.
public fun roll_down(value: u64, remaining_ms: u64, anchor_tte_ms: u64): u128 {
    let scaled =
        (value as u256) * (fixed::float_scaling!() as u256) * (remaining_ms as u256)
        / (anchor_tte_ms as u256);
    scaled as u128
}

/// The adjusted UP digital for `strike` on a rolled SVI surface (`a` and `b` at
/// 1e18, `rho`, `m`, and `sigma` at 1e9) and `forward`:
/// - k = ln(strike / forward)
/// - w(k) = a + b * (rho * (k - m) + sqrt((k - m)^2 + sigma^2))
/// - d2 = -((k + w(k) / 2) / sqrt(w(k)))
/// - price = N(d2) - phi(d2) * w'(k) / (2 * sqrt(w(k)))
///
/// Returns the price and `0`, or `none` and the code Predict aborts with where
/// the formula is undefined: a zero forward, a negative inner term, or a
/// non-positive variance.
public fun digital(
    a_magnitude: u128,
    a_is_negative: bool,
    b: u128,
    rho: I64,
    m: I64,
    sigma: u64,
    forward: u64,
    strike: u64,
): (Option<u64>, u64) {
    if (forward == 0) return (option::none(), ZERO_FORWARD);

    // Log-moneyness as a DIFFERENCE of logarithms, never as `ln` of a fixed-point
    // ratio. Forming `strike * 1e9 / forward` first destroys exactly the tails it
    // is asked about: the quotient floors to zero once `strike` is a billionth of
    // `forward` and leaves `u64` once it is 1.8e10 times it, and just inside those
    // limits it survives as a handful of raw units carrying tens of percent of
    // truncation error.
    //
    // `ln` is defined across the whole positive `u64` domain, so the difference is
    // well-conditioned over every representable pair: `|k| <= 44.4`, at a relative
    // error of 1e-7 per term. No strike needs a special case.
    let k = fixed::ln(strike).sub(&fixed::ln(forward));
    let k_minus_m = k.sub(&m);
    // The smile root `sqrt((k - m)^2 + sigma^2)` is taken from a 1e18 input: both
    // squares are exact `u128` products of 1e9 values, and `sqrt_u128_down` returns
    // the 1e9-scaled root. Squaring at 1e9 instead floors each square to a whole raw
    // unit, which erases `sigma^2` once `sigma` is below ~3.2e-5 and leaves a
    // short-dated smile's vertex with percent-scale error in `w` and `w'`.
    // `|k - m| <= 44.4 + 100` and `sigma <= 100`, so the input stays under 3.1e22
    // and the root fits `u64`.
    let k_minus_m_magnitude = k_minus_m.magnitude() as u128;
    let sigma = sigma as u128;
    let sq = fixed::sqrt_u128_down(k_minus_m_magnitude * k_minus_m_magnitude + sigma * sigma) as u64;
    let sq_i64 = i64::from_u64(sq);

    let rho_km = rho.mul_scaled(&k_minus_m);
    let inner = rho_km.add(&sq_i64);
    // Non-negative for |rho| <= 1, and exactly so in fixed point: the floored root
    // is at least `|k - m|`, and the floored `rho * (k - m)` is at most that in
    // magnitude. The check is a backstop.
    if (inner.is_negative()) return (option::none(), NEGATIVE_INNER);

    let total_var = total_var(a_magnitude, a_is_negative, b, inner.magnitude());
    if (total_var.is_none()) return (option::none(), NON_POSITIVE_VARIANCE);
    let (sqrt_var, d2) = sqrt_var_d2(total_var.destroy_some(), &k);

    let slope_ratio = k_minus_m.div_scaled(&sq_i64);
    let slope = rho.add(&slope_ratio);
    // `b` is at 1e18 and `slope` at 1e9, so the product comes back down by 1e18
    // to leave `w'` at 1e9. `b <= max_svi_input * 1e9` and `|slope| <= 2e9`
    // (`|rho| <= 1e9` and `|k - m| <= sq`), so the u128 product and the u64
    // narrowing both fit.
    let scale = fixed::float_scaling!() as u128;
    let w_prime_magnitude = (b * (slope.magnitude() as u128) / (scale * scale)) as u64;
    let nd2 = fixed::normal_cdf(&d2);
    if (w_prime_magnitude == 0) return (option::some(nd2), 0);

    let correction_magnitude = fixed::mul_div_down(
        fixed::normal_pdf(&d2),
        w_prime_magnitude,
        2 * sqrt_var,
    );
    let correction = i64::from_parts(correction_magnitude, slope.is_negative());
    let adjusted = i64::from_u64(nd2).sub(&correction);
    let price = if (adjusted.is_negative()) {
        0
    } else if (adjusted.magnitude() > fixed::float_scaling!()) {
        fixed::float_scaling!()
    } else {
        adjusted.magnitude()
    };
    (option::some(price), 0)
}

/// Whether a rolled surface's minimum total variance over all strikes is
/// positive, at the 1e18 the rolled `a` and `b` are carried in.
public fun var_positive(
    a_magnitude: u128,
    a_is_negative: bool,
    b: u128,
    rho: I64,
    sigma: u64,
): bool {
    total_var(a_magnitude, a_is_negative, b, smile_inner(rho, sigma)).is_some()
}

/// Whether raw Block Scholes inputs fit Predict's pricing-safe envelope: a
/// positive spot and forward, `forward <= max_spot` and `forward <= 100 *
/// spot`, and SVI `b`, `|rho|`, `|m|`, and `sigma` within their bounds. `a`
/// carries no bound of its own: only total variance has to be positive
/// (`raw_var_ok`), and every downstream use of `a` fits its provider width.
public fun inputs_ok(spot: u64, forward: u64, b: u64, rho: I64, m: I64, sigma: u64): bool {
    // `ceil(forward / factor) <= spot` enforces `forward <= factor * spot`
    // without an overflowing multiplication.
    spot > 0 && forward > 0
        && forward <= max_spot!()
        && forward.div_ceil(max_basis_factor!()) <= spot
        && b <= max_svi_input!()
        && rho.magnitude() <= fixed::float_scaling!()
        && m.magnitude() <= max_svi_input!()
        && sigma >= min_svi_sigma!()
        && sigma <= max_svi_input!()
}

/// Whether a raw SVI tuple's minimum total variance `a + b * sigma * sqrt(1 -
/// rho^2)` is positive, compared rather than summed: `a` reaches `u64::MAX`,
/// where the sum would leave `u64`.
public fun raw_var_ok(a: I64, b: u64, rho: I64, sigma: u64): bool {
    // The smallest possible non-`a` part over all strikes: `b * sigma * sqrt(1 -
    // rho^2)`, or 0 at the `|rho| == 1` boundary.
    let min_variance_increment = fixed::mul_down(b, smile_inner(rho, sigma));
    if (a.is_negative()) {
        min_variance_increment > a.magnitude()
    } else {
        a.magnitude() > 0 || min_variance_increment > 0
    }
}

// === Fees and impact ===

/// One finite leg's trading fee: `max(bernoulli(p), min_fee) * ramp * quantity`,
/// each product rounded down. `bernoulli(p) = base_fee * sqrt(p * (1 - p))`,
/// zero at `p = 0` or `1`; the caller checks `p <= 1`. The ramp is 1 at or
/// beyond `window_ms` to expiry and rises linearly to `max_multiplier` at
/// expiry, rounded down so the trader keeps the ramp dust.
public fun leg_fee(
    base_fee: u64,
    min_fee: u64,
    window_ms: u64,
    max_multiplier: u64,
    probability: u64,
    quantity: u64,
    time_to_expiry_ms: u64,
): u64 {
    let raw_fee = if (probability == 0 || probability == fixed::float_scaling!()) {
        0
    } else {
        let variance = fixed::mul_down(probability, fixed::float_scaling!() - probability);
        fixed::mul_down(base_fee, fixed::sqrt_down(variance))
    };
    let multiplier = if (time_to_expiry_ms >= window_ms) {
        fixed::float_scaling!()
    } else {
        // = (max_multiplier - 1) * elapsed / window, round down.
        fixed::float_scaling!() + fixed::mul_div_down(
            max_multiplier - fixed::float_scaling!(),
            window_ms - time_to_expiry_ms,
            window_ms,
        )
    };
    fixed::mul_down(fixed::mul_down(raw_fee.max(min_fee), multiplier), quantity)
}

/// The inventory-impact potential of `liability`: the marginal rate rises
/// linearly from zero to `max_rate` over `scale`, then stays capped:
///
/// `phi(L) = r_max * L^2 / (2B)` for `L <= B`
/// `phi(L) = phi(B) + r_max * (L - B)` for `L > B`.
///
/// Defined by this exact sequence of rounded integer operations, so charges and
/// rebates, which always subtract two evaluations, telescope exactly.
public fun potential(max_rate: u64, scale: u64, liability: u64): u64 {
    if (max_rate == 0 || liability == 0) return 0;
    let capped_liability = liability.min(scale);
    let utilization = fixed::mul_div_down(capped_liability, fixed::float_scaling!(), scale);
    let marginal_rate = fixed::mul_down(max_rate, utilization);
    let potential_at_capped_liability = fixed::mul_down(marginal_rate, capped_liability) / 2;
    if (liability <= scale) return potential_at_capped_liability;
    potential_at_capped_liability + fixed::mul_down(max_rate, liability - scale)
}

/// The largest whole number of `lot`s, at most `max_lots`, whose premium
/// `mul_down(probability, quantity)` fits `max_premium`, as a quantity. The probe
/// is the premium mint admission charges, so the result is exact, and an
/// oversized budget saturates at `max_lots` instead of aborting.
public fun max_qty(probability: u64, max_premium: u64, lot: u64, max_lots: u64): u64 {
    let mut lo = 0;
    let mut hi = max_lots;
    while (lo < hi) {
        let mid = (lo + hi + 1) / 2;
        if (fixed::mul_down(probability, mid * lot) <= max_premium) {
            lo = mid
        } else {
            hi = mid - 1
        }
    };
    lo * lot
}

/// The builder fee on a trade with a builder code: `fee_amount * multiplier`,
/// capped at `quantity * max_rate`, each rounded down.
public fun builder_fee(fee_amount: u64, quantity: u64, multiplier: u64, max_rate: u64): u64 {
    fixed::mul_down(fee_amount, multiplier).min(fixed::mul_down(quantity, max_rate))
}

// === Order-flow cash need ===

/// Exact-quantity mint cash need: `ceil(quantity * (1 - p)) + 1`, where `p` is
/// the market's minimum entry probability: a fill pays at least `p` per contract
/// into market cash.
public fun need_qty(quantity: u64, p: u64): u64 {
    fixed::mul_div_up(quantity, fixed::float_scaling!() - p, fixed::float_scaling!()) + 1
}

/// Budget mint cash need: `ceil((budget + 1) * (1 / p - 1)) + 1`. The
/// `budget + 1` covers premiums rounding down, which lets a fill buy up to `1 /
/// p` raw units more than `budget / p`.
public fun need_budget(budget: u64, p: u64): u64 {
    fixed::mul_div_up(budget + 1, fixed::float_scaling!() - p, p) + 1
}

/// Sell cash need: `ceil(close_quantity * (1 - lambda)) + 1`. A close lowers
/// payout liability by at least `lambda * close_quantity` and pays at most
/// `close_quantity`.
public fun need_sell(close_quantity: u64, lambda: u64): u64 {
    fixed::mul_div_up(close_quantity, fixed::float_scaling!() - lambda, fixed::float_scaling!()) + 1
}

// === Order IDs ===

/// Decode a packed Predict order ID into `(lower_tick, higher_tick, quantity)`,
/// with the quantity in USDC base units. For the order-flow companion's sell
/// sizing and remainder checks over order IDs Predict issued: it validates
/// nothing. The layout is Predict's frozen order-ID encoding: 30-bit ticks at
/// bits 70 and 40, and a 32-bit count of 10_000-unit lots at bit 100.
public fun order_terms(order_id: u256): (u64, u64, u64) {
    let tick_mask = (1u256 << 30) - 1;
    (
        ((order_id >> 70) & tick_mask) as u64,
        ((order_id >> 40) & tick_mask) as u64,
        (((order_id >> 100) & ((1u256 << 32) - 1)) as u64) * 10_000,
    )
}

// === Private Functions ===

/// Total variance `w = a + b * inner`, carried at `u128` / 1e18, or `none` when
/// `w <= 0`, which pricing cannot price because it divides by `sqrt(w)`.
///
/// `a_magnitude` and `b` arrive already rolled down and already at 1e18, so the
/// whole variance assembly stays in that domain: narrowing either back to 1e9
/// discards the entire low-variance signal, because a five-minute surface has
/// `w ~ 1e-8` — about ten raw units at 1e9. `inner` is 1e9-scaled, so `b * inner`
/// comes back down by 1e9 to land at 1e18.
fun total_var(a_magnitude: u128, a_is_negative: bool, b: u128, inner: u64): Option<u128> {
    let increment = b * (inner as u128) / (fixed::float_scaling!() as u128);
    if (a_is_negative) {
        if (increment > a_magnitude) option::some(increment - a_magnitude) else option::none()
    } else if (increment + a_magnitude > 0) {
        option::some(increment + a_magnitude)
    } else {
        option::none()
    }
}

/// `sqrt(w)` and `d2` for a positive total variance `w` at 1e18. `sqrt_u128_down`
/// of a 1e18 value is its 1e9-scaled root, so `sqrt(w)` returns at the scale the
/// rest of the formula reads. Returns `(sqrt(w), d2)`.
fun sqrt_var_d2(total_var: u128, k: &I64): (u64, I64) {
    let scale = fixed::float_scaling!() as u128;
    let sqrt_var = fixed::sqrt_u128_down(total_var) as u64;

    // d2 = -(k + w/2) / sqrt(w). The numerator stays at 1e18 and the divisor is
    // the 1e9-scaled root, so the quotient lands at 1e9 with its sign tracked by
    // hand — I64 cannot hold either operand at 1e18.
    let k_scaled = (k.magnitude() as u128) * scale;
    let half_var = total_var / 2;
    let (numerator, numerator_negative) = if (!k.is_negative()) {
        (k_scaled + half_var, false)
    } else if (half_var >= k_scaled) {
        (half_var - k_scaled, false)
    } else {
        (k_scaled - half_var, true)
    };
    // `normal_cdf` / `normal_pdf` saturate beyond |x| > 8, so cap the magnitude
    // there: the quotient grows without bound as w -> 0 and would otherwise
    // overflow the u64 cast.
    let saturation = 8 * scale + 1;
    let d2_magnitude = numerator / (sqrt_var as u128);
    let d2_magnitude = if (d2_magnitude > saturation) saturation else d2_magnitude;

    (sqrt_var, i64::from_parts(d2_magnitude as u64, !numerator_negative))
}

/// The smallest SVI inner term `rho*x + sqrt(x^2 + sigma^2)` over all `x`:
/// `sigma * sqrt(1 - rho^2)` at 1e9, or 0 at the `|rho| == 1` boundary.
fun smile_inner(rho: I64, sigma: u64): u64 {
    let rho_mag = rho.magnitude();
    if (rho_mag == fixed::float_scaling!()) return 0;

    let one_minus_rho_squared = fixed::float_scaling!() - fixed::mul_down(rho_mag, rho_mag);
    fixed::mul_down(sigma, fixed::sqrt_down(one_minus_rho_squared))
}

// === Test-Only Functions ===

#[test_only]
public fun total_var_for_testing(
    a_magnitude: u128,
    a_is_negative: bool,
    b: u128,
    inner: u64,
): Option<u128> {
    total_var(a_magnitude, a_is_negative, b, inner)
}

#[test_only]
public fun sqrt_var_d2_for_testing(total_var: u128, k: &I64): (u64, I64) {
    sqrt_var_d2(total_var, k)
}
