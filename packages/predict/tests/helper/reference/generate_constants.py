#!/usr/bin/env python3
"""Independent reference values for Predict's fixed-point math tests.

Ground truth comes ONLY from Python's stdlib `math` (double precision, ~15-16
significant digits — far more than the 1e9 / 9-digit fixed-point needs). NOTHING
here reads or depends on the Move contract, so the values are an independent
oracle, not a snapshot of contract output (unit-tests rule 1).

Each reference is `round(f_true(x) * 1e9)` — the correctly-rounded fixed-point
representation of the true mathematical value. The Move tests assert the contract
is within ONE fixed-point unit of this (the representation granularity: a correct
floor/ceil/round result is <= 1 unit from truth). A deviation > 1 unit is genuine
approximation error beyond rounding, independent of the (undocumented) rounding
convention.

Run: python3 generate_constants.py   (no third-party deps)
"""
import math

F = 1_000_000_000


def scaled(x: float) -> int:
    return round(x * F)


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
]

if __name__ == "__main__":
    for name, val in POINTS:
        print(f"{name},{val}")
