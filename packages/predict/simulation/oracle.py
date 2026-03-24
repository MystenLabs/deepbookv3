"""
Block Scholes Oracle - SVI-based volatility surface oracle.

Mirror of oracle.move + math.move — same data structures, same algorithms.
Useful for off-chain simulation and testing.
"""

import math as pymath
from dataclasses import dataclass
from typing import Optional

FLOAT_SCALING = 1_000_000_000
MS_PER_YEAR = 31_536_000_000


# === Fixed-point math (mirrors deepbook::math) ===

def mul(x: int, y: int) -> int:
    return (x * y) // FLOAT_SCALING


def div(x: int, y: int) -> int:
    return (x * FLOAT_SCALING) // y


def sqrt(x: int) -> int:
    return pymath.isqrt(x * FLOAT_SCALING)


# === Signed arithmetic helpers (mirrors predict::math) ===

def add_signed(a: int, a_neg: bool, b: int, b_neg: bool) -> tuple[int, bool]:
    if a_neg == b_neg:
        s = a + b
        return (0, False) if s == 0 else (s, a_neg)
    if a >= b:
        d = a - b
        return (0, False) if d == 0 else (d, a_neg)
    d = b - a
    return (0, False) if d == 0 else (d, b_neg)


def sub_signed(a: int, a_neg: bool, b: int, b_neg: bool) -> tuple[int, bool]:
    return add_signed(a, a_neg, b, not b_neg)


def mul_signed(a: int, a_neg: bool, b: int, b_neg: bool) -> tuple[int, bool]:
    product = mul(a, b)
    if product == 0:
        return (0, False)
    return (product, a_neg != b_neg)


# === ln / exp / normal_cdf (mirrors predict::math) ===

LN2 = 693_147_181


def _normalize(x: int) -> tuple[int, int]:
    y = x
    n = 0
    if (y >> 32) >= FLOAT_SCALING:
        y >>= 32; n += 32
    if (y >> 16) >= FLOAT_SCALING:
        y >>= 16; n += 16
    if (y >> 8) >= FLOAT_SCALING:
        y >>= 8; n += 8
    if (y >> 4) >= FLOAT_SCALING:
        y >>= 4; n += 4
    if (y >> 2) >= FLOAT_SCALING:
        y >>= 2; n += 2
    if (y >> 1) >= FLOAT_SCALING:
        y >>= 1; n += 1
    return (y, n)


def _log_ratio(y: int) -> int:
    return div(y - FLOAT_SCALING, y + FLOAT_SCALING)


def _ln_series(z: int) -> int:
    z2 = mul(z, z)
    term = z
    s = 0
    k = 1
    while k <= 13:
        s += div(term, k * FLOAT_SCALING)
        term = mul(term, z2)
        k += 2
    return mul(2 * FLOAT_SCALING, s)


def ln(x: int) -> tuple[int, bool]:
    assert x > 0
    if x == FLOAT_SCALING:
        return (0, False)
    if x < FLOAT_SCALING:
        inv = div(FLOAT_SCALING, x)
        result, _ = ln(inv)
        return (result, True)
    y, n = _normalize(x)
    z = _log_ratio(y)
    ln_y = _ln_series(z)
    return (n * LN2 + ln_y, False)


def _reduce_exp(x: int) -> tuple[int, int]:
    n = x // LN2
    r = x - n * LN2
    return (r, n)


def _exp_series(r: int) -> int:
    s = FLOAT_SCALING
    term = FLOAT_SCALING
    k = 1
    while k <= 12:
        term = div(mul(term, r), k * FLOAT_SCALING)
        if term == 0:
            break
        s += term
        k += 1
    return s


def exp(x: int, x_negative: bool) -> int:
    if x == 0:
        return FLOAT_SCALING
    r, n = _reduce_exp(x)
    exp_r = _exp_series(r)

    if x_negative:
        result = div(FLOAT_SCALING, exp_r)
        if n >= 32:
            result >>= 32
            if result == 0:
                return 0
            n -= 32
        if n >= 16:
            result >>= 16
            if result == 0:
                return 0
            n -= 16
        if n >= 8:
            result >>= 8
            if result == 0:
                return 0
            n -= 8
        if n >= 4:
            result >>= 4
            if result == 0:
                return 0
            n -= 4
        if n >= 2:
            result >>= 2
            if result == 0:
                return 0
            n -= 2
        if n >= 1:
            result >>= 1
        return result
    else:
        result = exp_r
        if n >= 32:
            result <<= 32; n -= 32
        if n >= 16:
            result <<= 16; n -= 16
        if n >= 8:
            result <<= 8; n -= 8
        if n >= 4:
            result <<= 4; n -= 4
        if n >= 2:
            result <<= 2; n -= 2
        if n >= 1:
            result <<= 1
        return result


def _cdf_t(x: int) -> int:
    return div(FLOAT_SCALING, FLOAT_SCALING + mul(231_641_900, x))


def _cdf_pdf(x: int) -> int:
    x_sq_half = mul(x, x) // 2
    return mul(exp(x_sq_half, True), 398_942_280)


def _cdf_poly(t: int) -> int:
    t2 = mul(t, t)
    t3 = mul(t2, t)
    t4 = mul(t3, t)
    t5 = mul(t4, t)
    pos = mul(319_381_530, t) + mul(1_781_477_937, t3) + mul(1_330_274_429, t5)
    neg = mul(356_563_782, t2) + mul(1_821_255_978, t4)
    return pos - neg


def normal_cdf(x: int, x_negative: bool) -> int:
    if x > 8 * FLOAT_SCALING:
        return 0 if x_negative else FLOAT_SCALING
    t = _cdf_t(x)
    poly = _cdf_poly(t)
    pdf = _cdf_pdf(x)
    complement = mul(pdf, poly)
    cdf = max(FLOAT_SCALING - complement, 0)
    return (FLOAT_SCALING - cdf) if x_negative else cdf


# === Oracle structs ===

@dataclass
class SVIParams:
    a: int = 0
    b: int = 0
    rho: int = 0
    rho_negative: bool = False
    m: int = 0
    m_negative: bool = False
    sigma: int = 0


@dataclass
class PriceData:
    spot: int = 0
    forward: int = 0


@dataclass
class CurvePoint:
    strike: int
    up_price: int
    dn_price: int


class OracleSVI:
    def __init__(
        self,
        underlying_asset: str,
        expiry: int,
        svi: Optional[SVIParams] = None,
        prices: Optional[PriceData] = None,
        risk_free_rate: int = 0,
        timestamp: int = 0,
    ):
        self.underlying_asset = underlying_asset
        self.expiry = expiry
        self.active = False
        self.prices = prices or PriceData()
        self.svi = svi or SVIParams()
        self.risk_free_rate = risk_free_rate
        self.timestamp = timestamp
        self.settlement_price: Optional[int] = None

    def is_settled(self) -> bool:
        return self.settlement_price is not None

    def settle(self, price: int):
        self.settlement_price = price
        self.active = False

    def _compute_nd2(self, strike: int, is_up: bool) -> int:
        forward = self.prices.forward

        # SVI: compute total variance from log-moneyness
        k, k_neg = ln(div(strike, forward))
        k_minus_m, km_neg = sub_signed(k, k_neg, self.svi.m, self.svi.m_negative)
        sq = sqrt(mul(k_minus_m, k_minus_m) + mul(self.svi.sigma, self.svi.sigma))
        rho_km, rho_km_neg = mul_signed(
            self.svi.rho, self.svi.rho_negative, k_minus_m, km_neg
        )
        inner, inner_neg = add_signed(rho_km, rho_km_neg, sq, False)
        assert not inner_neg, "ECannotBeNegative"
        total_var = self.svi.a + mul(self.svi.b, inner)

        # d2 = (-k - total_var/2) / sqrt(total_var), then N(±d2)
        sqrt_var = sqrt(total_var)
        d2, d2_neg = sub_signed(k, not k_neg, total_var // 2, False)
        d2 = div(d2, sqrt_var)
        cdf_neg = d2_neg if is_up else (not d2_neg)

        return normal_cdf(d2, cdf_neg)

    def _compute_discount(self, now: int) -> int:
        if now >= self.expiry:
            return FLOAT_SCALING
        tte_ms = self.expiry - now
        t = div(tte_ms, MS_PER_YEAR)
        rt = mul(self.risk_free_rate, t)
        return exp(rt, True)

    def _eval_strike(self, strike: int, discount: int) -> CurvePoint:
        nd2 = self._compute_nd2(strike, True)
        up = mul(discount, nd2)
        dn = max(discount - up, 0)
        return CurvePoint(strike=strike, up_price=up, dn_price=dn)

    def get_binary_price(self, strike: int, is_up: bool, now: int) -> int:
        if self.settlement_price is not None:
            up_wins = self.settlement_price > strike
            won = up_wins if is_up else not up_wins
            return FLOAT_SCALING if won else 0

        nd2 = self._compute_nd2(strike, is_up)
        discount = self._compute_discount(now)
        return mul(discount, nd2)

    def build_curve(
        self, min_strike: int, max_strike: int, now: int
    ) -> list[CurvePoint]:
        if self.is_settled():
            settlement = self.settlement_price
            return [
                CurvePoint(settlement - 1, FLOAT_SCALING, 0),
                CurvePoint(settlement, 0, FLOAT_SCALING),
            ]

        sample_limit = 50
        discount = self._compute_discount(now)

        if min_strike == max_strike:
            return [self._eval_strike(min_strike, discount)]

        forward = self.prices.forward
        points = [self._eval_strike(min_strike, discount)]
        used = 1

        if min_strike < forward < max_strike:
            points.append(self._eval_strike(forward, discount))
            used += 1
        points.append(self._eval_strike(max_strike, discount))
        used += 1

        min_interval = 1_000_000  # min_curve_interval

        while used < sample_limit:
            best_score = 0
            best_idx = 0

            for i in range(len(points) - 1):
                interval = points[i + 1].strike - points[i].strike
                if interval < min_interval:
                    continue

                if 0 < i < len(points) - 2:
                    sum_ends = points[i - 1].up_price + points[i + 1].up_price
                    twice_mid = 2 * points[i].up_price
                    score = mul(abs(sum_ends - twice_mid), interval)
                else:
                    score = mul(
                        abs(points[i].up_price - points[i + 1].up_price), interval
                    )

                if score > best_score:
                    best_score = score
                    best_idx = i

            if best_score == 0:
                break

            mid_strike = (points[best_idx].strike + points[best_idx + 1].strike) // 2
            new_point = self._eval_strike(mid_strike, discount)
            points.insert(best_idx + 1, new_point)
            used += 1

        return points


if __name__ == "__main__":
    # Quick sanity check: ETH-like oracle
    svi = SVIParams(
        a=40_000_000,       # 0.04
        b=300_000_000,      # 0.3
        rho=200_000_000,    # 0.2
        rho_negative=True,  # negative skew
        m=50_000_000,       # 0.05
        m_negative=False,
        sigma=100_000_000,  # 0.1
    )
    prices = PriceData(
        spot=2_000 * FLOAT_SCALING,
        forward=2_000 * FLOAT_SCALING,
    )
    now = 1_000_000_000  # 1B ms
    expiry = now + 7 * 24 * 3600 * 1000  # 1 week out

    oracle = OracleSVI(
        underlying_asset="ETH",
        expiry=expiry,
        svi=svi,
        prices=prices,
        risk_free_rate=50_000_000,  # 5%
        timestamp=now,
    )

    # Test binary prices at various strikes
    for strike_usd in [1800, 1900, 2000, 2100, 2200]:
        strike = strike_usd * FLOAT_SCALING
        up = oracle.get_binary_price(strike, True, now)
        dn = oracle.get_binary_price(strike, False, now)
        print(
            f"Strike={strike_usd}: UP={up / FLOAT_SCALING:.4f} "
            f"DN={dn / FLOAT_SCALING:.4f} SUM={up + dn}"
        )

    # Test curve building
    curve = oracle.build_curve(1800 * FLOAT_SCALING, 2200 * FLOAT_SCALING, now)
    print(f"\nCurve has {len(curve)} points")
    for p in curve[:5]:
        print(
            f"  strike={p.strike / FLOAT_SCALING:.1f} "
            f"up={p.up_price / FLOAT_SCALING:.4f} "
            f"dn={p.dn_price / FLOAT_SCALING:.4f}"
        )
    if len(curve) > 5:
        print(f"  ... ({len(curve) - 5} more)")
