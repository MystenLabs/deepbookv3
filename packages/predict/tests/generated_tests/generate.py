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

# Per-module output files
MATH_OUTPUT = DATA_DIR / "generated_math.move"
ORACLE_OUTPUT = DATA_DIR / "generated_oracle.move"
PREDICT_OUTPUT = DATA_DIR / "generated_predict.move"


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

    def header(self, module_name: str):
        self.lines.append("// DO NOT EDIT — generated by generate.py")
        self.lines.append(
            "// Source of truth: scipy.stats.norm + Black-Scholes + SVI"
        )
        self.lines.append(
            "// Regenerate: cd tests/generated_tests && python3 generate.py"
        )
        self.lines.append("")
        self.lines.append("#[test_only]")
        self.lines.append(f"module deepbook_predict::{module_name};")
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
# Operating range analysis
# ====================================================================


# ====================================================================
# Protocol & provider bounds (inputs to operating range analysis)
# ====================================================================

# Protocol quote bounds: only produce quotes between 0.1c and 99.9c
MIN_QUOTE_PRICE = 0.001   # 0.1 cent
MAX_QUOTE_PRICE = 0.999   # 99.9 cents

# Block Scholes provider SVI parameter bounds.
# Source: provider enforces via butterfly no-arb, positive min variance,
# and calendar consistency across expiries.
# a, m: market-dependent, no fixed global bounds from provider.
# Constraint: a + b * sigma * sqrt(1 - rho^2) >= 0
SVI_B_MIN = 1e-4
SVI_B_MAX = 1.0
SVI_RHO_MAX_ABS = 0.95       # |rho| < 1, provider caps at 0.95
SVI_SIGMA_MIN = 1e-3
SVI_SIGMA_MAX = 100.0

# Lee's moment formula: b * (1 + |rho|) <= 2
# With |rho| = 0.95: b <= 2 / 1.95 = 1.026 → b_max=1.0 is valid
LEE_BOUND = 2.0

# Conservative upper bound on 'a' — not provider-bounded, but
# a > 1 would mean >100% base total variance, unrealistic
A_MAX_CONSERVATIVE = 1.0

# Max risk-free rate and time to expiry we support
MAX_RATE = 0.15
MAX_TIME_YEARS = 1.0


def compute_smart_contract_bounds():
    """
    Derive on-chain validation constants from protocol quote bounds
    and provider SVI parameter bounds.

    Returns a dict of constants ready to be enforced in Move smart contracts.

    Pricing pipeline (forward direction):
      SVI params → ln(strike/forward) → total_var → d2 → normal_cdf → price
      rate + time → exp(-rt) → discount
      final_price = discount * cdf(d2)

    We work backwards from the quote clamp to derive what each
    function's inputs must be bounded to.
    """

    # ================================================================
    # Derived: discount factor bounds
    # ================================================================
    # discount = exp(-r * t)
    MAX_RT = MAX_RATE * MAX_TIME_YEARS
    MIN_DISCOUNT = math.exp(-MAX_RT)

    # ================================================================
    # Derived: normal_cdf input bounds
    # ================================================================
    # price = discount * CDF(d2)
    # CDF(d2) = price / discount
    #
    # At discount=1 (no discounting):
    #   CDF range = [MIN_QUOTE, MAX_QUOTE] = [0.001, 0.999]
    #   d2 range = [ppf(0.001), ppf(0.999)] = [-3.09, +3.09]
    #
    # At min discount (max rate, max time):
    #   CDF upper = MAX_QUOTE / MIN_DISCOUNT = 0.999 / 0.861 = 1.161
    #   Capped at 1.0 → d2 upper unconstrained from this side
    #   CDF lower = MIN_QUOTE / 1.0 = 0.001 (discount helps the lower end)
    #
    # The binding constraint is the lower end (deep OTM), giving |d2| ≈ 3.09
    # But with discount < 1, the upper CDF can exceed MAX_QUOTE at d2 values
    # beyond ppf(MAX_QUOTE), up to ppf(MAX_QUOTE / MIN_DISCOUNT)
    d2_at_min_quote = norm.ppf(MIN_QUOTE_PRICE)
    d2_at_max_quote = norm.ppf(MAX_QUOTE_PRICE)
    cdf_upper_with_discount = min(MAX_QUOTE_PRICE / MIN_DISCOUNT, 1.0)
    d2_at_max_with_discount = norm.ppf(min(cdf_upper_with_discount, 0.9999999))
    MAX_ABS_D2 = max(abs(d2_at_min_quote), abs(d2_at_max_quote),
                     abs(d2_at_max_with_discount))

    # ================================================================
    # Derived: exp bounds (inside cdf_pdf)
    # ================================================================
    # cdf_pdf computes exp(-x^2/2) where x = |d2|
    MAX_EXP_CDF_INPUT = MAX_ABS_D2 ** 2 / 2

    # ================================================================
    # Derived: total variance bounds
    # ================================================================
    # tv = a + b * (rho*(k-m) + sqrt((k-m)^2 + sigma^2))
    # Min: provider enforces a + b*sigma*sqrt(1-rho^2) >= 0, so tv > 0
    # Max at ATM (k=0): a + b*sigma
    TV_MAX = A_MAX_CONSERVATIVE + SVI_B_MAX * SVI_SIGMA_MAX

    # ================================================================
    # Derived: ln bounds (strike/forward ratio)
    # ================================================================
    # d2 = (-k - tv/2) / sqrt(tv)
    # |d2| <= MAX_ABS_D2
    # Solving for k: |k| <= |d2| * sqrt(tv) + tv/2
    # With large tv, this can be very large — meaning ln itself
    # doesn't need a bound, the SVI params + quote clamp handle it.
    # But we can compute the theoretical max for documentation:
    MAX_ABS_K = MAX_ABS_D2 * math.sqrt(TV_MAX) + TV_MAX / 2
    MAX_STRIKE_RATIO = math.exp(MAX_ABS_K)
    MIN_STRIKE_RATIO = math.exp(-MAX_ABS_K)

    # ================================================================
    # Build output: smart contract constants
    # ================================================================
    bounds = {
        "on_chain_constants": {
            # --- update_svi validation ---
            "svi_b_min": to_float_scaled(SVI_B_MIN),
            "svi_b_max": to_float_scaled(SVI_B_MAX),
            "svi_rho_max": to_float_scaled(SVI_RHO_MAX_ABS),
            "svi_sigma_min": to_float_scaled(SVI_SIGMA_MIN),
            "svi_sigma_max": to_float_scaled(SVI_SIGMA_MAX),
            # Lee's moment formula: b * (FLOAT + rho) <= 2 * FLOAT
            "lee_bound_scaled": to_float_scaled(LEE_BOUND),
            # Min variance: a + b*sigma*sqrt(FLOAT^2 - rho^2) / FLOAT >= 0

            # --- compute_discount validation ---
            "max_rt": to_float_scaled(MAX_RT),

            # --- normal_cdf operating range ---
            "max_abs_d2": to_float_scaled(MAX_ABS_D2),

            # --- quote clamp (applied after pricing) ---
            "min_quote": to_usdc(MIN_QUOTE_PRICE),
            "max_quote": to_usdc(MAX_QUOTE_PRICE),
        },
        "derived_info": {
            "d2_range_no_discount": (d2_at_min_quote, d2_at_max_quote),
            "d2_range_with_discount": (d2_at_min_quote, d2_at_max_with_discount),
            "max_abs_d2": MAX_ABS_D2,
            "min_discount": MIN_DISCOUNT,
            "max_exp_cdf_input": MAX_EXP_CDF_INPUT,
            "tv_max": TV_MAX,
            "max_abs_k": MAX_ABS_K,
            "strike_ratio_range": (MIN_STRIKE_RATIO, MAX_STRIKE_RATIO),
        },
    }

    return bounds


def print_operating_ranges():
    """Print smart contract bounds derived from quote clamp + provider SVI bounds."""
    b = compute_smart_contract_bounds()
    constants = b["on_chain_constants"]
    derived = b["derived_info"]

    print("\n" + "=" * 80)
    print("  SMART CONTRACT BOUNDS")
    print(f"  Derived from: quote clamp [{MIN_QUOTE_PRICE}, {MAX_QUOTE_PRICE}]")
    print(f"              + Block Scholes provider SVI bounds")
    print("=" * 80)

    print(f"\n  INPUTS")
    print(f"  {'─'*76}")
    print(f"    Quote clamp:     [{MIN_QUOTE_PRICE}, {MAX_QUOTE_PRICE}]")
    print(f"    SVI b:           [{SVI_B_MIN}, {SVI_B_MAX}]")
    print(f"    SVI |rho|:       [0, {SVI_RHO_MAX_ABS}]")
    print(f"    SVI sigma:       [{SVI_SIGMA_MIN}, {SVI_SIGMA_MAX}]")
    print(f"    Lee bound:       b*(1+|rho|) <= {LEE_BOUND}")
    print(f"    Max rate:        {MAX_RATE}")
    print(f"    Max time:        {MAX_TIME_YEARS} year")

    print(f"\n  ON-CHAIN CONSTANTS (FLOAT_SCALING = 1e9, USDC = 1e6)")
    print(f"  {'─'*76}")
    print(f"    // update_svi validation")
    print(f"    SVI_B_MIN:       {constants['svi_b_min']:>20,}")
    print(f"    SVI_B_MAX:       {constants['svi_b_max']:>20,}")
    print(f"    SVI_RHO_MAX:     {constants['svi_rho_max']:>20,}")
    print(f"    SVI_SIGMA_MIN:   {constants['svi_sigma_min']:>20,}")
    print(f"    SVI_SIGMA_MAX:   {constants['svi_sigma_max']:>20,}")
    print(f"    LEE_BOUND:       {constants['lee_bound_scaled']:>20,}  // b*(FLOAT+rho) <= this")
    print(f"")
    print(f"    // compute_discount validation")
    print(f"    MAX_RT:          {constants['max_rt']:>20,}")
    print(f"")
    print(f"    // normal_cdf operating range")
    print(f"    MAX_ABS_D2:      {constants['max_abs_d2']:>20,}")
    print(f"")
    print(f"    // quote clamp (applied after pricing)")
    print(f"    MIN_QUOTE:       {constants['min_quote']:>20,}  // 0.1 cent in USDC")
    print(f"    MAX_QUOTE:       {constants['max_quote']:>20,}  // 99.9 cents in USDC")

    print(f"\n  DERIVED (for documentation, not enforced on-chain)")
    print(f"  {'─'*76}")
    d = derived
    print(f"    d2 range (no discount):   [{d['d2_range_no_discount'][0]:+.4f}, {d['d2_range_no_discount'][1]:+.4f}]")
    print(f"    d2 range (with discount): [{d['d2_range_with_discount'][0]:+.4f}, {d['d2_range_with_discount'][1]:+.4f}]")
    print(f"    max |d2|:                 {d['max_abs_d2']:.4f}")
    print(f"    min discount:             {d['min_discount']:.9f}")
    print(f"    max exp input (cdf_pdf):  {d['max_exp_cdf_input']:.4f}")
    print(f"    max total_var:            {d['tv_max']:.4f}")
    print(f"    max |k| = |ln(S/F)|:      {d['max_abs_k']:.4f}")
    print(f"    strike/forward range:     [{d['strike_ratio_range'][0]:.6f}, {d['strike_ratio_range'][1]:.6f}]")

    print("=" * 80 + "\n")


# ====================================================================
# Scenario generation
# ====================================================================


def generate_math_constants(w: MoveWriter, bounds: dict):
    max_abs_d2 = bounds["derived_info"]["max_abs_d2"]
    max_exp_input = bounds["derived_info"]["max_exp_cdf_input"]

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

    # --- ln: non-power-of-2 inputs that exercise the series approximation ---
    # ln is not directly bounded by the quote clamp — it receives
    # strike/forward which is constrained by SVI params. With provider
    # bounds (sigma up to 100), the strike ratio is effectively unbounded.
    # These test points exercise the series approximation at various scales.
    w.section("ln — non-trivial inputs (exercise ln_series with nonzero z)")
    for x in [1.5, 3.0, 5.0, 7.0, 10.0, 0.1, 0.3, 0.7, 0.999, 1.001, 100.0, 1000.0]:
        name = str(x).replace(".", "_")
        w.const(f"LN_{name}", to_float_scaled(abs(math.log(x))),
                f"|ln({x})| = {abs(math.log(x)):.15f}")

    # --- exp: bounded by cdf_pdf input range ---
    # In production, exp is called from two places:
    #   1. compute_discount: exp(-rt, true) — max input = MAX_RT
    #   2. cdf_pdf: exp(-d2²/2, true) — max input = max_abs_d2² / 2
    # Both always use x_negative=true. We test positive exp too for
    # function correctness, but cap at the operating range.
    w.section(
        f"exp — operating range: max input = {max_exp_input:.2f} "
        f"(from max |d2| = {max_abs_d2:.4f})"
    )
    exp_points = [0.001, 0.01, 0.1, 0.3, 0.5, 1.5, 2.5]
    # Add points near the operating boundary
    exp_points.append(round(max_exp_input * 0.5, 1))   # 50% of max
    exp_points.append(round(max_exp_input * 0.9, 1))    # 90% of max
    exp_points = sorted(set(exp_points))

    for x in exp_points:
        name = str(x).replace(".", "_")
        w.const(f"EXP_{name}", to_float_scaled(math.exp(x)),
                f"e^{x} = {math.exp(x):.15f}")
        w.const(f"EXP_NEG_{name}", to_float_scaled(math.exp(-x)),
                f"e^(-{x}) = {math.exp(-x):.15f}")

    # --- normal_cdf: bounded by quote clamp ---
    # Protocol produces quotes between 0.1c and 99.9c.
    # price = discount * CDF(d2), so CDF operates in a range that
    # maps to |d2| <= {max_abs_d2:.4f}.
    # We generate dense coverage within this range, plus the contract's
    # clamp boundary at x = 8*FLOAT.
    w.section(
        f"Normal CDF — operating range: |d2| <= {max_abs_d2:.4f} "
        f"(from {MIN_QUOTE_PRICE*100:.1f}c—{MAX_QUOTE_PRICE*100:.1f}c quote bounds)"
    )

    # Dense coverage within operating range [0, ceil(max_abs_d2)]
    cdf_limit = math.ceil(max_abs_d2 * 2) / 2  # round up to nearest 0.5
    cdf_points = [0, 0.01, 0.05, 0.1, 0.75, 1.0, 1.5, 2.0, 2.5, 3.0]
    # Add the boundary point
    cdf_boundary = round(max_abs_d2, 2)
    if cdf_boundary not in cdf_points:
        cdf_points.append(cdf_boundary)
    # Add the contract's clamp boundary (tests the early-return path)
    cdf_points.append(8.0)
    cdf_points = sorted(set(cdf_points))

    for x in cdf_points:
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


def generate_oracle_scenarios(w: MoveWriter, indexed_snapshots, svi_rows, expiry_ms):
    w.section("Oracle pricing scenarios from real Block Scholes data")
    w.comment("Sampled by time-to-expiry diversity across operating range")
    w.comment(f"MTM values use quantity = {ORACLE_TEST_QUANTITY}")
    w.comment(f"Strikes filtered to quote bounds [{MIN_QUOTE_PRICE}, {MAX_QUOTE_PRICE}]")

    for idx, price_row in indexed_snapshots:
        prefix = f"S{idx}"
        result = emit_snapshot(w, prefix, price_row, svi_rows, expiry_ms)
        if result is None:
            continue
        svi_f, _, t, forward = result

        # Candidate strikes — ATM plus offsets
        candidates = [
            ("ATM", forward),
            ("OTM5", forward * 1.05),
            ("OTM10", forward * 1.10),
            ("ITM5", forward * 0.95),
            ("ITM10", forward * 0.90),
        ]

        for label, strike in candidates:
            up = binary_price(
                forward, strike, svi_f["a"], svi_f["b"], svi_f["rho"],
                svi_f["m"], svi_f["sigma"], svi_f["rate"], t, True,
            )
            dn = binary_price(
                forward, strike, svi_f["a"], svi_f["b"], svi_f["rho"],
                svi_f["m"], svi_f["sigma"], svi_f["rate"], t, False,
            )

            # Skip strikes where price falls outside quotable range
            if up < MIN_QUOTE_PRICE and dn < MIN_QUOTE_PRICE:
                w.comment(f"{prefix}_{label}: skipped (price outside quote bounds)")
                continue

            up_mtm = up * ORACLE_TEST_QUANTITY
            dn_mtm = dn * ORACLE_TEST_QUANTITY
            w.const(f"{prefix}_STRIKE_{label}", to_float_scaled(strike))
            w.const(f"{prefix}_UP_{label}", to_float_scaled(up))
            w.const(f"{prefix}_DN_{label}", to_float_scaled(dn))
            w.const(f"{prefix}_MTM_UP_{label}", to_usdc(up_mtm))
            w.const(f"{prefix}_MTM_DN_{label}", to_usdc(dn_mtm))


def generate_mint_scenarios(w: MoveWriter, indexed_snapshots, svi_rows, expiry_ms):
    w.section("Mint pricing scenarios from real Block Scholes data")
    w.comment("Spread + cost calculations across TTE regimes.")
    w.comment(f"Prices filtered to quote bounds [{MIN_QUOTE_PRICE}, {MAX_QUOTE_PRICE}]")
    w.comment(
        f"Default config: base_spread={DEFAULT_BASE_SPREAD}, "
        f"min_spread={DEFAULT_MIN_SPREAD}, util_mult={DEFAULT_UTIL_MULTIPLIER}"
    )

    # (suffix, is_call, strike_factor, quantity, util_pct)
    MINT_CASES_FULL = [
        ("ATM_UP", True, 1.00, 10.0, 0),
        ("ATM_DN", False, 1.00, 10.0, 0),
        ("OTM_UP", True, 1.10, 10.0, 0),
        ("ITM_UP", True, 0.90, 10.0, 0),
        ("ATM_UP_SMALL", True, 1.00, 0.001, 0),
        ("ATM_UP_LARGE", True, 1.00, 500.0, 0),
    ]
    MINT_CASES_CORE = [
        ("ATM_UP", True, 1.00, 10.0, 0),
        ("ATM_DN", False, 1.00, 10.0, 0),
        ("OTM_UP", True, 1.10, 10.0, 0),
        ("ITM_UP", True, 0.90, 10.0, 0),
    ]

    for idx, price_row, is_primary in indexed_snapshots:
        prefix = f"M{idx}"
        mint_cases = MINT_CASES_FULL if is_primary else MINT_CASES_CORE
        result = emit_snapshot(w, prefix, price_row, svi_rows, expiry_ms)
        if result is None:
            continue
        svi_f, _, t, forward = result

        vault_balance = forward * 10

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
            # Skip strikes where price falls outside quotable range
            if price < MIN_QUOTE_PRICE or price > MAX_QUOTE_PRICE:
                continue

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
            w.const(f"{label}_COST", to_usdc(cost))
            w.const(f"{label}_REDEEM_PAYOUT", to_usdc(redeem_payout))


# ====================================================================
# Synthetic oracle scenarios (hand-picked params to isolate behaviors)
# ====================================================================


def find_strikes_in_quote_range(
    forward: float, svi: dict, rate: float, t: float,
    target_d2s: list[float],
) -> list[tuple[str, float, float]]:
    """Find strikes that produce specific d2 values, filtering to quote bounds.

    Returns list of (label, strike, up_price) tuples where the price is
    within [MIN_QUOTE_PRICE, MAX_QUOTE_PRICE].
    """
    from scipy.optimize import brentq

    results = []
    discount = math.exp(-rate * t)

    for d2_target in target_d2s:
        # Compute what CDF(d2) and price would be
        cdf_val = norm.cdf(d2_target)
        price = discount * cdf_val

        if price < MIN_QUOTE_PRICE or price > MAX_QUOTE_PRICE:
            continue

        # Reverse-solve for strike: find strike where d2 = target
        # d2(strike) is monotonically decreasing in strike (for UP)
        def d2_at_strike(s):
            if s <= 0:
                return 100.0
            k = math.log(s / forward)
            tv = svi_total_variance(k, svi["a"], svi["b"], svi["rho"], svi["m"], svi["sigma"])
            if tv <= 0:
                return 100.0
            return (-k - tv / 2) / math.sqrt(tv) - d2_target

        try:
            strike = brentq(d2_at_strike, forward * 0.001, forward * 100.0)
        except ValueError:
            continue

        # Label based on d2 value
        if abs(d2_target) < 0.01:
            label = "ATM"
        elif d2_target > 0:
            label = f"ITM_D{abs(d2_target):.0f}" if d2_target == int(d2_target) else f"ITM_D{abs(d2_target):.1f}"
        else:
            label = f"OTM_D{abs(d2_target):.0f}" if d2_target == int(d2_target) else f"OTM_D{abs(d2_target):.1f}"

        results.append((label, strike, price))

    return results


def generate_synthetic_oracle_scenarios(w: MoveWriter, bounds: dict):
    max_abs_d2 = bounds["derived_info"]["max_abs_d2"]

    w.section("Synthetic oracle scenarios")
    w.comment("SVI params to test specific pricing behaviors.")
    w.comment(f"Strikes chosen so prices fall within quote bounds [{MIN_QUOTE_PRICE}, {MAX_QUOTE_PRICE}].")
    w.comment(f"Operating range: |d2| <= {max_abs_d2:.2f}")
    w.comment("Move tests must construct oracles that produce matching t values.")

    forward = 100.0

    # Short TTE (~0.0000317 years). Move tests: expiry=1_000_000ms, clock=0.
    t_short = 1e6 / (SECONDS_IN_YEAR * 1000)

    # Target d2 values within operating range — evenly spaced
    target_d2s = [-2.0, -1.0, 0.0, 1.0, 2.0]

    # --- Standard SVI: a=0, b=1, rho=0, m=0, sigma=0.25, rate=0 ---
    std = {"a": 0.0, "b": 1.0, "rho": 0.0, "m": 0.0, "sigma": 0.25}

    w.blank()
    w.comment(f"Standard SVI (a=0, b=1, rho=0, m=0, sigma=0.25), rate=0, t={t_short:.10f}yr")

    strikes_std = find_strikes_in_quote_range(forward, std, 0.0, t_short, target_d2s)
    for label, strike, _ in strikes_std:
        up = binary_price(forward, strike, **std, rate=0.0, t=t_short, is_call=True)
        dn = binary_price(forward, strike, **std, rate=0.0, t=t_short, is_call=False)
        w.const(f"SYN_STD_STRIKE_{label}", to_float_scaled(strike),
                f"strike={strike:.4f}")
        w.const(f"SYN_STD_UP_{label}", to_float_scaled(up))
        w.const(f"SYN_STD_DN_{label}", to_float_scaled(dn))

    # --- With 5% rate, t=1 year ---
    w.blank()
    t_1yr = 1.0
    discount_5pct = math.exp(-0.05 * t_1yr)
    w.comment(f"Standard SVI with 5% rate, t={t_1yr}yr")
    w.const("SYN_DISCOUNT_5PCT_1YR", to_float_scaled(discount_5pct),
            f"e^(-0.05*{t_1yr}) = {discount_5pct:.9f}")

    strikes_5pct = find_strikes_in_quote_range(forward, std, 0.05, t_1yr, target_d2s)
    for label, strike, _ in strikes_5pct:
        up = binary_price(forward, strike, **std, rate=0.05, t=t_1yr, is_call=True)
        dn = binary_price(forward, strike, **std, rate=0.05, t=t_1yr, is_call=False)
        w.const(f"SYN_5PCT_STRIKE_{label}", to_float_scaled(strike),
                f"strike={strike:.4f}")
        w.const(f"SYN_5PCT_UP_{label}", to_float_scaled(up))
        w.const(f"SYN_5PCT_DN_{label}", to_float_scaled(dn))

    # --- With 10% rate, t=0.5 years ---
    w.blank()
    t_half = 0.5
    discount_10pct_half = math.exp(-0.10 * t_half)
    w.comment(f"Standard SVI with 10% rate, t={t_half}yr")
    w.const("SYN_DISCOUNT_10PCT_HALF_YR", to_float_scaled(discount_10pct_half),
            f"e^(-0.10*{t_half}) = {discount_10pct_half:.9f}")

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
    full = {"a": 0.05, "b": 0.8, "rho": -0.3, "m": 0.1, "sigma": 0.2}
    w.comment(f"Full SVI (a=0.05, b=0.8, rho=-0.3, m=0.1, sigma=0.2), rate=0, t={t_short:.10f}yr")
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

    # --- Negative rho: rho=-0.3, strikes within quote range ---
    w.blank()
    w.comment(f"Negative rho (rho=-0.3), rate=0, t={t_short:.10f}yr — skews the smile")
    neg_rho = {**std, "rho": -0.3}
    strikes_rho = find_strikes_in_quote_range(forward, neg_rho, 0.0, t_short,
                                               [-2.0, -1.0, 0.0, 1.0, 2.0])
    for label, strike, _ in strikes_rho:
        up = binary_price(forward, strike, **neg_rho, rate=0.0, t=t_short, is_call=True)
        dn = binary_price(forward, strike, **neg_rho, rate=0.0, t=t_short, is_call=False)
        w.const(f"SYN_NEG_RHO_STRIKE_{label}", to_float_scaled(strike))
        w.const(f"SYN_NEG_RHO_UP_{label}", to_float_scaled(up))
        w.const(f"SYN_NEG_RHO_DN_{label}", to_float_scaled(dn))

    # --- Nonzero m: m=0.1, strikes within quote range ---
    w.blank()
    w.comment(f"Nonzero m (m=0.1), rate=0, t={t_short:.10f}yr — shifts the smile center")
    nonzero_m = {**std, "m": 0.1}
    strikes_m = find_strikes_in_quote_range(forward, nonzero_m, 0.0, t_short,
                                             [-2.0, -1.0, 0.0, 1.0, 2.0])
    for label, strike, _ in strikes_m:
        up = binary_price(forward, strike, **nonzero_m, rate=0.0, t=t_short, is_call=True)
        dn = binary_price(forward, strike, **nonzero_m, rate=0.0, t=t_short, is_call=False)
        w.const(f"SYN_M_STRIKE_{label}", to_float_scaled(strike))
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

    steps = generate_trade_sequence(price_rows, svi_rows, expiry_ms, 15)
    print(f"  Sequence: {len(steps)} steps")
    emit_trade_sequence(w, "sequence", steps)

    w.write(BULK_OUTPUT_FILE)


# ====================================================================
# Main
# ====================================================================


def main():
    bounds = compute_smart_contract_bounds()
    print_operating_ranges()

    print("Loading CSVs...")
    price_rows = load_csv("oracle_prices_mar17.csv")
    svi_rows = load_csv("oracle_svi_mar17.csv")

    first_ts_ms = int(price_rows[0]["checkpoint_timestamp_ms"])
    expiry_ms = first_ts_ms + 7 * 24 * 3600 * 1000

    # Diversity-sample snapshots for scenario generation
    all_snapshots = sample_diverse(price_rows, svi_rows, expiry_ms)
    print(f"Sampled {len(all_snapshots)} diverse snapshots:")
    for i, r in enumerate(all_snapshots):
        tte_ms = expiry_ms - int(r["checkpoint_timestamp_ms"])
        print(f"  [{i}] tte={tte_ms / 1000:.0f}s, forward={int(r['forward']) / 1e9:.2f}")

    # Filter to non-redundant snapshots and renumber contiguously.
    # Original indices: 0=7d, 1=5.9d, 2=3.3d, 3=1.2d, 4=5h, 5=1h, 6=2m, 7=31s
    # Oracle keep: 0, 3, 4, 5, 6, 7 → S0-S5
    oracle_keep = [0, 3, 4, 5, 6, 7]
    oracle_snapshots = [
        (new_idx, all_snapshots[orig_idx])
        for new_idx, orig_idx in enumerate(oracle_keep)
        if orig_idx < len(all_snapshots)
    ]

    # Mint keep: 0, 3, 5, 6, 7 → M0-M4
    # M0 is primary (gets all 8 mint cases), others get core 4 only
    mint_keep = [0, 3, 5, 6, 7]
    mint_snapshots = [
        (new_idx, all_snapshots[orig_idx], orig_idx == 0)
        for new_idx, orig_idx in enumerate(mint_keep)
        if orig_idx < len(all_snapshots)
    ]

    print(f"\nOracle snapshots: {len(oracle_snapshots)} (S0-S{len(oracle_snapshots)-1})")
    print(f"Mint snapshots: {len(mint_snapshots)} (M0-M{len(mint_snapshots)-1})")

    # 1. Math constants (ln, exp, cdf) → math_tests.move
    print("\nGenerating math constants...")
    w = MoveWriter()
    w.header("generated_math")
    generate_math_constants(w, bounds)
    w.write(MATH_OUTPUT)

    # 2. Oracle scenarios (synthetic + real-world pricing + MTM) → oracle_tests.move, vault_tests.move
    print("\nGenerating oracle scenarios...")
    w = MoveWriter()
    w.header("generated_oracle")
    generate_synthetic_oracle_scenarios(w, bounds)
    generate_oracle_scenarios(w, oracle_snapshots, svi_rows, expiry_ms)
    w.write(ORACLE_OUTPUT)

    # 3. Mint pricing scenarios → predict_tests.move
    print("\nGenerating mint scenarios...")
    w = MoveWriter()
    w.header("generated_predict")
    generate_mint_scenarios(w, mint_snapshots, svi_rows, expiry_ms)
    w.write(PREDICT_OUTPUT)

    # 4. Bulk trade sequences → predict_sequence_tests.move (already separate)
    print("\nGenerating bulk scenarios...")
    generate_bulk_file(price_rows, svi_rows, expiry_ms)


if __name__ == "__main__":
    main()
