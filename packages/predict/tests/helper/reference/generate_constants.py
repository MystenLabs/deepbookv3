#!/usr/bin/env python3
"""Independent reference values for Predict's fixed-point math tests.

Ground truth comes ONLY from Python's stdlib `math` (double precision, ~15-16
significant digits — far more than the 1e9 / 9-digit fixed-point needs). NOTHING
here reads or depends on the Move contract, so the values are an independent
oracle, not a snapshot of contract output (unit-tests rule 1).

Each reference is `round(f_true(x) * 1e9)` — the correctly-rounded fixed-point
representation of the true mathematical value. The Move tests assert the contract
is within its documented per-primitive precision budget of this (math.move
"Precision contract": exp/ln <= 1e-7 relative, normal_cdf <= 2e-8 absolute, sqrt
<= 1 ULP). A deviation beyond budget is a genuine finding (unit-tests rule 15).

Run: python3 generate_constants.py   (no third-party deps)
"""
import math
from decimal import Decimal, getcontext, ROUND_HALF_EVEN

getcontext().prec = 60

F = 1_000_000_000


def scaled(x: float) -> int:
    return round(x * F)


def exp_scaled(num: int, den: int = 1) -> int:
    """exp(num/den) * 1e9 via arbitrary-precision Decimal. Required for magnitudes
    above 2**53 (~9e15), where f64 `math.exp` loses integer-exactness and the
    `round(... * 1e9)` result carries trailing-digit artifacts."""
    return int(((Decimal(num) / Decimal(den)).exp() * Decimal(F)).to_integral_value(ROUND_HALF_EVEN))


def phi(x: float) -> float:  # standard normal CDF via stdlib erf
    return 0.5 * (1.0 + math.erf(x / math.sqrt(2.0)))


POINTS = [
    ("LN_2", scaled(math.log(2))),
    ("LN_10", scaled(math.log(10))),
    ("EXP_1", scaled(math.exp(1))),
    ("EXP_NEG_1", scaled(math.exp(-1))),
    ("EXP_2", scaled(math.exp(2))),
    ("EXP_NEG_2", scaled(math.exp(-2))),
    ("EXP_10", scaled(math.exp(10))),
    ("EXP_NEG_10", scaled(math.exp(-10))),
    ("CDF_HALF", scaled(phi(0.5))),
    ("CDF_NEG_HALF", scaled(phi(-0.5))),
    ("CDF_1", scaled(phi(1.0))),
    ("CDF_NEG_1", scaled(phi(-1.0))),
    ("CDF_2", scaled(phi(2.0))),
    ("CDF_NEG_2", scaled(phi(-2.0))),
    ("CDF_3", scaled(phi(3.0))),
    ("CDF_NEG_3", scaled(phi(-3.0))),
    ("SQRT_2", scaled(math.sqrt(2))),
    ("SQRT_3", scaled(math.sqrt(3))),
    ("SQRT_HALF", scaled(math.sqrt(0.5))),
    # --- Edge / boundary points (completeness audit). Same independent oracle. ---
    # exp: definitely-valid large arg, the u64-fit bound (= EXP_MAX_INPUT/1e9),
    # and the n=0 (x < ln2) series-only path.
    ("EXP_20", exp_scaled(20)), # > 2**53: Decimal-exact, not f64
    ("EXP_AT_U64_FIT_BOUND", exp_scaled(23_638_153_618, F)), # > 2**53: Decimal-exact
    ("EXP_HALF", scaled(math.exp(0.5))),
    # normal_cdf: small/medium split (0.66291), medium/clamp split (sqrt(32)),
    # and deeper tail than the base set (x=4, x=5).
    ("CDF_066291", scaled(phi(662_910_000 / F))),
    ("CDF_SQRT32", scaled(phi(5_656_854_249 / F))),
    ("CDF_4", scaled(phi(4.0))),
    ("CDF_5", scaled(phi(5.0))),
    # ln: smallest input (value 1e-9, magnitude) and the u64::MAX input.
    ("LN_1EM9_MAG", abs(scaled(math.log(1e-9)))),
    ("LN_U64MAX", scaled(math.log((2**64 - 1) / F))),
    ("LN_1_5", scaled(math.log(1.5))),  # x in (F, 2F): non-degenerate Horner series
    # sqrt with non-default precision: sqrt(x, P) == isqrt(x * P) in raw units.
    ("SQRT_4F_PREC_ONE", math.isqrt(4 * F * 1)),
    ("SQRT_U64MAX_PREC_ONE", math.isqrt((2**64 - 1) * 1)),  # high-bit Newton path; = 2^32-1
]

if __name__ == "__main__":
    for name, val in POINTS:
        print(f"{name},{val}")
