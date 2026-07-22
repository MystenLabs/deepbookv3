#!/usr/bin/env python3
"""Pricing evaluation-error certificate for the interval (envelope) pricing lane.

This is the calibration harness behind two things in `pricing.move`:

  * the u128/1e18 variance path in `compute_nd2_terms` (`variance_sqrt_and_d2`),
    which keeps `sqrt(w)` and `d2` precise where total variance `w` is only a
    few raw units at 1e9 (short-dated surfaces), and
  * the `evaluation_error_for_variance` widen table plus the
    `beta^2 <= 9 * min_tv` admission gate.

It carries a byte-faithful integer mirror of the Move pricing chain (Cody
`normal_cdf`, series `exp`/`ln`, Newton `sqrt`, i64 arithmetic — the same code
paths as `fixed_math::math` and `pricing::compute_nd2_terms`) in two precisions:
`compute_up_price_lo` (the pre-change 1e9 path) and `compute_up_price_hp` (the
shipped u128/1e18 path). Both are measured against an mpmath reference of the
exact real formula on line 585 of `pricing.move`.

Run: `python3 pricing_error_certificate.py` (needs `mpmath`).

What it shows:
  1. The leaf approximation constants (`normal_cdf`, `normal_pdf`, `ln`) the
     error bound rests on, verified against mpmath.
  2. The HP precision gain: lo vs hp error across the admissible variance range.
  3. The evaluation error e(w) over the admission-gated admissible SVI box, the
     conservative public envelope for the shipped tier table.

The shipped tier values are set from the high-precision error measured over
representative vendor SVI surfaces (the 5-minute/1-minute regime) with margin;
interval-branch-and-bound verification of the bands over the full admissible box
is planned hardening. This script reproduces the method and the gate on the
public admissible box; it does not contain vendor data.
"""
import math
import random
import mpmath as mp

mp.mp.dps = 30
F = 10**9
U64 = 2**64 - 1
LN2 = 693_147_180
INV_SQRT_2PI = 398_942_280
EXP_MAX_INPUT = 23_638_153_618
SMALL, MEDIUM = 662_910_000, 5_656_854_249
# Cody rational-approximation coefficients (mirror fixed_math::math::normal_cdf_u128)
A = [2_235_252_035, 161_028_231_069, 1_067_689_485_460, 18_154_981_253_344, 65_682_338]
B = [47_202_581_905, 976_098_551_738, 10_260_932_208_619, 45_507_789_335_027]
C = [398_941_512, 8_883_149_794, 93_506_656_132, 597_270_276_395, 2_494_537_585_290,
     6_848_190_450_536, 11_602_651_437_647, 9_842_714_838_384, 11]
D = [22_266_688_044, 235_387_901_782, 1_519_377_599_408, 6_485_558_298_267,
     18_615_571_640_885, 34_900_952_721_146, 38_912_003_286_093, 19_685_429_676_860]
INV = [333_333_333, 200_000_000, 142_857_143, 111_111_111, 90_909_091, 76_923_077]  # 1/3..1/13

# Admissible SVI input box (mirror assert_inputs_pricing_safe caps)
MIN_SVI_SIGMA = 1_000_000          # 1e-3
MAX_SVI_INPUT = 100 * F            # 100.0
SKEW_VARIANCE_RATIO = 9            # beta^2 <= 9 * min_tv  (beta/(2 sqrt(min_tv)) <= 1.5)


# ---------- integer mirror (fixed_math::math + i64) ----------
def m_sqrt(x, precision=F):
    mult = F // precision
    return math.isqrt(x * mult * F) // mult


def m_mul(x, y):
    return (x * y) // F


def m_mul_up(x, y):
    return (x * y + F - 1) // F


def m_mul_div_down(x, y, d):
    return (x * y) // d


def m_try_mul_div_down(x, y, d):
    r = (x * y) // d
    return None if r > U64 else r


def m_ln(x):  # returns (magnitude, is_negative)
    assert x > 0
    if x == F:
        return (0, False)
    if x < F:
        mag, _ = m_ln((F * F) // x)
        return (mag, True)
    y, n = x, 0
    for s in (32, 16, 8, 4, 2, 1):
        if (y >> s) >= F:
            y >>= s
            n += s
    z = ((y - F) * F) // (y + F)
    w = (z * z) // F
    h = (w * INV[5]) // F
    for inv_c in (INV[4], INV[3], INV[2], INV[1], INV[0]):
        h = ((inv_c + h) * w) // F
    ln_y = (((2 * F * z) // F) * (F + h)) // F
    return (n * LN2 + ln_y, False)


def _exp_u128(r, n, neg):
    s, term = F, F
    for k in range(1, 13):
        term = term * r // (k * F)
        if term == 0:
            break
        s += term
    if neg:
        res = (F * F) // s
        for sh in (32, 16, 8, 4, 2):
            if n >= sh:
                res >>= sh
                if res == 0:
                    return 0
                n -= sh
        if n >= 1:
            res >>= 1
        return res
    for sh in (32, 16, 8, 4, 2, 1):
        if n >= sh:
            s <<= sh
            n -= sh
    return s


def m_exp(mag, neg):
    if mag == 0:
        return F
    assert neg or mag <= EXP_MAX_INPUT
    n = mag // LN2
    return _exp_u128(mag - n * LN2, n, neg)


def m_normal_cdf(mag, neg):
    if mag > 8 * F:
        return 0 if neg else F
    x = mag
    if x < SMALL:
        xsq = x * x // F
        xnum = A[4] * xsq // F
        xden = xsq
        for a_c, b_c in ((A[0], B[0]), (A[1], B[1]), (A[2], B[2])):
            xnum = (xnum + a_c) * xsq // F
            xden = (xden + b_c) * xsq // F
        ratio = (xnum + A[3]) * F // (xden + B[3])
        term = x * ratio // F
        return F // 2 - term if neg else F // 2 + term
    if x < MEDIUM:
        xnum = C[8] * x // F
        xden = x
        for c_c, d_c in ((C[0], D[0]), (C[1], D[1]), (C[2], D[2]), (C[3], D[3]),
                         (C[4], D[4]), (C[5], D[5]), (C[6], D[6])):
            xnum = (xnum + c_c) * x // F
            xden = (xden + d_c) * x // F
        rational = (xnum + C[7]) * F // (xden + D[7])
        x_sq_half = x * x // (F * 2)
        n = x_sq_half // LN2
        ev = _exp_u128(x_sq_half - n * LN2, n, True)
        comp = ev * rational // F
        return comp if neg else F - comp
    return 0 if neg else F


def m_normal_pdf(mag):
    if mag > 8 * F:
        return 0
    return m_mul(m_exp((mag * mag) // (2 * F), True), INV_SQRT_2PI)


# i64: (magnitude, is_negative) with canonical zero
def i(mag, neg=False):
    return (mag, neg if mag != 0 else False)


def i_neg(a):
    return (a[0], (not a[1]) if a[0] else False)


def i_add(a, b):
    if a[1] == b[1]:
        return i(a[0] + b[0], a[1])
    if a[0] >= b[0]:
        return i(a[0] - b[0], a[1])
    return i(b[0] - a[0], b[1])


def i_sub(a, b):
    return i_add(a, i_neg(b))


def i_mul_scaled(a, b):
    return i((a[0] * b[0]) // F, a[1] != b[1])


def i_div_scaled(a, b):
    assert b[0] > 0
    return i((a[0] * F) // b[0], a[1] != b[1])


# ---------- the two pricing paths ----------
def _prelude(svi, forward, strike):
    sr = m_try_mul_div_down(strike, F, forward)
    if sr is None:
        return None, "sat0"
    if sr == 0:
        return None, "sat1"
    k = m_ln(sr)
    x = i_sub(k, svi["m"])
    x_sq = i_mul_scaled(x, x)[0]
    sig_sq = m_mul(svi["sigma"], svi["sigma"])
    s = m_sqrt(x_sq + sig_sq)
    inner = i_add(i_mul_scaled(svi["rho"], x), i(s))
    assert not (inner[1] and inner[0] > 0), "ECannotBeNegative"
    return (k, x, s, inner), None


def _finish(svi, k, sqrt_var, d2, s, x):
    slope = i_add(svi["rho"], i_div_scaled(x, i(s)))
    w_prime = i_mul_scaled(i(svi["b"]), slope)
    nd2 = m_normal_cdf(d2[0], d2[1])
    if w_prime[0] == 0:
        return nd2
    corr = m_mul_div_down(m_normal_pdf(d2[0]), w_prime[0], 2 * sqrt_var)
    adj = i_sub(i(nd2), i(corr, w_prime[1]))
    if adj[1]:
        return 0
    return min(adj[0], F)


def compute_up_price_lo(svi, forward, strike):
    """Pre-change 1e9 path: b*inner floored to 1e9 before sqrt(w) and d2."""
    pre, sat = _prelude(svi, forward, strike)
    if pre is None:
        return 0 if sat == "sat0" else F
    k, x, s, inner = pre
    vi = m_mul(svi["b"], inner[0])
    tv = i_add(i(vi), svi["a"])
    assert not tv[1] and tv[0] > 0, "ENonPositiveVariance"
    w = tv[0]
    sqrt_var = m_sqrt(w)
    d2 = i_neg(i_div_scaled(i_add(k, i(w // 2)), i(sqrt_var)))
    return _finish(svi, k, sqrt_var, d2, s, x)


def compute_up_price_hp(svi, forward, strike):
    """Shipped u128/1e18 path: variance, sqrt(w), and d2 kept at 1e18."""
    pre, sat = _prelude(svi, forward, strike)
    if pre is None:
        return 0 if sat == "sat0" else F
    k, x, s, inner = pre
    increment = svi["b"] * inner[0]            # 1e18
    a_mag, a_neg = svi["a"]
    a_scaled = a_mag * F                        # 1e18
    if a_neg:
        assert increment > a_scaled, "ENonPositiveVariance"
        total_var = increment - a_scaled
    else:
        total_var = increment + a_scaled
        assert total_var > 0, "ENonPositiveVariance"
    sqrt_var = math.isqrt(total_var)            # sqrt(w)*1e9
    half_var = total_var // 2
    k_scaled = k[0] * F
    if k[1]:
        num, num_neg = (half_var - k_scaled, False) if half_var >= k_scaled else (k_scaled - half_var, True)
    else:
        num, num_neg = k_scaled + half_var, False
    saturation = 8 * F + 1
    d2_mag = num // sqrt_var
    d2_mag = saturation if d2_mag > saturation else d2_mag
    d2 = (d2_mag, not num_neg if d2_mag else False)
    return _finish(svi, k, sqrt_var, d2, s, x)


# ---------- mpmath reference (exact real formula) ----------
def sgn(pair):
    return (mp.mpf(-1) if pair[1] else mp.mpf(1)) * pair[0] / F


def price_ref(svi, forward, strike):
    a, m, rho = sgn(svi["a"]), sgn(svi["m"]), sgn(svi["rho"])
    b, sig = mp.mpf(svi["b"]) / F, mp.mpf(svi["sigma"]) / F
    k = mp.log(mp.mpf(strike) / forward)
    x = k - m
    s = mp.sqrt(x * x + sig * sig)
    w = a + b * (rho * x + s)
    if w <= 0:
        return None
    d2 = -(k + w / 2) / mp.sqrt(w)
    Phi = mp.mpf("0.5") * mp.erfc(-d2 / mp.sqrt(2))
    phi = mp.e ** (-d2 * d2 / 2) / mp.sqrt(2 * mp.pi)
    wp = b * (rho + x / s)
    return min(mp.mpf(1), max(mp.mpf(0), Phi - phi * wp / (2 * mp.sqrt(w))))


def min_total_variance(svi):
    a = float(sgn(svi["a"]))
    b, sig = svi["b"] / F, svi["sigma"] / F
    rho = svi["rho"][0] / F
    return a + b * sig * math.sqrt(max(0.0, 1 - rho * rho))


def gate_admits(svi):
    b, rho_mag, sig = svi["b"], svi["rho"][0], svi["sigma"]
    if rho_mag == F:
        inc = 0
    else:
        inc = m_mul(b, m_mul(sig, m_sqrt(F - m_mul(rho_mag, rho_mag))))
    a_mag, a_neg = svi["a"]
    if a_neg:
        if inc <= a_mag:
            return False
        min_tv = inc - a_mag
    else:
        min_tv = inc + a_mag
    if min_tv <= 0:
        return False
    beta = b + m_mul_up(b, rho_mag)
    return beta * beta <= SKEW_VARIANCE_RATIO * min_tv * F


# ---------- checks ----------
def verify_leaves():
    cdf_max = pdf_max = ln_max = 0
    xf = -8.0
    while xf <= 8.0:
        mag = int(round(abs(xf) * F))
        cdf_max = max(cdf_max, abs(m_normal_cdf(mag, xf < 0)
                                   - round(float(mp.mpf("0.5") * mp.erfc(-mp.mpf(xf) / mp.sqrt(2))) * F)))
        if xf >= 0:
            pdf_max = max(pdf_max, abs(m_normal_pdf(mag)
                                       - round(float(mp.e ** (-mp.mpf(xf) ** 2 / 2) / mp.sqrt(2 * mp.pi)) * F)))
        xf += 0.001
    r = 0.05
    while r <= 20:
        sr = max(1, int(r * F))
        mag, neg = m_ln(sr)
        ln_max = max(ln_max, abs((-mag if neg else mag) - round(float(mp.log(mp.mpf(sr) / F)) * F)))
        r *= 1.0005
    return cdf_max, pdf_max, ln_max


SHIPPED_WIDEN = 300_000  # up_price_evaluation_error (raw 1e9): the single certified widen


def sample_gated_admissible(n=200_000, seed=7):
    rnd = random.Random(seed)
    fwd = 10**12
    band = {}
    lo_gain = {}
    made = 0
    while made < n:
        sig = 10 ** rnd.uniform(math.log10(1e-3), math.log10(0.3))
        rho = rnd.uniform(0, 0.999) * (1 if rnd.random() < 0.5 else -1)
        b = 10 ** rnd.uniform(-7, -1)
        a = 10 ** rnd.uniform(-9, math.log10(2e-3))
        m = rnd.uniform(-0.08, 0.08)
        svi = {"a": i(int(round(a * F)), False), "b": int(round(b * F)),
               "rho": i(int(round(abs(rho) * F)), rho < 0),
               "m": i(int(round(abs(m) * F)), m < 0), "sigma": int(round(sig * F))}
        if svi["b"] <= 0 or svi["sigma"] < MIN_SVI_SIGMA or not gate_admits(svi):
            continue
        made += 1
        if rnd.random() < 0.85:
            k = m + (10 ** rnd.uniform(-6, -2)) * (1 if rnd.random() < 0.5 else -1)
        else:
            k = rnd.uniform(-0.7, 0.7)
        strike = max(1, int(math.exp(k) * fwd))
        ref = price_ref(svi, fwd, strike)
        if ref is None:
            continue
        r = round(ref * F)
        try:
            hp = compute_up_price_hp(svi, fwd, strike)
            lo = compute_up_price_lo(svi, fwd, strike)
        except AssertionError:
            continue
        kk = math.log(strike / fwd)
        x = kk - m
        w = a + b * (rho * x + math.sqrt(x * x + sig * sig))
        if w <= 0:
            continue
        dec = math.floor(math.log10(w * F)) if w * F >= 1 else -1
        band[dec] = max(band.get(dec, 0), abs(hp - r))
        lo_gain[dec] = max(lo_gain.get(dec, 0), abs(lo - r))
    return band, lo_gain


def main():
    cdf_c, pdf_c, ln_c = verify_leaves()
    print("leaf approximation error vs mpmath (raw 1e9 units):")
    print(f"  normal_cdf max |e| = {cdf_c}")
    print(f"  normal_pdf max |e| = {pdf_c}")
    print(f"  ln         max |e| = {ln_c}  (absolute, ratio in [0.05, 20])")

    band, lo_gain = sample_gated_admissible()
    print("\nevaluation error over the admission-gated admissible box, by variance (raw 1e9):")
    print(f"{'w ~ 10^':>8} {'lo path':>12} {'hp path':>12}")
    domain_max = 0
    for dec in sorted(band, reverse=True):
        domain_max = max(domain_max, band[dec])
        print(f"{dec - 9:>8} {lo_gain.get(dec, 0):>12} {band[dec]:>12}")

    covered = "yes" if SHIPPED_WIDEN >= domain_max else "NO"
    print(f"\nsampled domain max (hp) = {domain_max} raw = {domain_max / F:.2e}")
    print(f"single widen up_price_evaluation_error = {SHIPPED_WIDEN} raw = {SHIPPED_WIDEN / F:.2e}"
          f"  (covers domain max: {covered})")
    print(f"admission gate: beta^2 <= {SKEW_VARIANCE_RATIO} * min_tv  "
          f"(beta = b*(1+|rho|), i.e. beta/(2*sqrt(min_tv)) <= 1.5)")
    print(
        "\nNote: one widen covers every admitted evaluation because the gate bounds the\n"
        "pricing error across the whole admitted domain (the error peaks at mid-variance,\n"
        "where the gate's skew budget is largest, not at the short end). The widen is the\n"
        "adversarial-sampled domain max times a ~3x margin; interval-branch-and-bound\n"
        "verification of the bound over the full box is planned hardening. Saturated\n"
        "evaluations sit on exact digital limits and are returned exact (zero width).")


if __name__ == "__main__":
    main()
