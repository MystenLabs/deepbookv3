#!/usr/bin/env python3
"""
Generates mathematically correct constants for predict unit tests.

Source of truth for binary option pricing math:
- SVI volatility surface → total variance
- Black-Scholes d2 → N(d2) for digital option pricing
- Discount factor e^(-r*t)

Uses scipy for true normal CDF and real-world CSV data from simulation/.

All values are floor-truncated to FLOAT_SCALING (1e9).
If the contract disagrees, the unit test fails — exposing the error.

Usage: python3 generate_constants.py
Dependencies: pip install scipy
"""

import csv
import math as pymath
from pathlib import Path

from scipy.stats import norm

FLOAT = 1_000_000_000
MS_PER_YEAR = 31_536_000_000


def floor_float(x: float) -> int:
    """Convert a real number to FLOAT_SCALING, floor-truncated."""
    return int(x * FLOAT)


# ====================================================================
# True math functions (source of truth — NOT the contract's math)
# ====================================================================


def true_svi_total_variance(
    k: float, a: float, b: float, rho: float, m: float, sigma: float
) -> float:
    """SVI total variance: a + b * (rho*(k-m) + sqrt((k-m)^2 + sigma^2))"""
    km = k - m
    return a + b * (rho * km + pymath.sqrt(km * km + sigma * sigma))


def true_binary_price(
    forward: float,
    strike: float,
    a: float,
    b: float,
    rho: float,
    m: float,
    sigma: float,
    rate: float,
    t: float,
    is_up: bool,
) -> float:
    """
    True binary option price using SVI + Black-Scholes.

    Binary call (UP) = discount * N(d2)
    Binary put (DN)  = discount * N(-d2)

    where d2 = (-k - total_var/2) / sqrt(total_var)
          k = ln(strike / forward)
          discount = e^(-r*t)
    """
    if t <= 0:
        if is_up:
            return 1.0 if forward > strike else 0.0
        else:
            return 0.0 if forward > strike else 1.0

    k = pymath.log(strike / forward)
    total_var = true_svi_total_variance(k, a, b, rho, m, sigma)
    sqrt_var = pymath.sqrt(total_var)

    d2 = (-k - total_var / 2) / sqrt_var
    discount = pymath.exp(-rate * t)

    if is_up:
        return discount * norm.cdf(d2)
    else:
        return discount * norm.cdf(-d2)


def true_binary_price_int(
    forward_int: int,
    strike_int: int,
    a_int: int,
    b_int: int,
    rho_int: int,
    rho_negative: bool,
    m_int: int,
    m_negative: bool,
    sigma_int: int,
    rate_int: int,
    t_years: float,
    is_up: bool,
) -> int:
    """Compute true binary price from FLOAT_SCALING integer inputs."""
    forward = forward_int / FLOAT
    strike = strike_int / FLOAT
    a = a_int / FLOAT
    b = b_int / FLOAT
    rho = rho_int / FLOAT * (-1 if rho_negative else 1)
    m = m_int / FLOAT * (-1 if m_negative else 1)
    sigma = sigma_int / FLOAT
    rate = rate_int / FLOAT

    price = true_binary_price(forward, strike, a, b, rho, m, sigma, rate, t_years, is_up)
    return floor_float(price)


# ====================================================================
# CSV data loading
# ====================================================================

SIMULATION_DIR = Path(__file__).parent.parent / "simulation"


def load_csv_rows(filename: str) -> list[dict]:
    path = SIMULATION_DIR / filename
    with open(path) as f:
        return list(csv.DictReader(f))


def match_svi_to_price(price_row: dict, svi_rows: list[dict]) -> dict:
    """Find the SVI row with the closest timestamp to a price row."""
    price_ts = int(price_row["checkpoint_timestamp_ms"])
    best = min(svi_rows, key=lambda r: abs(int(r["checkpoint_timestamp_ms"]) - price_ts))
    return best


# ====================================================================
# Output helpers
# ====================================================================


def section(title: str):
    print(f"\n// === {title} ===")


def const(name: str, value: int, comment: str = ""):
    suffix = f" // {comment}" if comment else ""
    print(f"const {name}: u64 = {value:_};{suffix}")


# ====================================================================
# Generate math constants
# ====================================================================


def generate_math_constants():
    section("Math constants")

    const("LN2", floor_float(pymath.log(2)), f"ln(2) = {pymath.log(2):.15f}")
    const("LN4", floor_float(pymath.log(4)), f"ln(4) = {pymath.log(4):.15f}")
    const("LN8", floor_float(pymath.log(8)), f"ln(8) = {pymath.log(8):.15f}")
    const("LN16", floor_float(pymath.log(16)), f"ln(16) = {pymath.log(16):.15f}")
    const("LN_1E9", floor_float(pymath.log(1e9)), f"ln(1e9) = {pymath.log(1e9):.15f}")
    const("E", floor_float(pymath.e), f"e = {pymath.e:.15f}")
    const("E_INV", floor_float(1.0 / pymath.e), f"1/e = {1 / pymath.e:.15f}")

    section("Normal CDF")
    for x in [0, 0.1, 0.25, 0.5, 1, 2, 3, 5, 8]:
        name = str(x).replace(".", "_")
        phi = floor_float(norm.cdf(x))
        phi_neg = floor_float(norm.cdf(-x))
        const(f"PHI_{name}", phi, f"Φ({x})")
        const(f"PHI_NEG_{name}", phi_neg, f"Φ(-{x})")


# ====================================================================
# Generate real-world test scenarios from CSV data
# ====================================================================


def generate_realworld_scenarios():
    section("Real-world test scenarios from simulation/oracle_*.csv")
    print("// Each scenario uses real Block Scholes SVI params + prices")
    print("// from ETH options markets, sampled at different timestamps.")
    print("//")
    print("// The python script computes true binary option prices using scipy.")
    print("// The Move tests assert the contract matches these values.")

    try:
        price_rows = load_csv_rows("oracle_prices_mar17.csv")
        svi_rows = load_csv_rows("oracle_svi_mar17.csv")
    except FileNotFoundError as e:
        print(f"// WARNING: CSV data not found: {e}")
        print("// Skipping real-world scenarios.")
        return

    # Pick 10 evenly-spaced snapshots across the dataset
    total = len(price_rows)
    indices = [int(i * total / 10) for i in range(10)]

    # Assume expiry is ~1 week from the first timestamp
    first_ts_ms = int(price_rows[0]["checkpoint_timestamp_ms"])
    expiry_ms = first_ts_ms + 7 * 24 * 3600 * 1000

    for scenario_idx, row_idx in enumerate(indices):
        price_row = price_rows[row_idx]
        svi_row = match_svi_to_price(price_row, svi_rows)

        spot = int(price_row["spot"])
        forward = int(price_row["forward"])
        now_ms = int(price_row["checkpoint_timestamp_ms"])

        a = int(svi_row["a"])
        b = int(svi_row["b"])
        rho = int(svi_row["rho"])
        rho_negative = svi_row["rho_negative"].strip() == "True"
        m = int(svi_row["m"])
        m_negative = svi_row["m_negative"].strip() == "True"
        sigma = int(svi_row["sigma"])
        rate = int(svi_row["risk_free_rate"])

        tte_ms = expiry_ms - now_ms
        if tte_ms <= 0:
            continue
        t_years = tte_ms / MS_PER_YEAR

        # 5 strikes per scenario
        strikes = [
            ("ATM", forward),
            ("OTM5", int(forward * 1.05)),
            ("OTM10", int(forward * 1.10)),
            ("ITM5", int(forward * 0.95)),
            ("ITM10", int(forward * 0.90)),
        ]

        print(f"\n// --- Scenario {scenario_idx}: row={row_idx}, "
              f"spot={spot / FLOAT:.2f}, forward={forward / FLOAT:.2f}, "
              f"tte={t_years:.4f}y ---")
        print(f"// SVI: a={a}, b={b}, rho={rho} ({'neg' if rho_negative else 'pos'}), "
              f"m={m} ({'neg' if m_negative else 'pos'}), sigma={sigma}, rate={rate}")

        prefix = f"S{scenario_idx}"
        const(f"{prefix}_SPOT", spot)
        const(f"{prefix}_FORWARD", forward)
        const(f"{prefix}_A", a)
        const(f"{prefix}_B", b)
        const(f"{prefix}_RHO", rho)
        const(f"{prefix}_RHO_NEG", 1 if rho_negative else 0)
        const(f"{prefix}_M", m)
        const(f"{prefix}_M_NEG", 1 if m_negative else 0)
        const(f"{prefix}_SIGMA", sigma)
        const(f"{prefix}_RATE", rate)
        const(f"{prefix}_EXPIRY_MS", expiry_ms)
        const(f"{prefix}_NOW_MS", now_ms)

        for strike_label, strike in strikes:
            up = true_binary_price_int(
                forward, strike, a, b, rho, rho_negative,
                m, m_negative, sigma, rate, t_years, True
            )
            dn = true_binary_price_int(
                forward, strike, a, b, rho, rho_negative,
                m, m_negative, sigma, rate, t_years, False
            )
            const(f"{prefix}_STRIKE_{strike_label}", strike)
            const(f"{prefix}_UP_{strike_label}", up)
            const(f"{prefix}_DN_{strike_label}", dn)


# ====================================================================
# Main
# ====================================================================


def main():
    print("// Generated by generate_constants.py — floor(true_value * 1e9)")
    print("// Source of truth: scipy.stats.norm + true Black-Scholes math")
    print("// If the contract disagrees, the test fails — exposing the error.")

    generate_math_constants()
    generate_realworld_scenarios()


if __name__ == "__main__":
    main()
