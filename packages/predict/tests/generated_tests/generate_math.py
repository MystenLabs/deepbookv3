#!/usr/bin/env python3
"""
Generates generated_math.move with ground-truth test vectors for
ln, exp, and normal_cdf.

Each vector combines:
1. Handpicked inputs (mathematical identities, known values)
2. Edge cases (boundaries, extremes, near-zero)
3. Randomized inputs (broad coverage across the full domain)

Source of truth: scipy.stats.norm + Python math
Usage: python3 generate_math.py
Dependencies: pip install scipy
"""

import math
import random
from pathlib import Path

from scipy.stats import norm

# ====================================================================
# Constants
# ====================================================================

FLOAT_SCALING = 1_000_000_000
U64_MAX = 2**64 - 1

DATA_DIR = Path(__file__).parent
MATH_OUTPUT = DATA_DIR / "generated_math.move"

SEED = 42
N_RANDOM_PER_FUNCTION = 200

# exp positive: contract aborts above this with EExpOverflow
MAX_EXP_INPUT = 23_638_153_699

# ====================================================================
# Handpicked + edge case inputs
# ====================================================================

# ln: (input_scaled,) — all must be > 0
LN_HANDPICKED = [
    # Powers of 2 (exercise bit-shift normalization)
    1 * FLOAT_SCALING,       # ln(1) = 0
    2 * FLOAT_SCALING,       # ln(2)
    4 * FLOAT_SCALING,       # ln(4)
    8 * FLOAT_SCALING,       # ln(8)
    16 * FLOAT_SCALING,      # ln(16)
    # Mathematical constants
    2_718_281_828,            # ln(e) ≈ 1
    # Fractions (exercise recursive inversion)
    500_000_000,             # ln(0.5) = -ln(2)
    250_000_000,             # ln(0.25) = -ln(4)
    100_000_000,             # ln(0.1)
    # Near 1 (exercise series convergence)
    999_000_000,             # ln(0.999) — tiny negative
    1_001_000_000,           # ln(1.001) — tiny positive
    # Non-power-of-2 (exercise series with nonzero z)
    1_500_000_000,           # ln(1.5)
    3_000_000_000,           # ln(3)
    5_000_000_000,           # ln(5)
    7_000_000_000,           # ln(7)
    10_000_000_000,          # ln(10)
    100_000_000_000,         # ln(100)
    1_000_000_000_000,       # ln(1000)
]

LN_EDGE_CASES = [
    1,                       # minimum valid input (ln(1e-9))
    2,                       # near minimum
    U64_MAX,                 # maximum u64
    U64_MAX - 1,             # near maximum
    FLOAT_SCALING - 1,       # just below 1.0
    FLOAT_SCALING + 1,       # just above 1.0
]

# exp: (input_scaled, is_negative)
EXP_HANDPICKED = [
    # Identity
    (0, False),                             # e^0 = 1
    (FLOAT_SCALING, False),                 # e^1 = e
    (FLOAT_SCALING, True),                  # e^(-1) = 1/e
    # Powers of 2 (exercise bit-shift path)
    (693_147_180, False),                   # e^ln2 = 2
    (693_147_180, True),                    # e^(-ln2) = 0.5
    (1_386_294_361, False),                 # e^ln4 = 4
    (1_386_294_361, True),                  # e^(-ln4) = 0.25
    (2_079_441_541, False),                 # e^ln8 = 8
    (2_079_441_541, True),                  # e^(-ln8) = 0.125
]

EXP_EDGE_CASES = [
    # Boundary
    (MAX_EXP_INPUT, False),                 # max valid positive input
    (MAX_EXP_INPUT - 1, False),             # one below max
    # Large negative (underflow to 0)
    (50 * FLOAT_SCALING, True),             # e^(-50) → 0
    (U64_MAX, True),                        # max u64 negative → 0
    # Tiny inputs
    (1, False),                             # e^(1e-9) ≈ 1
    (1, True),                              # e^(-1e-9) ≈ 1
]

# exp overflow: inputs that must abort
EXP_OVERFLOW_HANDPICKED = [
    MAX_EXP_INPUT + 1,                      # first overflow
    MAX_EXP_INPUT + 1000,                   # slightly above
    24 * FLOAT_SCALING,                     # round number above boundary
    U64_MAX,                                # max u64
]

# cdf: (input_scaled, is_negative)
CDF_HANDPICKED = [
    # Known values
    (0, False),                             # Φ(0) = 0.5
    (0, True),                              # Φ(-0) = 0.5
    (FLOAT_SCALING, False),                 # Φ(1) ≈ 0.841
    (FLOAT_SCALING, True),                  # Φ(-1) ≈ 0.159
    (2 * FLOAT_SCALING, False),             # Φ(2)
    (2 * FLOAT_SCALING, True),              # Φ(-2)
    (3 * FLOAT_SCALING, False),             # Φ(3)
    (3 * FLOAT_SCALING, True),              # Φ(-3)
]

CDF_EDGE_CASES = [
    # Clamp boundary: 8*FLOAT is the last value that goes through polynomial
    (8 * FLOAT_SCALING, False),             # Φ(8) ≈ FLOAT
    (8 * FLOAT_SCALING, True),              # Φ(-8) ≈ 0
    (8 * FLOAT_SCALING + 1, False),         # just above clamp → FLOAT
    (8 * FLOAT_SCALING + 1, True),          # just above clamp → 0
    # Far beyond clamp
    (U64_MAX, False),                       # → FLOAT
    (U64_MAX, True),                        # → 0
    # Tiny input
    (1, False),                             # Φ(1e-9) ≈ 0.5
    (1, True),                              # Φ(-1e-9) ≈ 0.5
    # Algorithm boundaries (small/medium threshold in Cody approx)
    (662_000_000, False),                   # near SMALL_THRESHOLD (0.66291)
    (662_000_000, True),
    (5_656_000_000, False),                 # near MEDIUM_THRESHOLD (sqrt(32))
    (5_656_000_000, True),
]


# ====================================================================
# Scaling helpers
# ====================================================================


def to_float_scaled(value: float) -> int:
    """Convert to FLOAT_SCALING (1e9), floor-truncated."""
    return int(value * FLOAT_SCALING)


def fmt_u64(value: int) -> str:
    """Format an integer with underscore separators for Move readability."""
    return f"{value:_}"


# ====================================================================
# Ground truth computation
# ====================================================================


def compute_ln(input_scaled: int) -> tuple[int, bool]:
    """Compute ln ground truth from a scaled u64 input."""
    x = input_scaled / FLOAT_SCALING
    val = math.log(x)
    return to_float_scaled(abs(val)), val < 0


def compute_exp(input_scaled: int, is_negative: bool) -> int:
    """Compute exp ground truth from a scaled u64 input."""
    x = input_scaled / FLOAT_SCALING
    return to_float_scaled(math.exp(-x if is_negative else x))


def compute_cdf(input_scaled: int, is_negative: bool) -> int:
    """Compute normal CDF ground truth from a scaled u64 input."""
    x = input_scaled / FLOAT_SCALING
    if x > 8.0:
        return 0 if is_negative else FLOAT_SCALING
    return to_float_scaled(norm.cdf(-x if is_negative else x))


# ====================================================================
# Random input generation
# ====================================================================


def random_ln_inputs(rng: random.Random, n: int) -> list[int]:
    """Log-uniform sample across [1, u64_max] for ln, biased toward small inputs.

    Uses exp^2 to concentrate samples near the low end where the series
    approximation is most sensitive.
    """
    cases = []
    for _ in range(n):
        # Bias toward small: square a uniform [0,1] then scale to exponent range
        t = rng.random() ** 2  # concentrated near 0
        exp = -9 + t * 28.26  # range [-9, 19.26], 10^19.26 ≈ u64_max
        x = min(U64_MAX, max(1, int(10 ** exp)))
        cases.append(x)
    return cases


def random_exp_inputs(rng: random.Random, n: int) -> list[tuple[int, bool]]:
    """Random exp inputs, biased toward small values. Skips trivial zero results.

    Positive: biased sample in [0, MAX_EXP_INPUT].
    Negative: biased sample, retrying if result would be 0.
    """
    cases = []
    half = n // 2

    # Positive: all inputs in range produce nonzero results
    for _ in range(half):
        t = rng.random() ** 2
        x = int(t * MAX_EXP_INPUT)
        cases.append((x, False))

    # Negative: skip inputs where exp(-x) rounds to 0
    attempts = 0
    while len(cases) < n and attempts < n * 10:
        attempts += 1
        t = rng.random() ** 2
        x = int(t * MAX_EXP_INPUT)  # same range as positive, biased toward 0
        expected = compute_exp(x, True)
        if expected > 0:
            cases.append((x, True))

    return cases


def random_exp_overflow_inputs(rng: random.Random, n: int) -> list[int]:
    """Random inputs above MAX_EXP_INPUT that must abort."""
    return [rng.randint(MAX_EXP_INPUT + 1, U64_MAX) for _ in range(n)]


def random_cdf_inputs(rng: random.Random, n: int) -> list[tuple[int, bool]]:
    """Random CDF inputs, biased toward small values. Skips trivial 0/FLOAT results.

    Samples in [0, 8*FLOAT] (the polynomial range). Inputs beyond 8*FLOAT
    are covered by edge cases.
    """
    cdf_max = 8 * FLOAT_SCALING
    cases = []
    half = n // 2
    attempts = 0
    while len(cases) < n and attempts < n * 10:
        attempts += 1
        t = rng.random() ** 2
        x = int(t * cdf_max)
        is_neg = len(cases) >= half
        expected = compute_cdf(x, is_neg)
        # Skip trivial clamp results
        if expected < 1_000 or expected > FLOAT_SCALING - 1_000:
            continue
        cases.append((x, is_neg))

    return cases


# ====================================================================
# Move file writer
# ====================================================================


class MoveWriter:
    """Builds a #[test_only] Move module with generated constants."""

    def __init__(self):
        self.lines: list[str] = []

    def header(self, module_name: str):
        self.lines.append("// DO NOT EDIT — generated by generate_math.py")
        self.lines.append("// Source of truth: scipy.stats.norm + Python math")
        self.lines.append(
            "// Regenerate: cd tests/generated_tests && python3 generate_math.py"
        )
        self.lines.append("")
        self.lines.append("#[test_only]")
        self.lines.append(f"module deepbook_predict::{module_name};")

    def blank(self):
        self.lines.append("")

    def section(self, title: str):
        self.blank()
        self.lines.append(f"// === {title} ===")

    def raw(self, text: str):
        self.lines.append(text)

    def write(self, path: Path):
        with open(path, "w") as f:
            f.write("\n".join(self.lines))
            f.write("\n")
        print(f"Wrote {path} ({len(self.lines)} lines)")


# ====================================================================
# Vector emission
# ====================================================================


def emit_ln_vector(w: MoveWriter, cases: list[int]):
    n = len(cases)
    w.section(f"ln test vector ({n} cases)")
    w.blank()
    w.raw("public struct LnCase has copy, drop {")
    w.raw("    input: u64,")
    w.raw("    expected_mag: u64,")
    w.raw("    expected_neg: bool,")
    w.raw("}")
    w.blank()
    w.raw("public fun ln_input(c: &LnCase): u64 { c.input }")
    w.raw("public fun ln_expected_mag(c: &LnCase): u64 { c.expected_mag }")
    w.raw("public fun ln_expected_neg(c: &LnCase): bool { c.expected_neg }")
    w.blank()
    w.raw("public fun ln_cases(): vector<LnCase> { vector[")

    for input_scaled in cases:
        mag, neg = compute_ln(input_scaled)
        neg_str = "true" if neg else "false"
        w.raw(
            f"    LnCase {{ input: {fmt_u64(input_scaled)}, "
            f"expected_mag: {fmt_u64(mag)}, expected_neg: {neg_str} }},"
        )

    w.raw("]}")


def emit_exp_vector(w: MoveWriter, cases: list[tuple[int, bool]]):
    n = len(cases)
    w.section(f"exp test vector ({n} cases)")
    w.blank()
    w.raw("public struct ExpCase has copy, drop {")
    w.raw("    input: u64,")
    w.raw("    is_negative: bool,")
    w.raw("    expected: u64,")
    w.raw("}")
    w.blank()
    w.raw("public fun exp_input(c: &ExpCase): u64 { c.input }")
    w.raw("public fun exp_is_negative(c: &ExpCase): bool { c.is_negative }")
    w.raw("public fun exp_expected(c: &ExpCase): u64 { c.expected }")
    w.blank()
    w.raw("public fun exp_cases(): vector<ExpCase> { vector[")

    for input_scaled, is_neg in cases:
        expected = compute_exp(input_scaled, is_neg)
        neg_str = "true" if is_neg else "false"
        w.raw(
            f"    ExpCase {{ input: {fmt_u64(input_scaled)}, "
            f"is_negative: {neg_str}, expected: {fmt_u64(expected)} }},"
        )

    w.raw("]}")


def emit_exp_overflow_vector(w: MoveWriter, cases: list[int]):
    n = len(cases)
    w.section(f"exp overflow vector ({n} cases — all must abort)")
    w.blank()
    w.raw("public fun exp_overflow_cases(): vector<u64> { vector[")
    for x in cases:
        w.raw(f"    {fmt_u64(x)},")
    w.raw("]}")


def emit_cdf_vector(w: MoveWriter, cases: list[tuple[int, bool]]):
    n = len(cases)
    w.section(f"Normal CDF test vector ({n} cases)")
    w.blank()
    w.raw("public struct CdfCase has copy, drop {")
    w.raw("    input: u64,")
    w.raw("    is_negative: bool,")
    w.raw("    expected: u64,")
    w.raw("}")
    w.blank()
    w.raw("public fun cdf_input(c: &CdfCase): u64 { c.input }")
    w.raw("public fun cdf_is_negative(c: &CdfCase): bool { c.is_negative }")
    w.raw("public fun cdf_expected(c: &CdfCase): u64 { c.expected }")
    w.blank()
    w.raw("public fun cdf_cases(): vector<CdfCase> { vector[")

    for input_scaled, is_neg in cases:
        expected = compute_cdf(input_scaled, is_neg)
        neg_str = "true" if is_neg else "false"
        w.raw(
            f"    CdfCase {{ input: {fmt_u64(input_scaled)}, "
            f"is_negative: {neg_str}, expected: {fmt_u64(expected)} }},"
        )

    w.raw("]}")


# ====================================================================
# Main
# ====================================================================


def main():
    rng = random.Random(SEED)

    # Build vectors: handpicked + edge cases + random
    ln_cases = LN_HANDPICKED + LN_EDGE_CASES + random_ln_inputs(rng, N_RANDOM_PER_FUNCTION)
    exp_cases = EXP_HANDPICKED + EXP_EDGE_CASES + random_exp_inputs(rng, N_RANDOM_PER_FUNCTION)
    exp_overflow = EXP_OVERFLOW_HANDPICKED + random_exp_overflow_inputs(rng, 16)
    cdf_cases = CDF_HANDPICKED + CDF_EDGE_CASES + random_cdf_inputs(rng, N_RANDOM_PER_FUNCTION)

    w = MoveWriter()
    w.header("generated_math")

    emit_ln_vector(w, ln_cases)
    emit_exp_vector(w, exp_cases)
    emit_exp_overflow_vector(w, exp_overflow)
    emit_cdf_vector(w, cdf_cases)

    w.write(MATH_OUTPUT)


if __name__ == "__main__":
    main()
