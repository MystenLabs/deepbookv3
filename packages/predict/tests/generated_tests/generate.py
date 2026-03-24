#!/usr/bin/env python3
"""
Generates generated_scenarios.move with ground-truth test constants.

Pure Python/scipy math — no FLOAT_SCALING in calculations. Scaling to
the contract's 1e9 fixed-point representation happens only at the output
layer when writing the .move file.

Reference: blockscholes_oracle_deepbook_demo.py for pricing patterns.

Source of truth:
- scipy.stats.norm for normal CDF
- Standard Black-Scholes for binary option pricing
- SVI parameterization for implied volatility

Usage: python3 generate.py
Dependencies: pip install scipy
"""

import csv
import math
from pathlib import Path

from scipy.stats import norm

# ====================================================================
# Constants
# ====================================================================

SECONDS_IN_YEAR = 365.0 * 24 * 60 * 60
FLOAT_SCALING = 1_000_000_000  # only used at the output layer

# Default pricing config (mirrors constants.move defaults)
DEFAULT_BASE_SPREAD = 0.02  # 2%
DEFAULT_MIN_SPREAD = 0.005  # 0.5%
DEFAULT_UTIL_MULTIPLIER = 2.0  # 2x

DATA_DIR = Path(__file__).parent
OUTPUT_FILE = DATA_DIR / "generated_scenarios.move"


# ====================================================================
# SVI + Black-Scholes pricing (pure float math)
# ====================================================================


def svi_total_variance(
    k: float, a: float, b: float, rho: float, m: float, sigma: float
) -> float:
    """SVI total variance: a + b * (rho*(k-m) + sqrt((k-m)^2 + sigma^2))"""
    km = k - m
    return a + b * (rho * km + math.sqrt(km * km + sigma * sigma))


def binary_price(
    forward: float,
    strike: float,
    a: float,
    b: float,
    rho: float,
    m: float,
    sigma: float,
    rate: float,
    t: float,
    is_call: bool,
) -> float:
    """
    Binary option price using SVI + Black-Scholes.

    Binary call (UP) = discount * N(d2)
    Binary put (DN)  = discount * N(-d2)

    d2 = (-k - total_var/2) / sqrt(total_var)
    k = ln(strike / forward)
    discount = e^(-r*t)
    """
    if t <= 0:
        if is_call:
            return 1.0 if forward > strike else 0.0
        else:
            return 0.0 if forward > strike else 1.0

    k = math.log(strike / forward)
    total_var = svi_total_variance(k, a, b, rho, m, sigma)
    sqrt_var = math.sqrt(total_var)

    d2 = (-k - total_var / 2) / sqrt_var
    discount = math.exp(-rate * t)

    if is_call:
        return discount * norm.cdf(d2)
    else:
        return discount * norm.cdf(-d2)


# ====================================================================
# Spread + mint pricing (pure float math)
# ====================================================================


def mint_spread(price: float, base_spread: float, min_spread: float) -> float:
    """Bernoulli spread: base_spread * sqrt(price * (1 - price)), floored at min_spread."""
    variance = price * (1.0 - price)
    bernoulli_spread = base_spread * math.sqrt(variance)
    return max(bernoulli_spread, min_spread)


def utilization_spread(
    base_spread: float, util_multiplier: float, liability: float, balance: float
) -> float:
    """Utilization spread: base_spread * util_multiplier * util^2."""
    if balance == 0.0 or liability == 0.0:
        return 0.0
    util = min(liability / balance, 1.0)
    return base_spread * util_multiplier * util * util


def ask_price(
    price: float,
    base_spread: float,
    min_spread: float,
    util_multiplier: float,
    liability: float,
    balance: float,
) -> float:
    """Ask price: min(1.0, price + spread + util_spread)."""
    spread = mint_spread(price, base_spread, min_spread)
    util_spread = utilization_spread(base_spread, util_multiplier, liability, balance)
    return min(1.0, price + spread + util_spread)


def mint_cost(
    price: float,
    quantity: float,
    base_spread: float,
    min_spread: float,
    util_multiplier: float,
    liability: float,
    balance: float,
) -> float:
    """Mint cost: ask * quantity."""
    ask = ask_price(price, base_spread, min_spread, util_multiplier, liability, balance)
    return ask * quantity


# ====================================================================
# CSV loading
# ====================================================================


def load_csv(filename: str) -> list[dict]:
    path = DATA_DIR / filename
    with open(path) as f:
        return list(csv.DictReader(f))


def match_svi_to_price(price_row: dict, svi_rows: list[dict]) -> dict:
    """Find the SVI row with the closest timestamp to a price row."""
    ts = int(price_row["checkpoint_timestamp_ms"])
    return min(svi_rows, key=lambda r: abs(int(r["checkpoint_timestamp_ms"]) - ts))


def parse_svi_floats(svi_row: dict) -> dict:
    """Parse SVI row into native Python floats."""
    rho_sign = -1 if svi_row["rho_negative"].strip() == "True" else 1
    m_sign = -1 if svi_row["m_negative"].strip() == "True" else 1
    return {
        "a": int(svi_row["a"]) / FLOAT_SCALING,
        "b": int(svi_row["b"]) / FLOAT_SCALING,
        "rho": int(svi_row["rho"]) / FLOAT_SCALING * rho_sign,
        "m": int(svi_row["m"]) / FLOAT_SCALING * m_sign,
        "sigma": int(svi_row["sigma"]) / FLOAT_SCALING,
        "rate": int(svi_row["risk_free_rate"]) / FLOAT_SCALING,
    }


def parse_svi_ints(svi_row: dict) -> dict:
    """Parse SVI row keeping raw integer values (for Move constants)."""
    return {
        "a": int(svi_row["a"]),
        "b": int(svi_row["b"]),
        "rho": int(svi_row["rho"]),
        "rho_neg": svi_row["rho_negative"].strip() == "True",
        "m": int(svi_row["m"]),
        "m_neg": svi_row["m_negative"].strip() == "True",
        "sigma": int(svi_row["sigma"]),
        "rate": int(svi_row["risk_free_rate"]),
    }


# ====================================================================
# Diversity sampling
# ====================================================================

# Time-to-expiry buckets in milliseconds: (label, min_ms, max_ms)
TTE_BUCKETS = [
    ("7d", 5 * 24 * 3600_000, 8 * 24 * 3600_000),
    ("3d", 2 * 24 * 3600_000, 5 * 24 * 3600_000),
    ("1d", 12 * 3600_000, 2 * 24 * 3600_000),
    ("6h", 2 * 3600_000, 12 * 3600_000),
    ("1h", 15 * 60_000, 2 * 3600_000),
    ("5m", 1 * 60_000, 15 * 60_000),
    ("1m", 1_000, 1 * 60_000),
]


def sample_diverse(
    price_rows: list[dict], svi_rows: list[dict], expiry_ms: int
) -> list[dict]:
    """
    Pick one representative price row per TTE bucket.

    Within each bucket, pick the row whose forward price is closest to
    the bucket's median forward — gives us a "typical" snapshot per regime.
    Then pick an additional row with the most extreme SVI b (highest vol)
    across all buckets for extra diversity.
    """
    selected = []

    for label, lo_ms, hi_ms in TTE_BUCKETS:
        bucket = [
            r for r in price_rows
            if lo_ms < (expiry_ms - int(r["checkpoint_timestamp_ms"])) <= hi_ms
        ]
        if not bucket:
            continue

        # Pick median forward price row
        forwards = sorted(bucket, key=lambda r: int(r["forward"]))
        mid = forwards[len(forwards) // 2]
        selected.append(mid)

    # Add highest-vol snapshot (max SVI b) if not already included
    selected_ts = {int(r["checkpoint_timestamp_ms"]) for r in selected}
    max_b_svi = max(svi_rows, key=lambda r: int(r["b"]))
    max_b_ts = int(max_b_svi["checkpoint_timestamp_ms"])
    # Find the price row closest to this SVI timestamp
    best_price = min(
        price_rows,
        key=lambda r: abs(int(r["checkpoint_timestamp_ms"]) - max_b_ts),
    )
    if int(best_price["checkpoint_timestamp_ms"]) not in selected_ts:
        selected.append(best_price)

    # Sort by time-to-expiry descending (far expiry first)
    selected.sort(
        key=lambda r: expiry_ms - int(r["checkpoint_timestamp_ms"]), reverse=True
    )

    return selected


# ====================================================================
# Move file writer
# ====================================================================


USDC_SCALING = 1_000_000  # 6 decimals: 1_000_000 = $1


def to_float_scaled(value: float) -> int:
    """Convert a price/percentage/strike to FLOAT_SCALING (1e9), floor-truncated."""
    return int(value * FLOAT_SCALING)


def to_usdc(value: float) -> int:
    """Convert a dollar amount/quantity to USDC units (1e6), floor-truncated."""
    return int(value * USDC_SCALING)


class MoveWriter:
    """Builds a #[test_only] Move module with generated constants."""

    def __init__(self):
        self.lines: list[str] = []

    def header(self):
        self.lines.append("// DO NOT EDIT — generated by generate.py")
        self.lines.append(
            "// Source of truth: scipy.stats.norm + Black-Scholes + SVI"
        )
        self.lines.append(
            "// Regenerate: cd tests/generated_tests && python3 generate.py"
        )
        self.lines.append("")
        self.lines.append("#[test_only]")
        self.lines.append("module deepbook_predict::generated_scenarios;")
        self.lines.append("")

    def comment(self, text: str):
        self.lines.append(f"// {text}")

    def blank(self):
        self.lines.append("")

    def section(self, title: str):
        self.blank()
        self.lines.append(f"// === {title} ===")

    def const(self, name: str, value: int, comment: str = ""):
        suffix = f" // {comment}" if comment else ""
        self.lines.append(f"public macro fun {name}(): u64 {{ {value:_} }}{suffix}")

    def write(self, path: Path):
        with open(path, "w") as f:
            f.write("\n".join(self.lines))
            f.write("\n")
        print(f"Wrote {path} ({len(self.lines)} lines)")


# ====================================================================
# Scenario generation
# ====================================================================


def generate_math_constants(w: MoveWriter):
    w.section("Math constants")

    w.const("LN2", to_float_scaled(math.log(2)), f"ln(2) = {math.log(2):.15f}")
    w.const("LN4", to_float_scaled(math.log(4)), f"ln(4) = {math.log(4):.15f}")
    w.const("LN8", to_float_scaled(math.log(8)), f"ln(8) = {math.log(8):.15f}")
    w.const("LN16", to_float_scaled(math.log(16)), f"ln(16) = {math.log(16):.15f}")
    w.const(
        "LN_1E9", to_float_scaled(math.log(1e9)), f"ln(1e9) = {math.log(1e9):.15f}"
    )
    w.const("E", to_float_scaled(math.e), f"e = {math.e:.15f}")
    w.const("E_INV", to_float_scaled(1.0 / math.e), f"1/e = {1 / math.e:.15f}")

    w.section("Normal CDF")
    for x in [0, 0.1, 0.25, 0.5, 1, 2, 3, 5, 8]:
        name = str(x).replace(".", "_")
        w.const(f"PHI_{name}", to_float_scaled(norm.cdf(x)), f"Φ({x})")
        w.const(f"PHI_NEG_{name}", to_float_scaled(norm.cdf(-x)), f"Φ(-{x})")


def emit_snapshot(
    w: MoveWriter,
    prefix: str,
    price_row: dict,
    svi_rows: list[dict],
    expiry_ms: int,
):
    """Emit oracle params for a single snapshot. Returns (svi_f, svi_i, t, forward) or None."""
    svi_row = match_svi_to_price(price_row, svi_rows)

    spot_int = int(price_row["spot"])
    forward_int = int(price_row["forward"])
    now_ms = int(price_row["checkpoint_timestamp_ms"])

    svi_f = parse_svi_floats(svi_row)
    svi_i = parse_svi_ints(svi_row)

    tte_ms = expiry_ms - now_ms
    if tte_ms <= 0:
        return None
    t = tte_ms / 1000.0 / SECONDS_IN_YEAR

    forward = forward_int / FLOAT_SCALING
    spot = spot_int / FLOAT_SCALING

    tte_human = (
        f"{tte_ms / 1000:.0f}s"
        if tte_ms < 60_000
        else f"{tte_ms / 60_000:.0f}m"
        if tte_ms < 3600_000
        else f"{tte_ms / 3600_000:.1f}h"
        if tte_ms < 86400_000
        else f"{tte_ms / 86400_000:.1f}d"
    )

    w.blank()
    w.comment(
        f"--- {prefix}: spot={spot:.2f}, forward={forward:.2f}, tte={tte_human} ---"
    )

    w.const(f"{prefix}_SPOT", spot_int)
    w.const(f"{prefix}_FORWARD", forward_int)
    w.const(f"{prefix}_A", svi_i["a"])
    w.const(f"{prefix}_B", svi_i["b"])
    w.const(f"{prefix}_RHO", svi_i["rho"])
    w.const(f"{prefix}_RHO_NEG", 1 if svi_i["rho_neg"] else 0)
    w.const(f"{prefix}_M", svi_i["m"])
    w.const(f"{prefix}_M_NEG", 1 if svi_i["m_neg"] else 0)
    w.const(f"{prefix}_SIGMA", svi_i["sigma"])
    w.const(f"{prefix}_RATE", svi_i["rate"])
    w.const(f"{prefix}_EXPIRY_MS", expiry_ms)
    w.const(f"{prefix}_NOW_MS", now_ms)

    return svi_f, svi_i, t, forward


ORACLE_TEST_QUANTITY = 10.0  # standard quantity for MTM tests


def generate_oracle_scenarios(w: MoveWriter, snapshots, svi_rows, expiry_ms):
    w.section("Oracle pricing scenarios from real Block Scholes data")
    w.comment("Sampled by time-to-expiry diversity: 7d, 3d, 1d, 6h, 1h, 5m, <1m")
    w.comment(f"MTM values use quantity = {ORACLE_TEST_QUANTITY}")

    for idx, price_row in enumerate(snapshots):
        prefix = f"S{idx}"
        result = emit_snapshot(w, prefix, price_row, svi_rows, expiry_ms)
        if result is None:
            continue
        svi_f, _, t, forward = result

        strikes = [
            ("ATM", forward),
            ("OTM5", forward * 1.05),
            ("OTM10", forward * 1.10),
            ("ITM5", forward * 0.95),
            ("ITM10", forward * 0.90),
        ]

        for label, strike in strikes:
            up = binary_price(
                forward, strike, svi_f["a"], svi_f["b"], svi_f["rho"],
                svi_f["m"], svi_f["sigma"], svi_f["rate"], t, True,
            )
            dn = binary_price(
                forward, strike, svi_f["a"], svi_f["b"], svi_f["rho"],
                svi_f["m"], svi_f["sigma"], svi_f["rate"], t, False,
            )
            up_mtm = up * ORACLE_TEST_QUANTITY
            dn_mtm = dn * ORACLE_TEST_QUANTITY
            w.const(f"{prefix}_STRIKE_{label}", to_float_scaled(strike))
            w.const(f"{prefix}_UP_{label}", to_float_scaled(up))
            w.const(f"{prefix}_DN_{label}", to_float_scaled(dn))
            w.const(f"{prefix}_MTM_UP_{label}", to_usdc(up_mtm))
            w.const(f"{prefix}_MTM_DN_{label}", to_usdc(dn_mtm))


def generate_mint_scenarios(w: MoveWriter, snapshots, svi_rows, expiry_ms):
    w.section("Mint pricing scenarios from real Block Scholes data")
    w.comment("Same snapshots as oracle scenarios, with spread + cost calculations.")
    w.comment(
        f"Default config: base_spread={DEFAULT_BASE_SPREAD}, "
        f"min_spread={DEFAULT_MIN_SPREAD}, util_mult={DEFAULT_UTIL_MULTIPLIER}"
    )

    # (suffix, is_call, strike_factor, quantity, util_pct)
    mint_cases = [
        ("ATM_UP", True, 1.00, 10.0, 0),
        ("ATM_DN", False, 1.00, 10.0, 0),
        ("OTM_UP", True, 1.10, 10.0, 0),
        ("ITM_UP", True, 0.90, 10.0, 0),
        ("ATM_UP_UTIL50", True, 1.00, 10.0, 50),
        ("ATM_UP_UTIL80", True, 1.00, 10.0, 80),
        ("ATM_UP_SMALL", True, 1.00, 0.001, 0),
        ("ATM_UP_LARGE", True, 1.00, 500.0, 0),
    ]

    for idx, price_row in enumerate(snapshots):
        prefix = f"M{idx}"
        result = emit_snapshot(w, prefix, price_row, svi_rows, expiry_ms)
        if result is None:
            continue
        svi_f, _, t, forward = result

        vault_balance = forward * 10
        w.const(f"{prefix}_VAULT_BALANCE", to_usdc(vault_balance))

        for suffix, is_call, strike_factor, quantity, util_pct in mint_cases:
            strike = forward * strike_factor
            vault_liability = vault_balance * util_pct / 100.0

            price = binary_price(
                forward, strike, svi_f["a"], svi_f["b"], svi_f["rho"],
                svi_f["m"], svi_f["sigma"], svi_f["rate"], t, is_call,
            )
            spread = mint_spread(price, DEFAULT_BASE_SPREAD, DEFAULT_MIN_SPREAD)
            util_spr = utilization_spread(
                DEFAULT_BASE_SPREAD, DEFAULT_UTIL_MULTIPLIER,
                vault_liability, vault_balance,
            )
            total_spread = spread + util_spr
            ask = min(1.0, price + total_spread)
            bid = max(0.0, price - total_spread)
            cost = ask * quantity
            redeem_payout = bid * quantity

            label = f"{prefix}_{suffix}"
            direction = "UP" if is_call else "DN"
            w.comment(
                f"{label}: strike={strike:.2f}, {direction}, "
                f"qty={quantity}, util={util_pct}%"
            )
            w.comment(
                f"  price={price:.9f}, spread={spread:.9f}, "
                f"util_spread={util_spr:.9f}, ask={ask:.9f}, bid={bid:.9f}"
            )

            w.const(f"{label}_STRIKE", to_float_scaled(strike))
            w.const(f"{label}_QUANTITY", to_usdc(quantity))
            w.const(f"{label}_VAULT_LIABILITY", to_usdc(vault_liability))
            w.const(f"{label}_PRICE", to_float_scaled(price))
            w.const(f"{label}_SPREAD", to_float_scaled(spread))
            w.const(f"{label}_UTIL_SPREAD", to_float_scaled(util_spr))
            w.const(f"{label}_ASK", to_float_scaled(ask))
            w.const(f"{label}_BID", to_float_scaled(bid))
            w.const(f"{label}_COST", to_usdc(cost))
            w.const(f"{label}_REDEEM_PAYOUT", to_usdc(redeem_payout))


# ====================================================================
# Synthetic oracle scenarios (hand-picked params to isolate behaviors)
# ====================================================================


def generate_synthetic_oracle_scenarios(w: MoveWriter):
    w.section("Synthetic oracle scenarios")
    w.comment("Hand-picked SVI params to test specific pricing behaviors.")
    w.comment("All inputs are pure math — no contract conventions (ms, FLOAT_SCALING).")
    w.comment("Move tests must construct oracles that produce matching t values.")

    forward = 100.0

    # Short TTE (~0.0000317 years). Move tests: expiry=1_000_000ms, clock=0.
    t_short = 1e6 / (SECONDS_IN_YEAR * 1000)

    # --- Standard SVI: a=0, b=1, rho=0, m=0, sigma=0.25, rate=0 ---
    std = {"a": 0.0, "b": 1.0, "rho": 0.0, "m": 0.0, "sigma": 0.25}

    w.blank()
    w.comment(f"Standard SVI (a=0, b=1, rho=0, m=0, sigma=0.25), rate=0, t={t_short:.10f}yr")
    strikes_std = [
        ("ATM", 100.0),
        ("STRIKE_2X", 200.0),
        ("DEEP_ITM", 10.0),
        ("DEEP_OTM", 1000.0),
        ("S50", 50.0),
        ("S80", 80.0),
        ("S100", 100.0),
        ("S120", 120.0),
        ("S150", 150.0),
    ]
    for label, strike in strikes_std:
        up = binary_price(forward, strike, **std, rate=0.0, t=t_short, is_call=True)
        dn = binary_price(forward, strike, **std, rate=0.0, t=t_short, is_call=False)
        w.const(f"SYN_STD_UP_{label}", to_float_scaled(up))
        w.const(f"SYN_STD_DN_{label}", to_float_scaled(dn))

    # --- With 5% rate, t=1 year ---
    w.blank()
    t_1yr = 1.0
    discount_5pct = math.exp(-0.05 * t_1yr)
    w.comment(f"Standard SVI with 5% rate, t={t_1yr}yr")
    w.const("SYN_DISCOUNT_5PCT_1YR", to_float_scaled(discount_5pct),
            f"e^(-0.05*{t_1yr}) = {discount_5pct:.9f}")

    strikes_5pct = [
        ("S60", 60.0),
        ("S80", 80.0),
        ("S100", 100.0),
        ("S120", 120.0),
        ("S140", 140.0),
    ]
    for label, strike in strikes_5pct:
        up = binary_price(forward, strike, **std, rate=0.05, t=t_1yr, is_call=True)
        dn = binary_price(forward, strike, **std, rate=0.05, t=t_1yr, is_call=False)
        w.const(f"SYN_5PCT_UP_{label}", to_float_scaled(up))
        w.const(f"SYN_5PCT_DN_{label}", to_float_scaled(dn))

    w.const("SYN_5PCT_UP_ATM", to_float_scaled(
        binary_price(forward, 100.0, **std, rate=0.05, t=t_1yr, is_call=True)))
    w.const("SYN_5PCT_DN_ATM", to_float_scaled(
        binary_price(forward, 100.0, **std, rate=0.05, t=t_1yr, is_call=False)))

    # --- With 10% rate, t=0.5 years ---
    w.blank()
    t_half = 0.5
    discount_10pct_half = math.exp(-0.10 * t_half)
    w.comment(f"Standard SVI with 10% rate, t={t_half}yr")
    w.const("SYN_DISCOUNT_10PCT_HALF_YR", to_float_scaled(discount_10pct_half),
            f"e^(-0.10*{t_half}) = {discount_10pct_half:.9f}")
    up = binary_price(forward, 100.0, **std, rate=0.10, t=t_half, is_call=True)
    dn = binary_price(forward, 100.0, **std, rate=0.10, t=t_half, is_call=False)
    w.const("SYN_10PCT_HALF_UP_ATM", to_float_scaled(up))
    w.const("SYN_10PCT_HALF_DN_ATM", to_float_scaled(dn))

    # --- With 10% rate, t ≈ 0.317 years ---
    w.blank()
    t_partial = 10e9 / (SECONDS_IN_YEAR * 1000)
    w.comment(f"Standard SVI with 10% rate, t={t_partial:.10f}yr")
    up = binary_price(forward, 100.0, **std, rate=0.10, t=t_partial, is_call=True)
    dn = binary_price(forward, 100.0, **std, rate=0.10, t=t_partial, is_call=False)
    w.const("SYN_10PCT_PARTIAL_UP_ATM", to_float_scaled(up))
    w.const("SYN_10PCT_PARTIAL_DN_ATM", to_float_scaled(dn))

    # --- Full SVI: a=0.05, b=0.8, rho=-0.3, m=0.1, sigma=0.2, rate=0 ---
    w.blank()
    w.comment(f"Full SVI (a=0.05, b=0.8, rho=-0.3, m=0.1, sigma=0.2), rate=0, t={t_short:.10f}yr")
    full = {"a": 0.05, "b": 0.8, "rho": -0.3, "m": 0.1, "sigma": 0.2}
    up = binary_price(forward, 100.0, **full, rate=0.0, t=t_short, is_call=True)
    dn = binary_price(forward, 100.0, **full, rate=0.0, t=t_short, is_call=False)
    w.const("SYN_FULL_UP_ATM", to_float_scaled(up))
    w.const("SYN_FULL_DN_ATM", to_float_scaled(dn))

    # --- Small sigma: sigma=0.01, rest standard ---
    w.blank()
    w.comment(f"Small sigma (sigma=0.01), rate=0, t={t_short:.10f}yr")
    small_sigma = {**std, "sigma": 0.01}
    up = binary_price(forward, 100.0, **small_sigma, rate=0.0, t=t_short, is_call=True)
    dn = binary_price(forward, 100.0, **small_sigma, rate=0.0, t=t_short, is_call=False)
    w.const("SYN_SMALL_SIGMA_UP_ATM", to_float_scaled(up))
    w.const("SYN_SMALL_SIGMA_DN_ATM", to_float_scaled(dn))

    # --- Nonzero a: a=0.1, rest standard ---
    w.blank()
    w.comment(f"Nonzero a (a=0.1), rate=0, t={t_short:.10f}yr — increases variance")
    nonzero_a = {**std, "a": 0.1}
    up = binary_price(forward, 100.0, **nonzero_a, rate=0.0, t=t_short, is_call=True)
    w.const("SYN_A100M_UP_ATM", to_float_scaled(up))

    # --- Negative rho: rho=-0.3 ---
    w.blank()
    w.comment(f"Negative rho (rho=-0.3), rate=0, t={t_short:.10f}yr — skews the smile")
    neg_rho = {**std, "rho": -0.3}
    for label, strike in [("S80", 80.0), ("S100", 100.0), ("S120", 120.0)]:
        up = binary_price(forward, strike, **neg_rho, rate=0.0, t=t_short, is_call=True)
        dn = binary_price(forward, strike, **neg_rho, rate=0.0, t=t_short, is_call=False)
        w.const(f"SYN_NEG_RHO_UP_{label}", to_float_scaled(up))
        w.const(f"SYN_NEG_RHO_DN_{label}", to_float_scaled(dn))

    # --- Nonzero m: m=0.1 ---
    w.blank()
    w.comment(f"Nonzero m (m=0.1), rate=0, t={t_short:.10f}yr — shifts the smile center")
    nonzero_m = {**std, "m": 0.1}
    for label, strike in [("S80", 80.0), ("S100", 100.0), ("S120", 120.0)]:
        up = binary_price(forward, strike, **nonzero_m, rate=0.0, t=t_short, is_call=True)
        dn = binary_price(forward, strike, **nonzero_m, rate=0.0, t=t_short, is_call=False)
        w.const(f"SYN_M_UP_{label}", to_float_scaled(up))
        w.const(f"SYN_M_DN_{label}", to_float_scaled(dn))


# ====================================================================
# Bulk trade sequence generation (separate file)
# ====================================================================

BULK_OUTPUT_FILE = DATA_DIR / "generated_scenarios_bulk.move"

INITIAL_VAULT_BALANCE = 100_000.0  # initial LP liquidity
TRADE_QUANTITY = 10.0

# Strike patterns: (factor relative to forward, is_up)
STRIKE_PATTERNS = [
    (1.00, True),
    (1.00, False),
    (1.05, True),
    (0.95, True),
    (1.10, True),
    (0.90, True),
    (1.05, False),
    (0.95, False),
]


def recompute_mtm(
    positions: dict[tuple[float, bool], float],
    forward: float,
    svi: dict,
    rate: float,
    t: float,
) -> float:
    """Reprice all open positions at current market. Brute-force but correct."""
    total = 0.0
    for (strike, is_up), qty in positions.items():
        price = binary_price(
            forward, strike, svi["a"], svi["b"], svi["rho"],
            svi["m"], svi["sigma"], rate, t, is_up,
        )
        total += price * qty
    return total


def generate_trade_sequence(
    price_rows: list[dict],
    svi_rows: list[dict],
    expiry_ms: int,
    num_steps: int,
) -> list[dict]:
    """
    Generate a sequence of mints/redeems with ground-truth state tracking.

    All math is scipy/float — no contract math. Vault state evolves using
    true arithmetic. After each trade, MTM is recomputed by repricing all
    open positions at the current market snapshot (forward, SVI, t).
    """
    vault_balance = INITIAL_VAULT_BALANCE
    vault_mtm = 0.0
    positions: dict[tuple[float, bool], float] = {}  # (strike, is_up) -> quantity

    valid = [r for r in price_rows if int(r["checkpoint_timestamp_ms"]) < expiry_ms]
    if not valid:
        return []

    row_step = max(1, len(valid) // num_steps)
    steps = []

    for i in range(num_steps):
        row_idx = min(i * row_step, len(valid) - 1)
        price_row = valid[row_idx]
        svi_row = match_svi_to_price(price_row, svi_rows)
        svi_f = parse_svi_floats(svi_row)
        svi_i = parse_svi_ints(svi_row)

        forward_int = int(price_row["forward"])
        spot_int = int(price_row["spot"])
        now_ms = int(price_row["checkpoint_timestamp_ms"])

        tte_ms = expiry_ms - now_ms
        if tte_ms <= 0:
            break
        t = tte_ms / 1000.0 / SECONDS_IN_YEAR
        forward = forward_int / FLOAT_SCALING

        # Decide mint vs redeem: first 40% always mint, then alternate
        can_redeem = len(positions) > 0 and i >= num_steps * 0.4
        is_mint = not can_redeem or (i % 3 != 0)

        if is_mint:
            strike_factor, is_up = STRIKE_PATTERNS[i % len(STRIKE_PATTERNS)]
            strike = forward * strike_factor
            quantity = TRADE_QUANTITY

            # Insert position before pricing (matches contract: insert_position then get_quote)
            key = (strike, is_up)
            positions[key] = positions.get(key, 0.0) + quantity
            vault_mtm = recompute_mtm(positions, forward, svi_f, svi_f["rate"], t)

            price = binary_price(
                forward, strike, svi_f["a"], svi_f["b"], svi_f["rho"],
                svi_f["m"], svi_f["sigma"], svi_f["rate"], t, is_up,
            )
            spread = mint_spread(price, DEFAULT_BASE_SPREAD, DEFAULT_MIN_SPREAD)
            util_spr = utilization_spread(
                DEFAULT_BASE_SPREAD, DEFAULT_UTIL_MULTIPLIER,
                vault_mtm, vault_balance,
            )
            ask = min(1.0, price + spread + util_spr)
            trade_amount = ask * quantity

            vault_balance += trade_amount
        else:
            # Remove position before pricing (matches contract: remove_position then get_quote)
            key = list(positions.keys())[0]
            strike, is_up = key
            quantity = min(positions[key], TRADE_QUANTITY)

            positions[key] -= quantity
            if positions[key] <= 1e-12:
                del positions[key]
            vault_mtm = recompute_mtm(positions, forward, svi_f, svi_f["rate"], t)

            price = binary_price(
                forward, strike, svi_f["a"], svi_f["b"], svi_f["rho"],
                svi_f["m"], svi_f["sigma"], svi_f["rate"], t, is_up,
            )
            spread = mint_spread(price, DEFAULT_BASE_SPREAD, DEFAULT_MIN_SPREAD)
            util_spr = utilization_spread(
                DEFAULT_BASE_SPREAD, DEFAULT_UTIL_MULTIPLIER,
                vault_mtm, vault_balance,
            )
            bid = max(0.0, price - spread - util_spr)
            trade_amount = bid * quantity

            vault_balance -= trade_amount

        steps.append({
            "spot": spot_int,
            "forward": forward_int,
            **svi_i,
            "expiry_ms": expiry_ms,
            "now_ms": now_ms,
            "strike": to_float_scaled(strike),  # strikes are prices → FLOAT_SCALING
            "is_up": is_up,
            "quantity": to_usdc(quantity),
            "is_mint": is_mint,
            "expected_trade_amount": to_usdc(trade_amount),
        })

    return steps


def emit_trade_sequence(w: MoveWriter, name: str, steps: list[dict]):
    """Emit a public fun that returns vector<TradeStep>."""
    w.blank()
    w.comment(f"{len(steps)} sequential trades with evolving vault state")
    w.lines.append(f"public fun {name}(): vector<TradeStep> {{")
    w.lines.append("    vector[")

    for s in steps:
        w.lines.append("        TradeStep {")
        w.lines.append(f"            spot: {s['spot']:_},")
        w.lines.append(f"            forward: {s['forward']:_},")
        w.lines.append(f"            a: {s['a']:_},")
        w.lines.append(f"            b: {s['b']:_},")
        w.lines.append(f"            rho: {s['rho']:_},")
        w.lines.append(f"            rho_neg: {'true' if s['rho_neg'] else 'false'},")
        w.lines.append(f"            m: {s['m']:_},")
        w.lines.append(f"            m_neg: {'true' if s['m_neg'] else 'false'},")
        w.lines.append(f"            sigma: {s['sigma']:_},")
        w.lines.append(f"            rate: {s['rate']:_},")
        w.lines.append(f"            expiry_ms: {s['expiry_ms']:_},")
        w.lines.append(f"            now_ms: {s['now_ms']:_},")
        w.lines.append(f"            strike: {s['strike']:_},")
        w.lines.append(f"            is_up: {'true' if s['is_up'] else 'false'},")
        w.lines.append(f"            quantity: {s['quantity']:_},")
        w.lines.append(f"            is_mint: {'true' if s['is_mint'] else 'false'},")
        w.lines.append(f"            expected_trade_amount: {s['expected_trade_amount']:_},")
        w.lines.append("        },")

    w.lines.append("    ]")
    w.lines.append("}")


def generate_bulk_file(price_rows, svi_rows, expiry_ms):
    w = MoveWriter()
    w.lines.append("// DO NOT EDIT — generated by generate.py")
    w.lines.append("// Sequential trade scenarios for comprehensive precision testing.")
    w.lines.append("// Vault state evolves step-by-step using scipy ground-truth math.")
    w.lines.append("// Regenerate: cd tests/generated_tests && python3 generate.py")
    w.lines.append("")
    w.lines.append("#[test_only]")
    w.lines.append("module deepbook_predict::generated_scenarios_bulk;")
    w.lines.append("")

    w.lines.append(f"const INITIAL_VAULT_BALANCE: u64 = {to_usdc(INITIAL_VAULT_BALANCE):_};")
    w.lines.append("")

    # Struct definition
    w.lines.append("public struct TradeStep has copy, drop {")
    w.lines.append("    spot: u64,")
    w.lines.append("    forward: u64,")
    w.lines.append("    a: u64,")
    w.lines.append("    b: u64,")
    w.lines.append("    rho: u64,")
    w.lines.append("    rho_neg: bool,")
    w.lines.append("    m: u64,")
    w.lines.append("    m_neg: bool,")
    w.lines.append("    sigma: u64,")
    w.lines.append("    rate: u64,")
    w.lines.append("    expiry_ms: u64,")
    w.lines.append("    now_ms: u64,")
    w.lines.append("    strike: u64,")
    w.lines.append("    is_up: bool,")
    w.lines.append("    quantity: u64,")
    w.lines.append("    is_mint: bool,")
    w.lines.append("    expected_trade_amount: u64,")
    w.lines.append("}")
    w.lines.append("")

    # Getters
    fields = [
        ("spot", "u64"), ("forward", "u64"),
        ("a", "u64"), ("b", "u64"), ("rho", "u64"), ("rho_neg", "bool"),
        ("m", "u64"), ("m_neg", "bool"), ("sigma", "u64"), ("rate", "u64"),
        ("expiry_ms", "u64"), ("now_ms", "u64"),
        ("strike", "u64"), ("is_up", "bool"), ("quantity", "u64"),
        ("is_mint", "bool"), ("expected_trade_amount", "u64"),
    ]
    for name, typ in fields:
        w.lines.append(
            f"public fun {name}(s: &TradeStep): {typ} {{ s.{name} }}"
        )

    # Initial vault balance getter
    w.lines.append("")
    w.lines.append(
        "public fun initial_vault_balance(): u64 { INITIAL_VAULT_BALANCE }"
    )

    steps = generate_trade_sequence(price_rows, svi_rows, expiry_ms, 100)
    print(f"  Sequence: {len(steps)} steps")
    emit_trade_sequence(w, "sequence", steps)

    w.write(BULK_OUTPUT_FILE)


# ====================================================================
# Main
# ====================================================================


def main():
    print("Loading CSVs...")
    price_rows = load_csv("oracle_prices_mar17.csv")
    svi_rows = load_csv("oracle_svi_mar17.csv")

    first_ts_ms = int(price_rows[0]["checkpoint_timestamp_ms"])
    expiry_ms = first_ts_ms + 7 * 24 * 3600 * 1000

    # Diversity-sample snapshots for scenario generation
    snapshots = sample_diverse(price_rows, svi_rows, expiry_ms)
    print(f"Sampled {len(snapshots)} diverse snapshots:")
    for r in snapshots:
        tte_ms = expiry_ms - int(r["checkpoint_timestamp_ms"])
        print(f"  tte={tte_ms / 1000:.0f}s, forward={int(r['forward']) / 1e9:.2f}")

    # Generate main .move file
    w = MoveWriter()
    w.header()
    generate_math_constants(w)
    generate_synthetic_oracle_scenarios(w)
    generate_oracle_scenarios(w, snapshots, svi_rows, expiry_ms)
    generate_mint_scenarios(w, snapshots, svi_rows, expiry_ms)
    w.write(OUTPUT_FILE)

    # Generate bulk scenarios file
    print("\nGenerating bulk scenarios...")
    generate_bulk_file(price_rows, svi_rows, expiry_ms)


if __name__ == "__main__":
    main()
