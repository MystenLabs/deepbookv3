#!/usr/bin/env python3
"""Generate independent true-model pricing references and ex-ante error bounds.

The profiles below are committed synthetic inputs that satisfy Predict's production
pricing envelope. Expected values use Python's stdlib real math, not the Move
implementation or the fixed-point simulation replay. Tolerances are computed before
Move execution by propagating intervals from the precision contracts documented in
fixed_math::math and the exact rounding directions in fixed_math::i64.

Run from the repository root:

    python3 packages/predict/tests/reference/generate_pricing_reference.py
    python3 packages/predict/tests/reference/generate_pricing_reference.py --check
"""

from __future__ import annotations

import argparse
import math
from dataclasses import dataclass
from pathlib import Path

F = 1_000_000_000
ULP = 1.0 / F
LN_RELATIVE_ERROR = 1e-7
NORMAL_CDF_ABS_ERROR = 20 * ULP
NORMAL_PDF_ABS_ERROR = 50 * ULP
REFERENCE_ROUNDING_CUSHION = 2
# A pricing reference may accept at most 0.1 basis point of payout probability.
# This product-level ceiling is declared independently of profiles and Move output.
MAX_ABSOLUTE_TOLERANCE = 10_000
U64_MAX = (1 << 64) - 1
MAX_PRICING_BASIS_FACTOR = 100
MAX_PRICING_SPOT = U64_MAX // MAX_PRICING_BASIS_FACTOR
MIN_SVI_SIGMA = 1_000_000
MAX_SVI_INPUT = 100 * F

HERE = Path(__file__).resolve().parent
OUTPUT = HERE / "pricing_reference_data.move"


@dataclass(frozen=True)
class Interval:
    lo: float
    hi: float

    def __post_init__(self) -> None:
        if not math.isfinite(self.lo) or not math.isfinite(self.hi) or self.lo > self.hi:
            raise ValueError(f"invalid interval [{self.lo}, {self.hi}]")

    def add(self, other: "Interval") -> "Interval":
        return Interval(self.lo + other.lo, self.hi + other.hi)

    def sub(self, other: "Interval") -> "Interval":
        return Interval(self.lo - other.hi, self.hi - other.lo)

    def neg(self) -> "Interval":
        return Interval(-self.hi, -self.lo)


@dataclass(frozen=True)
class Profile:
    name: str
    spot: int
    forward: int
    a: int
    a_negative: bool
    b: int
    sigma: int
    rho: int
    rho_negative: bool
    m: int
    m_negative: bool
    source_timestamp_ms: int
    strikes: tuple[int, ...]


PROFILES = (
    Profile(
        name="flat_medium_variance",
        spot=100_000_000_000,
        forward=100_000_000_000,
        a=10_000_000,
        a_negative=False,
        b=0,
        sigma=200_000_000,
        rho=0,
        rho_negative=False,
        m=0,
        m_negative=False,
        source_timestamp_ms=119_000,
        strikes=(
            80_000_000_000,
            90_000_000_000,
            100_000_000_000,
            110_000_000_000,
            120_000_000_000,
        ),
    ),
    Profile(
        name="negative_skew_medium_variance",
        spot=100_000_000_000,
        forward=101_000_000_000,
        a=2_000_000,
        a_negative=False,
        b=40_000_000,
        sigma=180_000_000,
        rho=350_000_000,
        rho_negative=True,
        m=15_000_000,
        m_negative=False,
        source_timestamp_ms=119_001,
        strikes=(
            85_000_000_000,
            95_000_000_000,
            101_000_000_000,
            107_000_000_000,
            117_000_000_000,
        ),
    ),
    Profile(
        name="negative_skew_small_variance",
        spot=100_000_000_000,
        forward=100_000_000_000,
        a=80_000,
        a_negative=False,
        b=4_000_000,
        sigma=8_000_000,
        rho=250_000_000,
        rho_negative=True,
        m=5_000_000,
        m_negative=True,
        source_timestamp_ms=119_002,
        strikes=(
            97_000_000_000,
            99_000_000_000,
            100_000_000_000,
            101_000_000_000,
            103_000_000_000,
        ),
    ),
)


def fixed_mul_down(left: int, right: int) -> int:
    return left * right // F


def fixed_sqrt_down(value: int) -> int:
    return math.isqrt(value * F)


def validate_production_envelope(profile: Profile) -> None:
    """Fail before generation when a profile cannot enter Predict pricing.

    These integer checks reproduce only the input envelope in
    packages/predict/sources/pricing/pricing.move. They do not contribute to the
    independent true-model values or acceptance tolerances.
    """

    if profile.spot <= 0 or profile.forward <= 0:
        raise ValueError(f"{profile.name}: spot and forward must be positive")
    if profile.spot > MAX_PRICING_SPOT or profile.forward > MAX_PRICING_SPOT:
        raise ValueError(f"{profile.name}: spot or forward exceeds the pricing ceiling")
    minimum_spot = (
        profile.forward + MAX_PRICING_BASIS_FACTOR - 1
    ) // MAX_PRICING_BASIS_FACTOR
    if minimum_spot > profile.spot:
        raise ValueError(f"{profile.name}: forward exceeds the permitted spot basis")
    if profile.a > MAX_SVI_INPUT or profile.b > MAX_SVI_INPUT or profile.m > MAX_SVI_INPUT:
        raise ValueError(f"{profile.name}: a, b, or m exceeds the SVI input ceiling")
    if profile.rho > F:
        raise ValueError(f"{profile.name}: |rho| exceeds one")
    if not MIN_SVI_SIGMA <= profile.sigma <= MAX_SVI_INPUT:
        raise ValueError(f"{profile.name}: sigma is outside the pricing envelope")

    if profile.rho == F:
        minimum_variance_increment = 0
    else:
        one_minus_rho_squared = F - fixed_mul_down(profile.rho, profile.rho)
        minimum_variance_increment = fixed_mul_down(
            profile.b,
            fixed_mul_down(profile.sigma, fixed_sqrt_down(one_minus_rho_squared)),
        )
    minimum_total_variance = (
        minimum_variance_increment - profile.a
        if profile.a_negative
        else minimum_variance_increment + profile.a
    )
    if minimum_total_variance <= 0:
        raise ValueError(f"{profile.name}: minimum fixed-point total variance is not positive")


def validate_profile_sequence() -> None:
    previous_timestamp_ms = 0
    for profile in PROFILES:
        validate_production_envelope(profile)
        if profile.source_timestamp_ms <= previous_timestamp_ms:
            raise ValueError(
                f"{profile.name}: source timestamp {profile.source_timestamp_ms} must be "
                f"strictly greater than {previous_timestamp_ms}"
            )
        previous_timestamp_ms = profile.source_timestamp_ms


def signed(raw: int, negative: bool) -> float:
    value = raw / F
    return -value if negative else value


def clamp01(value: float) -> float:
    return max(0.0, min(1.0, value))


def expand(interval: Interval, error: float) -> Interval:
    return Interval(interval.lo - error, interval.hi + error)


def signed_mul(left: Interval, right: Interval) -> Interval:
    products = (
        left.lo * right.lo,
        left.lo * right.hi,
        left.hi * right.lo,
        left.hi * right.hi,
    )
    return expand(Interval(min(products), max(products)), ULP)


def positive_mul_floor(left: Interval, right: Interval) -> Interval:
    if left.lo < 0 or right.lo < 0:
        raise ValueError("positive fixed-point multiply received a negative interval")
    return Interval(max(0.0, left.lo * right.lo - ULP), left.hi * right.hi)


def square_floor(value: Interval) -> Interval:
    upper = max(value.lo * value.lo, value.hi * value.hi)
    lower = 0.0 if value.lo <= 0 <= value.hi else min(value.lo * value.lo, value.hi * value.hi)
    return Interval(max(0.0, lower - ULP), upper)


def sqrt_floor(value: Interval) -> Interval:
    if value.lo <= 0:
        raise ValueError(f"sqrt interval is not strictly positive: {value}")
    return Interval(max(0.0, math.sqrt(value.lo) - ULP), math.sqrt(value.hi))


def signed_div(numerator: Interval, denominator: Interval) -> Interval:
    if denominator.lo <= 0:
        raise ValueError(f"division denominator is not positive: {denominator}")
    quotients = (
        numerator.lo / denominator.lo,
        numerator.lo / denominator.hi,
        numerator.hi / denominator.lo,
        numerator.hi / denominator.hi,
    )
    return expand(Interval(min(quotients), max(quotients)), ULP)


def normal_cdf_bounds(value: Interval) -> Interval:
    lo = 0.5 * (1.0 + math.erf(value.lo / math.sqrt(2.0)))
    hi = 0.5 * (1.0 + math.erf(value.hi / math.sqrt(2.0)))
    return Interval(clamp01(lo - NORMAL_CDF_ABS_ERROR), clamp01(hi + NORMAL_CDF_ABS_ERROR))


def normal_pdf(value: float) -> float:
    return math.exp(-0.5 * value * value) / math.sqrt(2.0 * math.pi)


def normal_pdf_bounds(value: Interval) -> Interval:
    endpoint_values = (normal_pdf(value.lo), normal_pdf(value.hi))
    maximum = normal_pdf(0.0) if value.lo <= 0 <= value.hi else max(endpoint_values)
    minimum = min(endpoint_values)
    return Interval(
        max(0.0, minimum - NORMAL_PDF_ABS_ERROR),
        maximum + NORMAL_PDF_ABS_ERROR,
    )


def abs_bounds(value: Interval) -> Interval:
    lower = 0.0 if value.lo <= 0 <= value.hi else min(abs(value.lo), abs(value.hi))
    return Interval(lower, max(abs(value.lo), abs(value.hi)))


def correction_bounds(pdf: Interval, w_prime: Interval, sqrt_variance: Interval) -> Interval:
    magnitude = abs_bounds(w_prime)
    denominator_lo = 2.0 * sqrt_variance.lo
    denominator_hi = 2.0 * sqrt_variance.hi
    lower = pdf.lo * magnitude.lo / denominator_hi
    upper = pdf.hi * magnitude.hi / denominator_lo
    return Interval(max(0.0, lower - ULP), upper)


def true_up(profile: Profile, strike: int) -> float:
    forward = profile.forward / F
    k = math.log((strike / F) / forward)
    a = signed(profile.a, profile.a_negative)
    rho = signed(profile.rho, profile.rho_negative)
    m = signed(profile.m, profile.m_negative)
    b = profile.b / F
    sigma = profile.sigma / F
    km = k - m
    root = math.sqrt(km * km + sigma * sigma)
    variance = a + b * (rho * km + root)
    if variance <= 0:
        raise ValueError(f"{profile.name}: non-positive true variance at strike {strike}")
    d2 = -(k + variance / 2.0) / math.sqrt(variance)
    slope = b * (rho + km / root)
    adjusted = 0.5 * (1.0 + math.erf(d2 / math.sqrt(2.0)))
    adjusted -= normal_pdf(d2) * slope / (2.0 * math.sqrt(variance))
    return clamp01(adjusted)


def contract_up_bounds(profile: Profile, strike: int) -> Interval:
    ratio_raw = strike * F // profile.forward
    if ratio_raw <= 0 or ratio_raw > U64_MAX:
        raise ValueError(f"{profile.name}: strike ratio outside finite pricing domain")
    ratio = ratio_raw / F
    exact_log = math.log(ratio)
    log_error = LN_RELATIVE_ERROR * abs(exact_log) + ULP
    k = Interval(exact_log - log_error, exact_log + log_error)

    m = signed(profile.m, profile.m_negative)
    km = k.sub(Interval(m, m))
    km_squared = square_floor(km)
    sigma = Interval(profile.sigma / F, profile.sigma / F)
    sigma_squared = positive_mul_floor(sigma, sigma)
    root = sqrt_floor(km_squared.add(sigma_squared))

    rho = signed(profile.rho, profile.rho_negative)
    rho_km = signed_mul(Interval(rho, rho), km)
    inner = rho_km.add(root)
    if inner.lo < 0:
        raise ValueError(f"{profile.name}: interval cannot prove non-negative SVI inner term")
    variance_increment = positive_mul_floor(Interval(profile.b / F, profile.b / F), inner)
    a = signed(profile.a, profile.a_negative)
    variance = variance_increment.add(Interval(a, a))
    if variance.lo <= 0:
        raise ValueError(f"{profile.name}: interval cannot prove positive total variance")

    sqrt_variance = sqrt_floor(variance)
    half_variance = Interval(max(0.0, variance.lo / 2.0 - 0.5 * ULP), variance.hi / 2.0)
    d2 = signed_div(k.add(half_variance), sqrt_variance).neg()

    slope_ratio = signed_div(km, root)
    slope = slope_ratio.add(Interval(rho, rho))
    w_prime = signed_mul(Interval(profile.b / F, profile.b / F), slope)
    cdf = normal_cdf_bounds(d2)
    correction = correction_bounds(normal_pdf_bounds(d2), w_prime, sqrt_variance)

    if w_prime.lo >= 0:
        adjusted = cdf.sub(correction)
    elif w_prime.hi <= 0:
        adjusted = cdf.add(correction)
    else:
        adjusted = Interval(cdf.lo - correction.hi, cdf.hi + correction.hi)
    return Interval(clamp01(adjusted.lo), clamp01(adjusted.hi))


def up_value_and_bounds(profile: Profile, strike: int | None) -> tuple[float, Interval]:
    if strike is None:
        return 0.0, Interval(0.0, 0.0)
    if strike == 0:
        return 1.0, Interval(1.0, 1.0)
    return true_up(profile, strike), contract_up_bounds(profile, strike)


def range_reference(
    profile: Profile,
    lower: int,
    higher: int | None,
) -> tuple[int, int]:
    lower_true, lower_bounds = up_value_and_bounds(profile, lower)
    higher_true, higher_bounds = up_value_and_bounds(profile, higher)
    true_range = max(0.0, lower_true - higher_true)
    contract_bounds = Interval(
        clamp01(lower_bounds.lo - higher_bounds.hi),
        clamp01(lower_bounds.hi - higher_bounds.lo),
    )
    reference = round(true_range * F)
    reference_real = reference / F
    tolerance = math.ceil(
        max(
            abs(reference_real - contract_bounds.lo),
            abs(contract_bounds.hi - reference_real),
        )
        * F
    ) + REFERENCE_ROUNDING_CUSHION
    if tolerance > MAX_ABSOLUTE_TOLERANCE:
        raise ValueError(
            f"{profile.name}: propagated tolerance {tolerance} exceeds the independently "
            f"declared accuracy ceiling {MAX_ABSOLUTE_TOLERANCE}"
        )
    return reference, tolerance


def profile_points(profile: Profile) -> list[tuple[int, int | None, int, int]]:
    points = []
    for strike in profile.strikes:
        reference, tolerance = range_reference(profile, strike, None)
        points.append((strike, None, reference, tolerance))
    center = profile.strikes[len(profile.strikes) // 2]
    reference, tolerance = range_reference(profile, 0, center)
    points.append((0, center, reference, tolerance))
    lower = profile.strikes[1]
    higher = profile.strikes[-2]
    reference, tolerance = range_reference(profile, lower, higher)
    points.append((lower, higher, reference, tolerance))
    return points


def move_int(value: int) -> str:
    return f"{value:_}"


def move_bool(value: bool) -> str:
    return "true" if value else "false"


def move_strike(value: int | None) -> str:
    return "constants::pos_inf!()" if value is None else move_int(value)


def render() -> str:
    validate_profile_sequence()
    all_points = [profile_points(profile) for profile in PROFILES]
    worst_tolerance = max(point[3] for points in all_points for point in points)
    lines = [
        "// Copyright (c) Mysten Labs, Inc.",
        "// SPDX-License-Identifier: Apache-2.0",
        "//",
        "// @generated by packages/predict/tests/reference/generate_pricing_reference.py",
        "// Regenerate: python3 packages/predict/tests/reference/generate_pricing_reference.py",
        "// Check: python3 packages/predict/tests/reference/generate_pricing_reference.py --check",
        "//",
        "// Committed synthetic production-safe inputs; no external-data provenance claim.",
        "// True values use Python stdlib log/sqrt/erf. Tolerances are ex-ante intervals",
        "// propagated from current fixed_math primitive contracts, never Move output.",
        "// Pyth spot equals BS spot, so current mul_div_down reanchoring returns each",
        "// configured forward exactly.",
        f"// Maximum permitted absolute tolerance: {move_int(MAX_ABSOLUTE_TOLERANCE)} units",
        "// at 1e9 scale (0.1 basis point of payout probability).",
        f"// Worst generated absolute tolerance: {move_int(worst_tolerance)} units at 1e9 scale.",
        "#[test_only]",
        "module deepbook_predict::pricing_reference_data;",
        "",
        "use deepbook_predict::{constants, oracle_profile::{Self, SurfaceProfile}};",
        "",
        "const ENoSuchProfile: u64 = 0;",
        "",
        "public struct RefPoint has copy, drop {",
        "    lower: u64,",
        "    higher: u64,",
        "    reference: u64,",
        "    tolerance: u64,",
        "}",
        "",
        "public fun lower(point: &RefPoint): u64 { point.lower }",
        "",
        "public fun higher(point: &RefPoint): u64 { point.higher }",
        "",
        "public fun reference(point: &RefPoint): u64 { point.reference }",
        "",
        "public fun tolerance(point: &RefPoint): u64 { point.tolerance }",
        "",
        f"public fun profile_count(): u64 {{ {len(PROFILES)} }}",
        "",
        "public fun profile(index: u64): SurfaceProfile {",
    ]
    for index, profile in enumerate(PROFILES):
        prefix = "if" if index == 0 else "else if"
        lines.extend(
            [
                f"    {prefix} (index == {index}) {{",
                f"        // {profile.name}",
                "        oracle_profile::new(",
                f"            {move_int(profile.spot)},",
                f"            {move_int(profile.forward)},",
                f"            {move_int(profile.a)},",
                f"            {move_bool(profile.a_negative)},",
                f"            {move_int(profile.b)},",
                f"            {move_int(profile.sigma)},",
                f"            {move_int(profile.rho)},",
                f"            {move_bool(profile.rho_negative)},",
                f"            {move_int(profile.m)},",
                f"            {move_bool(profile.m_negative)},",
                f"            {move_int(profile.source_timestamp_ms)},",
                "        )",
                "    }",
            ]
        )
    lines.extend(
        [
            "    else {",
            "        abort ENoSuchProfile",
            "    }",
            "}",
            "",
            "public fun points(index: u64): vector<RefPoint> {",
        ]
    )
    for index, (profile, points) in enumerate(zip(PROFILES, all_points, strict=True)):
        prefix = "if" if index == 0 else "else if"
        lines.extend([f"    {prefix} (index == {index}) {{", f"        // {profile.name}", "        vector["])
        for lower, higher, reference, tolerance in points:
            lines.append(
                "            point("
                f"{move_strike(lower)}, {move_strike(higher)}, "
                f"{move_int(reference)}, {move_int(tolerance)}),"
            )
        lines.extend(["        ]", "    }"])
    lines.extend(
        [
            "    else {",
            "        abort ENoSuchProfile",
            "    }",
            "}",
            "",
            "fun point(lower: u64, higher: u64, reference: u64, tolerance: u64): RefPoint {",
            "    RefPoint { lower, higher, reference, tolerance }",
            "}",
            "",
        ]
    )
    return (
        "\n".join(lines)
        .replace("\n    else if", " else if")
        .replace("\n    else {", " else {")
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="fail if committed output is stale")
    args = parser.parse_args()
    rendered = render()
    if args.check:
        if not OUTPUT.exists() or OUTPUT.read_text() != rendered:
            print(f"stale generated reference: {OUTPUT}")
            return 1
        print(f"pricing reference is current: {OUTPUT}")
        return 0
    OUTPUT.write_text(rendered)
    print(f"wrote {OUTPUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
