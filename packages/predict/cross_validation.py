#!/usr/bin/env python3
"""
Cross-validation harness for DeepBook Predict binary option pricing.

Computes prices using the same mathematical path as the Move smart contract,
outputting all values in FLOAT_SCALING (1e9) integer format for Move unit tests.

Usage: python3 cross_validation.py
"""

from math import exp, log, sqrt

from scipy.stats import norm

FLOAT_SCALING = 1_000_000_000
MS_PER_YEAR = 31_536_000_000


def to_scaled(x: float) -> int:
    return round(abs(x) * FLOAT_SCALING)


def to_price(dollars: float) -> int:
    return round(dollars * FLOAT_SCALING)


def compute_binary(
    forward, strike, svi_a, svi_b, svi_rho, svi_m, svi_sigma, risk_free_rate, tte_ms
):
    """
    Replicate Move contract compute_nd2 + get_binary_price.

    Move path:
      1. k = ln(strike/forward)
      2. SVI: total_var = a + b*(rho*(k-m) + sqrt((k-m)^2 + sigma^2))
      3. d2 = (ln(F/K) - total_var/2) / sqrt(total_var)  =  (-k - total_var/2) / sqrt(total_var)
      4. N(d2) for UP, N(-d2) for DOWN
      5. discount = e^(-r*t)
      6. price = discount * N(±d2)
    """
    k = log(strike / forward)

    k_minus_m = k - svi_m
    sq = sqrt(k_minus_m**2 + svi_sigma**2)
    inner = svi_rho * k_minus_m + sq
    total_var = svi_a + svi_b * inner

    sqrt_var = sqrt(total_var)
    d2 = (-k - total_var / 2) / sqrt_var

    nd2_up = norm.cdf(d2)
    nd2_down = norm.cdf(-d2)

    t = tte_ms / MS_PER_YEAR
    discount = exp(-risk_free_rate * t)

    price_up = discount * nd2_up
    price_down = discount * nd2_down

    return {
        "k": k,
        "total_var": total_var,
        "d2": d2,
        "nd2_up": nd2_up,
        "nd2_down": nd2_down,
        "discount": discount,
        "price_up": price_up,
        "price_down": price_down,
    }


# ============================================================
# Test Scenarios
# ============================================================

scenarios = [
    {
        "name": "Real BTC 126d",
        "svi": {
            "a": 0.01178,
            "b": 0.18226,
            "rho": -0.28796,
            "m": 0.02823,
            "sigma": 0.34312,
        },
        "spot": 67_293.0,
        "forward": 68_071.0,
        "risk_free_rate": 0.035,
        "tte_days": 126,
        "strikes": [68_071.0, 78_071.0, 58_071.0, 48_071.0],
        "labels": ["ATM", "OTM_call", "ITM_call", "Deep_ITM"],
    },
    {
        "name": "Synthetic 30d",
        "svi": {"a": 0.04, "b": 0.1, "rho": -0.3, "m": 0.0, "sigma": 0.1},
        "spot": 100_000.0,
        "forward": 100_500.0,
        "risk_free_rate": 0.05,
        "tte_days": 30,
        "strikes": [100_500.0, 110_000.0, 90_000.0],
        "labels": ["ATM", "OTM_call", "ITM_call"],
    },
]


def main():
    print("=" * 70)
    print("MATH PRIMITIVE TEST VALUES (for math_tests.move)")
    print("=" * 70)

    # ln tests
    ln_tests = [2.0, 0.5, 10.0, 1.147, 0.853]
    print("\n// --- ln tests ---")
    for x in ln_tests:
        val = log(x)
        is_neg = val < 0
        print(
            f"// ln({to_scaled(x)}) -> ({to_scaled(val)}, {str(is_neg).lower()})"
            f"  // ln({x}) = {val:.9f}"
        )

    # exp tests
    print("\n// --- exp tests ---")
    exp_cases = [
        (0.035 * 126 / 365, True, "discount scenario A"),
        (0.05 * 30 / 365, True, "discount scenario B"),
        (1.0, False, "e^1"),
        (0.5, True, "e^-0.5"),
    ]
    for x, neg, desc in exp_cases:
        result = exp(-x) if neg else exp(x)
        print(
            f"// exp({to_scaled(x)}, {str(neg).lower()}) -> {to_scaled(result)}"
            f"  // {desc}: e^({'-' if neg else ''}{x:.9f}) = {result:.9f}"
        )

    # normal_cdf tests
    print("\n// --- normal_cdf tests ---")
    cdf_vals = [0.0, 0.5, 1.0, -1.0, 2.0, -2.0, 0.1, -0.5]
    for x in cdf_vals:
        result = norm.cdf(x)
        is_neg = x < 0
        print(
            f"// normal_cdf({to_scaled(abs(x))}, {str(is_neg).lower()}) -> {to_scaled(result)}"
            f"  // N({x:.1f}) = {result:.9f}"
        )

    # Scenario test values
    for i, s in enumerate(scenarios):
        print(f"\n{'=' * 70}")
        print(f"SCENARIO {i + 1}: {s['name']}")
        print(f"{'=' * 70}")

        svi = s["svi"]
        tte_ms = s["tte_days"] * 24 * 60 * 60 * 1000

        rho_neg = svi["rho"] < 0
        m_neg = svi["m"] < 0

        now_ms = 1_000_000_000
        expiry_ms = now_ms + tte_ms

        print(f"\n// Oracle parameters (Move u64 values):")
        print(f"// spot:      {to_price(s['spot'])}")
        print(f"// forward:   {to_price(s['forward'])}")
        print(f"// svi_a:     {to_scaled(svi['a'])}")
        print(f"// svi_b:     {to_scaled(svi['b'])}")
        print(
            f"// svi_rho:   {to_scaled(svi['rho'])}, negative={str(rho_neg).lower()}"
        )
        print(f"// svi_m:     {to_scaled(svi['m'])}, negative={str(m_neg).lower()}")
        print(f"// svi_sigma: {to_scaled(svi['sigma'])}")
        print(f"// r:         {to_scaled(s['risk_free_rate'])}")
        print(f"// now_ms:    {now_ms}")
        print(f"// expiry_ms: {expiry_ms}")
        print(f"// tte_ms:    {tte_ms}")

        for strike, label in zip(s["strikes"], s["labels"]):
            r = compute_binary(
                s["forward"],
                strike,
                svi["a"],
                svi["b"],
                svi["rho"],
                svi["m"],
                svi["sigma"],
                s["risk_free_rate"],
                tte_ms,
            )

            print(f"\n// --- {label} (strike=${strike:,.0f}) ---")
            print(f"// strike:     {to_price(strike)}")
            print(
                f"// k:          {r['k']:.9f} ({'neg' if r['k'] < 0 else 'pos'})"
            )
            print(f"// total_var:  {r['total_var']:.9f} -> {to_scaled(r['total_var'])}")
            print(f"// d2:         {r['d2']:.9f} ({'neg' if r['d2'] < 0 else 'pos'})")
            print(f"// nd2_up:     {r['nd2_up']:.9f} -> {to_scaled(r['nd2_up'])}")
            print(f"// nd2_down:   {r['nd2_down']:.9f} -> {to_scaled(r['nd2_down'])}")
            print(f"// discount:   {r['discount']:.9f} -> {to_scaled(r['discount'])}")
            print(f"// price_up:   {r['price_up']:.9f} -> {to_scaled(r['price_up'])}")
            print(f"// price_down: {r['price_down']:.9f} -> {to_scaled(r['price_down'])}")

            # Sanity: up + down ≈ discount (put-call parity for binary)
            sum_check = r["price_up"] + r["price_down"]
            print(
                f"// up+down:    {sum_check:.9f} vs discount {r['discount']:.9f}"
                f"  (diff={abs(sum_check - r['discount']):.2e})"
            )


if __name__ == "__main__":
    main()
