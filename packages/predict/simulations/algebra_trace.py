#!/usr/bin/env python3
"""Trace Predict's mint-centered algebra without changing canonical replay values."""

from __future__ import annotations

import argparse
import json
import math
from collections import Counter, defaultdict
from dataclasses import dataclass
from fractions import Fraction
from pathlib import Path
from typing import Any

import python_replay as replay

SCHEMA_VERSION = "predict_algebra_trace_v2"
CONTRACT_BASELINE = "4d5206a3a197e5b48cacf84c7fcb4ba18fb54a55"
PRICING_PROFILE = "canonical_premium_protocol_fees_retained_1e18_sqrt_nav_bid_ask"
F = replay.FLOAT_SCALING
U64_MAX = (1 << 64) - 1


def _sat_add(a: int, b: int, cap: int = U64_MAX) -> int:
    return min(cap, a + b)


def _ceil_div(a: int, b: int, cap: int = U64_MAX) -> int:
    if b == 0:
        return cap
    value = (a + b - 1) // b
    return min(cap, value)


def _ceil_mul_div(a: int, b: int, divisor: int, cap: int = U64_MAX) -> int:
    if divisor == 0:
        return cap
    return min(cap, _ceil_div(a * b, divisor, cap))


def _signed_i64(value: int) -> replay.I64:
    return replay.I64(abs(value), value < 0)


def _from_i64(value: replay.I64) -> int:
    return -value.magnitude if value.is_negative else value.magnitude


def _fraction_payload(value: Fraction | None) -> dict[str, str] | None:
    if value is None:
        return None
    return {
        "numerator": str(value.numerator),
        "denominator": str(value.denominator),
    }


@dataclass(frozen=True)
class TraceValue:
    node_id: str
    center: int
    exact_raw: Fraction | None
    error: int = 0


@dataclass(frozen=True)
class Scenario:
    name: str
    description: str
    pyth_spot: int
    block_scholes_spot: int
    pushed_forward: int
    svi: dict[str, Any]
    strike: int
    is_up: bool
    quantity: int
    leverage: int
    close_quantity: int
    reference_lower: int
    reference_upper: int


SCENARIOS = (
    Scenario(
        name="ordinary_1x",
        description="Mid-probability one-times mint with a one-third partial close.",
        pyth_spot=75_852_009_440_344,
        block_scholes_spot=75_852_009_440_344,
        pushed_forward=75_799_394_374_445,
        svi={
            "a": 171_736,
            "aNegative": False,
            "b": 7_449_196,
            "rho": 243_059_022,
            "rhoNegative": True,
            "m": 1_133_202,
            "mNegative": False,
            "sigma": 15_731_214,
        },
        strike=75_788_000_000_000,
        is_up=True,
        quantity=12_000_000,
        leverage=replay.LEVERAGE_ONE_X,
        close_quantity=4_000_000,
        reference_lower=528_329_926,
        reference_upper=528_329_931,
    ),
    Scenario(
        name="leveraged_boundary",
        description="Two-and-a-half-times mint whose smallest partial close exposes floor-split dust.",
        pyth_spot=75_041_662_630_739,
        block_scholes_spot=75_041_662_630_739,
        pushed_forward=75_044_761_049_821,
        svi={
            "a": 99_272,
            "aNegative": False,
            "b": 3_466_091,
            "rho": 475_372_427,
            "rhoNegative": True,
            "m": 3_647_706,
            "mNegative": True,
            "sigma": 6_351_738,
        },
        strike=75_040_000_000_000,
        is_up=True,
        quantity=20_000_000,
        leverage=replay.LEVERAGE_TWO_AND_HALF_X,
        close_quantity=replay.POSITION_LOT_SIZE,
        reference_lower=499_130_528,
        reference_upper=499_130_533,
    ),
    Scenario(
        name="precision_sensitive",
        description="Small-variance real SVI surface with a leveraged mint and precision-amplifying price path.",
        pyth_spot=74_212_635_061_019,
        block_scholes_spot=74_212_635_061_019,
        pushed_forward=74_212_629_180_749,
        svi={
            "a": 54_831,
            "aNegative": False,
            "b": 2_366_211,
            "rho": 298_114_517,
            "rhoNegative": True,
            "m": 2_324_961,
            "mNegative": False,
            "sigma": 5_354_101,
        },
        strike=73_490_000_000_000,
        is_up=True,
        quantity=30_000_000,
        leverage=replay.LEVERAGE_TWO_AND_HALF_X,
        close_quantity=10_000_000,
        reference_lower=877_147_818,
        reference_upper=877_147_823,
    ),
)


class AlgebraTrace:
    def __init__(self, scenario: Scenario):
        self.scenario = scenario
        self.nodes: list[dict[str, Any]] = []
        self.values: dict[str, TraceValue] = {}
        self.parity_checks: list[dict[str, Any]] = []
        self.identities: list[dict[str, Any]] = []
        self._counter = 0

    def _node(
        self,
        name: str,
        phase: str,
        op: str,
        center: int,
        inputs: tuple[TraceValue, ...] = (),
        *,
        exact_raw: Fraction | None = None,
        error: int = 0,
        unit: str = "raw",
        scale: int | None = None,
        rounding: str = "exact",
        boundary: str | None = None,
        flow_direction: str | None = None,
        dust_owner: str | None = None,
        move_site: str | None = None,
        expression: str | None = None,
        tags: tuple[str, ...] = (),
        note: str | None = None,
    ) -> TraceValue:
        self._counter += 1
        node_id = f"{self.scenario.name}:{self._counter:04d}:{name}"
        residual = None if exact_raw is None else Fraction(center) - exact_raw
        node = {
            "id": node_id,
            "name": name,
            "phase": phase,
            "op": op,
            "inputs": [value.node_id for value in inputs],
            "center": str(center),
            "exact_raw": _fraction_payload(exact_raw),
            "rounding_residual": _fraction_payload(residual),
            "certificate_error": str(error),
            "unit": unit,
            "scale": None if scale is None else str(scale),
            "rounding": rounding,
            "boundary": boundary,
            "flow_direction": flow_direction,
            "dust_owner": dust_owner,
            "move_site": move_site,
            "expression": expression,
            "tags": list(tags),
            "note": note,
        }
        value = TraceValue(node_id, center, exact_raw, error)
        self.nodes.append(node)
        self.values[node_id] = value
        return value

    def input(
        self,
        name: str,
        center: int,
        phase: str,
        *,
        unit: str,
        scale: int | None = None,
        move_site: str | None = None,
        note: str | None = None,
    ) -> TraceValue:
        return self._node(
            name,
            phase,
            "input",
            center,
            exact_raw=Fraction(center),
            unit=unit,
            scale=scale,
            move_site=move_site,
            note=note,
        )

    def alias(
        self,
        name: str,
        value: TraceValue,
        phase: str,
        *,
        boundary: str,
        move_site: str,
        note: str | None = None,
    ) -> TraceValue:
        return self._node(
            name,
            phase,
            "alias",
            value.center,
            (value,),
            exact_raw=value.exact_raw,
            error=value.error,
            unit=self._node_unit(value),
            scale=self._node_scale(value),
            boundary=boundary,
            move_site=move_site,
            note=note,
        )

    def _node_unit(self, value: TraceValue) -> str:
        return next(node["unit"] for node in self.nodes if node["id"] == value.node_id)

    def _node_scale(self, value: TraceValue) -> int | None:
        raw = next(node["scale"] for node in self.nodes if node["id"] == value.node_id)
        return None if raw is None else int(raw)

    def add(
        self,
        name: str,
        a: TraceValue,
        b: TraceValue,
        phase: str,
        *,
        move_site: str,
        expression: str | None = None,
        unit: str | None = None,
        note: str | None = None,
    ) -> TraceValue:
        exact = None if a.exact_raw is None or b.exact_raw is None else a.exact_raw + b.exact_raw
        return self._node(
            name,
            phase,
            "add",
            a.center + b.center,
            (a, b),
            exact_raw=exact,
            error=_sat_add(a.error, b.error),
            unit=unit or self._node_unit(a),
            scale=self._node_scale(a),
            move_site=move_site,
            expression=expression,
            note=note,
        )

    def sub(
        self,
        name: str,
        a: TraceValue,
        b: TraceValue,
        phase: str,
        *,
        move_site: str,
        expression: str | None = None,
        unit: str | None = None,
        boundary: str | None = None,
        flow_direction: str | None = None,
        dust_owner: str | None = None,
        note: str | None = None,
    ) -> TraceValue:
        exact = None if a.exact_raw is None or b.exact_raw is None else a.exact_raw - b.exact_raw
        return self._node(
            name,
            phase,
            "sub",
            a.center - b.center,
            (a, b),
            exact_raw=exact,
            error=_sat_add(a.error, b.error),
            unit=unit or self._node_unit(a),
            scale=self._node_scale(a),
            boundary=boundary,
            flow_direction=flow_direction,
            dust_owner=dust_owner,
            move_site=move_site,
            expression=expression,
            note=note,
        )

    def neg(self, name: str, value: TraceValue, phase: str, *, move_site: str) -> TraceValue:
        exact = None if value.exact_raw is None else -value.exact_raw
        return self._node(
            name,
            phase,
            "neg",
            -value.center,
            (value,),
            exact_raw=exact,
            error=value.error,
            unit=self._node_unit(value),
            scale=self._node_scale(value),
            move_site=move_site,
        )

    def half(self, name: str, value: TraceValue, phase: str, *, move_site: str) -> TraceValue:
        center = abs(value.center) // 2
        center = -center if value.center < 0 else center
        exact = None if value.exact_raw is None else value.exact_raw / 2
        return self._node(
            name,
            phase,
            "half",
            center,
            (value,),
            exact_raw=exact,
            error=_sat_add(value.error, 1),
            unit=self._node_unit(value),
            scale=self._node_scale(value),
            rounding="toward_zero",
            move_site=move_site,
        )

    def mul_scaled(
        self,
        name: str,
        a: TraceValue,
        b: TraceValue,
        phase: str,
        *,
        move_site: str,
        unit: str,
        certify: bool = False,
        boundary: str | None = None,
        flow_direction: str | None = None,
        dust_owner: str | None = None,
        expression: str | None = None,
        tags: tuple[str, ...] = (),
        note: str | None = None,
    ) -> TraceValue:
        magnitude = abs(a.center) * abs(b.center) // F
        center = -magnitude if (a.center < 0) != (b.center < 0) else magnitude
        exact = None if a.exact_raw is None or b.exact_raw is None else a.exact_raw * b.exact_raw / F
        error = 0
        if certify:
            error = _sat_add(
                _sat_add(
                    _sat_add(
                        _ceil_mul_div(abs(a.center), b.error, F),
                        _ceil_mul_div(abs(b.center), a.error, F),
                    ),
                    _ceil_mul_div(a.error, b.error, F),
                ),
                1,
            )
        return self._node(
            name,
            phase,
            "mul_scaled",
            center,
            (a, b),
            exact_raw=exact,
            error=error,
            unit=unit,
            scale=self._node_scale(a),
            rounding="toward_zero" if center < 0 else "down",
            boundary=boundary,
            flow_direction=flow_direction,
            dust_owner=dust_owner,
            move_site=move_site,
            expression=expression,
            tags=tags,
            note=note,
        )

    def mul_scaled_up(
        self,
        name: str,
        a: TraceValue,
        b: TraceValue,
        phase: str,
        *,
        move_site: str,
        unit: str,
        boundary: str | None = None,
        flow_direction: str | None = None,
        dust_owner: str | None = None,
        expression: str | None = None,
    ) -> TraceValue:
        product = a.center * b.center
        center = (product + F - 1) // F
        exact = (
            None
            if a.exact_raw is None or b.exact_raw is None
            else a.exact_raw * b.exact_raw / F
        )
        return self._node(
            name,
            phase,
            "mul_scaled_up",
            center,
            (a, b),
            exact_raw=exact,
            unit=unit,
            scale=self._node_scale(a),
            rounding="up",
            boundary=boundary,
            flow_direction=flow_direction,
            dust_owner=dust_owner,
            move_site=move_site,
            expression=expression,
        )

    def square_scaled(
        self,
        name: str,
        value: TraceValue,
        phase: str,
        *,
        move_site: str,
        certify: bool,
    ) -> TraceValue:
        center = abs(value.center) * abs(value.center) // F
        exact = None if value.exact_raw is None else value.exact_raw * value.exact_raw / F
        error = 0
        if certify:
            cross = _ceil_mul_div(abs(value.center), value.error, F)
            error = _sat_add(_sat_add(_sat_add(cross, cross), _ceil_mul_div(value.error, value.error, F)), 1)
        return self._node(
            name,
            phase,
            "square_scaled",
            center,
            (value,),
            exact_raw=exact,
            error=error,
            unit="probability_1e9",
            scale=F,
            rounding="down",
            move_site=move_site,
        )

    def div_scaled(
        self,
        name: str,
        a: TraceValue,
        b: TraceValue,
        phase: str,
        *,
        move_site: str,
        unit: str,
        certify: bool = False,
        boundary: str | None = None,
        flow_direction: str | None = None,
        dust_owner: str | None = None,
        expression: str | None = None,
    ) -> TraceValue:
        magnitude = abs(a.center) * F // abs(b.center)
        center = -magnitude if (a.center < 0) != (b.center < 0) else magnitude
        exact = None if a.exact_raw is None or b.exact_raw is None else a.exact_raw * F / b.exact_raw
        error = 0
        if certify:
            mb = abs(b.center)
            if mb <= b.error:
                error = U64_MAX
            else:
                denominator = mb - b.error
                first = _ceil_mul_div(a.error, F, denominator)
                numerator_over_b = _ceil_mul_div(abs(a.center), b.error, denominator)
                second = _ceil_mul_div(numerator_over_b, F, denominator)
                error = _sat_add(_sat_add(first, second), 1)
        return self._node(
            name,
            phase,
            "div_scaled",
            center,
            (a, b),
            exact_raw=exact,
            error=error,
            unit=unit,
            scale=self._node_scale(a),
            rounding="toward_zero" if center < 0 else "down",
            boundary=boundary,
            flow_direction=flow_direction,
            dust_owner=dust_owner,
            move_site=move_site,
            expression=expression,
        )

    def div_scaled_up(
        self,
        name: str,
        a: TraceValue,
        b: TraceValue,
        phase: str,
        *,
        move_site: str,
        unit: str,
        boundary: str | None = None,
        flow_direction: str | None = None,
        dust_owner: str | None = None,
        expression: str | None = None,
    ) -> TraceValue:
        numerator = a.center * F
        center = (numerator + b.center - 1) // b.center
        exact = (
            None
            if a.exact_raw is None or b.exact_raw is None
            else a.exact_raw * F / b.exact_raw
        )
        return self._node(
            name,
            phase,
            "div_scaled_up",
            center,
            (a, b),
            exact_raw=exact,
            unit=unit,
            scale=self._node_scale(a),
            rounding="up",
            boundary=boundary,
            flow_direction=flow_direction,
            dust_owner=dust_owner,
            move_site=move_site,
            expression=expression,
        )

    def mul_div_down(
        self,
        name: str,
        a: TraceValue,
        b: TraceValue,
        c: TraceValue,
        phase: str,
        *,
        move_site: str,
        unit: str,
        certify: bool = False,
        boundary: str | None = None,
        flow_direction: str | None = None,
        dust_owner: str | None = None,
        expression: str | None = None,
        forced_error: int | None = None,
        note: str | None = None,
    ) -> TraceValue:
        magnitude = abs(a.center) * abs(b.center) // abs(c.center)
        negative = (a.center < 0) ^ (b.center < 0) ^ (c.center < 0)
        center = -magnitude if negative else magnitude
        exact = None if any(value.exact_raw is None for value in (a, b, c)) else a.exact_raw * b.exact_raw / c.exact_raw
        error = 0
        if certify:
            ma, mb, mc = abs(a.center), abs(b.center), abs(c.center)
            if mc <= c.error or ma > U64_MAX - a.error or mb > U64_MAX - b.error:
                error = U64_MAX
            else:
                upper = _ceil_mul_div(ma + a.error, mb + b.error, mc - c.error)
                if upper == U64_MAX:
                    error = U64_MAX
                elif ma > a.error and mb > b.error:
                    lower = 0 if mc > U64_MAX - c.error else (ma - a.error) * (mb - b.error) // (mc + c.error)
                    error = max(magnitude - lower, max(0, upper - magnitude))
                else:
                    error = _sat_add(magnitude, upper)
        if forced_error is not None:
            error = forced_error
        return self._node(
            name,
            phase,
            "mul_div_down",
            center,
            (a, b, c),
            exact_raw=exact,
            error=error,
            unit=unit,
            scale=self._node_scale(a),
            rounding="toward_zero" if center < 0 else "down",
            boundary=boundary,
            flow_direction=flow_direction,
            dust_owner=dust_owner,
            move_site=move_site,
            expression=expression,
            note=note,
        )

    def sqrt(self, name: str, value: TraceValue, phase: str, *, move_site: str) -> TraceValue:
        center = replay.sqrt_fixed(abs(value.center), F)
        low = replay.sqrt_fixed(value.center - value.error, F) if value.center > value.error else 0
        high = replay.sqrt_fixed(min(U64_MAX, value.center + value.error), F)
        error = max(center - low, high - center) + 1
        return self._node(
            name,
            phase,
            "sqrt",
            center,
            (value,),
            exact_raw=None,
            error=error,
            unit="probability_1e9",
            scale=F,
            rounding="approximation",
            move_site=move_site,
        )

    def ln(self, name: str, value: TraceValue, phase: str, *, move_site: str, input_error: int) -> TraceValue:
        center = _from_i64(replay.ln_fixed(value.center))
        leaf = abs(center) // 10_000_000 + 3
        propagated = _ceil_mul_div(input_error, F, value.center - input_error) if value.center > input_error else U64_MAX
        return self._node(
            name,
            phase,
            "ln",
            center,
            (value,),
            exact_raw=None,
            error=_sat_add(propagated, leaf),
            unit="probability_1e9",
            scale=F,
            rounding="approximation",
            move_site=move_site,
        )

    def normal_cdf(self, name: str, value: TraceValue, phase: str, *, move_site: str) -> TraceValue:
        center = replay.normal_cdf(_signed_i64(value.center))
        nearest = max(0, abs(value.center) - value.error)
        sup_phi = _sat_add(replay.normal_pdf(replay.I64(nearest)), 50)
        error = _sat_add(_ceil_mul_div(sup_phi, value.error, F), 20)
        return self._node(
            name,
            phase,
            "normal_cdf",
            center,
            (value,),
            exact_raw=None,
            error=error,
            unit="probability_1e9",
            scale=F,
            rounding="approximation",
            move_site=move_site,
        )

    def normal_pdf(self, name: str, value: TraceValue, phase: str, *, move_site: str) -> TraceValue:
        center = replay.normal_pdf(_signed_i64(value.center))
        error = _sat_add(_ceil_mul_div(242_000_000, value.error, F), 50)
        return self._node(
            name,
            phase,
            "normal_pdf",
            center,
            (value,),
            exact_raw=None,
            error=error,
            unit="probability_1e9",
            scale=F,
            rounding="approximation",
            move_site=move_site,
        )

    def clamp_nonnegative(
        self,
        name: str,
        value: TraceValue,
        phase: str,
        *,
        move_site: str,
        boundary: str,
        note: str,
    ) -> TraceValue:
        center = max(0, value.center)
        exact = None if value.exact_raw is None else max(Fraction(0), value.exact_raw)
        return self._node(
            name,
            phase,
            "clamp_nonnegative",
            center,
            (value,),
            exact_raw=exact,
            error=value.error,
            unit=self._node_unit(value),
            scale=self._node_scale(value),
            rounding="policy_clamp",
            boundary=boundary,
            move_site=move_site,
            note=note,
        )

    def clamp_upper(
        self,
        name: str,
        value: TraceValue,
        upper: TraceValue,
        phase: str,
        *,
        move_site: str,
        boundary: str,
    ) -> TraceValue:
        center = min(value.center, upper.center)
        exact = None if value.exact_raw is None else min(value.exact_raw, Fraction(upper.center))
        return self._node(
            name,
            phase,
            "clamp_upper",
            center,
            (value, upper),
            exact_raw=exact,
            error=value.error,
            unit=self._node_unit(value),
            scale=self._node_scale(value),
            rounding="policy_clamp",
            boundary=boundary,
            move_site=move_site,
        )

    def saturating_sub(
        self,
        name: str,
        a: TraceValue,
        b: TraceValue,
        phase: str,
        *,
        move_site: str,
        flow_direction: str,
        dust_owner: str,
        note: str,
    ) -> TraceValue:
        center = max(0, a.center - b.center)
        exact = None if a.exact_raw is None or b.exact_raw is None else max(Fraction(0), a.exact_raw - b.exact_raw)
        return self._node(
            name,
            phase,
            "saturating_sub",
            center,
            (a, b),
            exact_raw=exact,
            error=_sat_add(a.error, b.error),
            unit=self._node_unit(a),
            scale=self._node_scale(a),
            rounding="policy_clamp",
            boundary="money",
            flow_direction=flow_direction,
            dust_owner=dust_owner,
            move_site=move_site,
            note=note,
        )

    def check_parity(self, label: str, traced: int, canonical: int) -> None:
        self.parity_checks.append(
            {
                "label": label,
                "traced": str(traced),
                "canonical": str(canonical),
                "matches": traced == canonical,
            }
        )

    def check_identity(self, label: str, left: int, right: int) -> None:
        self.identities.append(
            {
                "label": label,
                "left": str(left),
                "right": str(right),
                "holds": left == right,
            }
        )

    def knots(self) -> list[dict[str, Any]]:
        knots: list[dict[str, Any]] = []
        by_id = {node["id"]: node for node in self.nodes}
        consumers: dict[str, list[str]] = defaultdict(list)
        for node in self.nodes:
            for parent in node["inputs"]:
                consumers[parent].append(node["id"])

        for node in self.nodes:
            residual = node["rounding_residual"]
            residual_nonzero = residual is not None and int(residual["numerator"]) != 0
            if "certificate-reset" in node["tags"] and residual_nonzero and int(node["certificate_error"]) == 0:
                knots.append(
                    {
                        "kind": "certificate_provenance_gap",
                        "severity": "high",
                        "node": node["id"],
                        "summary": "Rounded sigma square is relabeled exact, so its leaf error disappears.",
                        "proof_obligation": "Birth the multiplication leaf error or prove it is dominated by the precision-island certificate.",
                    }
                )
            if node["rounding"] in {"down", "toward_zero"} and node["expression"]:
                rounded_parents = [
                    by_id[parent]
                    for parent in node["inputs"]
                    if by_id[parent]["rounding"] in {"down", "toward_zero", "approximation"}
                    and by_id[parent]["expression"]
                ]
                if rounded_parents:
                    knots.append(
                        {
                            "kind": "stacked_rounding",
                            "severity": "candidate",
                            "node": node["id"],
                            "parents": [parent["id"] for parent in rounded_parents],
                            "summary": f"{node['name']} rounds an already-rounded expression at {node['move_site']}.",
                            "proof_obligation": "Compare a fused expression for scalar bits, abort domain, dust direction, and certificate width.",
                        }
                    )
            if node["op"] == "saturating_sub" and consumers[node["id"]]:
                knots.append(
                    {
                        "kind": "lossy_value_reused",
                        "severity": "review",
                        "node": node["id"],
                        "consumers": consumers[node["id"]],
                        "summary": "A clamped value continues into downstream algebra.",
                        "proof_obligation": "Confirm this is the policy owner and no consumer needs the discarded pre-clamp identity.",
                    }
                )
            if (
                node["boundary"] == "money"
                and node["flow_direction"] == "protocol_inflow"
                and node["dust_owner"] == "trader"
                and node["rounding"] in {"down", "toward_zero"}
            ):
                knots.append(
                    {
                        "kind": "dust_direction_review",
                        "severity": "policy",
                        "node": node["id"],
                        "summary": f"{node['name']} is a protocol inflow that rounds down, leaving arithmetic dust with the trader.",
                        "proof_obligation": "Preserve the settled scalar policy unless a separate economics decision authorizes changing it.",
                    }
                )

        expressions: dict[str, list[str]] = defaultdict(list)
        for node in self.nodes:
            if node["expression"]:
                expressions[node["expression"]].append(node["id"])
        for expression, node_ids in expressions.items():
            if len(node_ids) > 1:
                knots.append(
                    {
                        "kind": "repeated_expression",
                        "severity": "candidate",
                        "nodes": node_ids,
                        "summary": f"Expression is evaluated {len(node_ids)} times: {expression}.",
                        "proof_obligation": "Check whether one derived fact can be carried without widening ownership or changing guard order.",
                    }
                )

        for check in self.parity_checks:
            if not check["matches"]:
                knots.append(
                    {
                        "kind": "replica_parity_failure",
                        "severity": "blocker",
                        "summary": f"{check['label']} differs from the canonical Python replay.",
                        "traced": check["traced"],
                        "canonical": check["canonical"],
                    }
                )
        return knots

    def payload(self) -> dict[str, Any]:
        counts = Counter(node["op"] for node in self.nodes if node["op"] not in {"input", "alias"})
        output_names = {
            "mint_range_price",
            "net_premium",
            "floor_shares",
            "redeem_amount",
            "settlement_winner_payout",
            "liquidation_decision",
            "active_market_nav",
            "pool_value",
            "withdraw_pool_value",
            "supply_pool_value",
            "supply_shares",
            "withdraw_dusdc",
        }
        outputs = {
            node["name"]: {
                "center": node["center"],
                "certificate_error": node["certificate_error"],
            }
            for node in self.nodes
            if node["name"] in output_names
        }
        return {
            "scenario": self.scenario.name,
            "description": self.scenario.description,
            "nodes": self.nodes,
            "operation_counts": dict(sorted(counts.items())),
            "key_outputs": outputs,
            "parity_checks": self.parity_checks,
            "identities": self.identities,
            "knots": self.knots(),
        }


def _trace_up_price(
    trace: AlgebraTrace,
    svi: dict[str, Any],
    forward: TraceValue,
    strike: int,
    label: str,
) -> TraceValue:
    phase = "pricing"
    strike_value = trace.input(
        f"{label}_strike",
        strike,
        phase,
        unit="price_1e9",
        scale=F,
        move_site="pricing::compute_up_price",
    )
    if strike == replay.NEG_INF_STRIKE:
        return trace._node(
            f"{label}_up_price",
            phase,
            "sentinel",
            F,
            (strike_value,),
            exact_raw=Fraction(F),
            unit="probability_1e9",
            scale=F,
            move_site="pricing::compute_up_price",
        )
    if strike == replay.POS_INF_STRIKE:
        return trace._node(
            f"{label}_up_price",
            phase,
            "sentinel",
            0,
            (strike_value,),
            exact_raw=Fraction(0),
            unit="probability_1e9",
            scale=F,
            move_site="pricing::compute_up_price",
        )

    scaling = trace.input(
        f"{label}_float_scaling",
        F,
        phase,
        unit="probability_1e9",
        scale=F,
        move_site="fixed_math::math::float_scaling",
    )
    ratio = trace.mul_div_down(
        f"{label}_strike_ratio",
        strike_value,
        scaling,
        forward,
        phase,
        move_site="pricing::compute_up_price",
        unit="probability_1e9",
        forced_error=1,
        note="Move hands one raw unit of ratio-floor error to approx::ln.",
    )
    k = trace.ln(
        f"{label}_log_moneyness",
        ratio,
        phase,
        move_site="pricing::compute_up_price",
        input_error=1,
    )
    m_signed = -svi["m"] if svi["mNegative"] else svi["m"]
    m = trace.input(
        f"{label}_svi_m",
        m_signed,
        phase,
        unit="probability_1e9",
        scale=F,
        move_site="pricing::moneyness_terms",
    )
    k_minus_m = trace.sub(
        f"{label}_k_minus_m",
        k,
        m,
        phase,
        move_site="pricing::moneyness_terms",
        expression="k-m",
    )
    k_minus_m_squared = trace.square_scaled(
        f"{label}_k_minus_m_squared",
        k_minus_m,
        phase,
        move_site="pricing::moneyness_terms",
        certify=True,
    )
    sigma = trace.input(
        f"{label}_sigma",
        svi["sigma"],
        phase,
        unit="probability_1e9",
        scale=F,
        move_site="pricing::moneyness_terms",
    )
    sigma_squared = trace.square_scaled(
        f"{label}_sigma_squared",
        sigma,
        phase,
        move_site="pricing::moneyness_terms",
        certify=True,
    )
    sqrt_input = trace.add(
        f"{label}_sqrt_input",
        k_minus_m_squared,
        sigma_squared,
        phase,
        move_site="pricing::moneyness_terms",
    )
    root = trace.sqrt(f"{label}_moneyness_root", sqrt_input, phase, move_site="pricing::moneyness_terms")
    rho = trace.input(
        f"{label}_rho",
        -svi["rho"] if svi["rhoNegative"] else svi["rho"],
        phase,
        unit="probability_1e9",
        scale=F,
        move_site="pricing::total_variance",
    )
    rho_km = trace.mul_scaled(
        f"{label}_rho_times_moneyness",
        rho,
        k_minus_m,
        phase,
        move_site="pricing::total_variance",
        unit="probability_1e9",
        certify=True,
        expression="rho*(k-m)",
    )
    inner = trace.add(
        f"{label}_variance_inner",
        rho_km,
        root,
        phase,
        move_site="pricing::total_variance",
        expression="rho*(k-m)+root",
    )
    b = trace.input(
        f"{label}_svi_b",
        svi["b"],
        phase,
        unit="probability_1e9",
        scale=F,
        move_site="pricing::total_variance",
    )
    a = trace.input(
        f"{label}_svi_a",
        -svi["a"] if svi.get("aNegative", False) else svi["a"],
        phase,
        unit="probability_1e9",
        scale=F,
        move_site="pricing::variance_denominator_terms",
    )
    wide_increment = b.center * inner.center
    wide_a = abs(a.center) * F
    wide_total_center = (
        wide_increment - wide_a
        if a.center < 0
        else wide_increment + wide_a
    )
    wide_error = b.center * inner.error
    wide_total = trace._node(
        f"{label}_wide_total_variance",
        phase,
        "wide_total_variance",
        wide_total_center,
        (b, inner, a),
        exact_raw=None,
        error=wide_error,
        unit="variance_1e18",
        scale=F * F,
        rounding="exact_wide",
        move_site="pricing::variance_denominator_terms",
        note="Only total variance is retained at 1e18 through sqrt; downstream Approx arithmetic remains 1e9.",
    )
    half_var_center = wide_total_center // (2 * F)
    half_var_error = _ceil_div(wide_error, 2 * F) + 1
    half_var = trace._node(
        f"{label}_half_variance",
        phase,
        "direct_half_variance",
        half_var_center,
        (wide_total,),
        exact_raw=None,
        error=half_var_error,
        unit="probability_1e9",
        scale=F,
        rounding="down",
        move_site="pricing::variance_denominator_terms",
    )
    sqrt_center = math.isqrt(wide_total_center)
    sqrt_low = (
        math.isqrt(wide_total_center - wide_error)
        if wide_total_center > wide_error
        else 0
    )
    sqrt_high_floor = math.isqrt(wide_total_center + wide_error)
    sqrt_high = (
        sqrt_high_floor
        if sqrt_high_floor * sqrt_high_floor == wide_total_center + wide_error
        else sqrt_high_floor + 1
    )
    sqrt_var = trace._node(
        f"{label}_sqrt_variance",
        phase,
        "sqrt_u128_variance",
        sqrt_center,
        (wide_total,),
        exact_raw=None,
        error=max(sqrt_center - sqrt_low, sqrt_high - sqrt_center),
        unit="probability_1e9",
        scale=F,
        rounding="outward",
        move_site="pricing::variance_denominator_terms",
    )
    d2_numerator = trace.add(
        f"{label}_d2_numerator",
        k,
        half_var,
        phase,
        move_site="pricing::compute_up_price",
    )
    d2_unnegated = trace.div_scaled(
        f"{label}_d2_unnegated",
        d2_numerator,
        sqrt_var,
        phase,
        move_site="pricing::compute_up_price",
        unit="probability_1e9",
        certify=True,
    )
    d2 = trace.neg(f"{label}_d2", d2_unnegated, phase, move_site="pricing::compute_up_price")
    slope_ratio = trace.div_scaled(
        f"{label}_slope_ratio",
        k_minus_m,
        root,
        phase,
        move_site="pricing::variance_slope",
        unit="probability_1e9",
        certify=True,
    )
    slope = trace.add(
        f"{label}_variance_slope_base",
        rho,
        slope_ratio,
        phase,
        move_site="pricing::variance_slope",
    )
    w_prime = trace.mul_scaled(
        f"{label}_variance_slope",
        b,
        slope,
        phase,
        move_site="pricing::variance_slope",
        unit="probability_1e9",
        certify=True,
    )
    nd2 = trace.normal_cdf(f"{label}_normal_cdf", d2, phase, move_site="pricing::digital_price")
    if w_prime.center == 0 and w_prime.error == 0:
        zero = trace.input(
            f"{label}_zero",
            0,
            phase,
            unit="probability_1e9",
            scale=F,
            move_site="pricing::digital_price",
        )
        nonnegative = trace.clamp_nonnegative(
            f"{label}_digital_nonnegative",
            nd2,
            phase,
            move_site="pricing::digital_price",
            boundary="pricing_policy",
            note="Clamp preserves the canonical branch and the certificate radius.",
        )
        scalar = trace.clamp_upper(
            f"{label}_digital_price",
            nonnegative,
            scaling,
            phase,
            move_site="pricing::digital_price",
            boundary="pricing_policy",
        )
        _ = zero
    else:
        pdf = trace.normal_pdf(f"{label}_normal_pdf", d2, phase, move_site="pricing::digital_price")
        two_sqrt = trace.add(
            f"{label}_two_sqrt_variance",
            sqrt_var,
            sqrt_var,
            phase,
            move_site="pricing::digital_price",
        )
        correction = trace.mul_div_down(
            f"{label}_smile_correction",
            pdf,
            w_prime,
            two_sqrt,
            phase,
            move_site="pricing::digital_price",
            unit="probability_1e9",
            certify=True,
        )
        adjusted = trace.sub(
            f"{label}_adjusted_digital",
            nd2,
            correction,
            phase,
            move_site="pricing::digital_price",
        )
        nonnegative = trace.clamp_nonnegative(
            f"{label}_digital_nonnegative",
            adjusted,
            phase,
            move_site="pricing::digital_price",
            boundary="pricing_policy",
            note="Fixed-point or SVI tail behavior is projected to the probability domain.",
        )
        scalar = trace.clamp_upper(
            f"{label}_digital_price",
            nonnegative,
            scaling,
            phase,
            move_site="pricing::digital_price",
            boundary="pricing_policy",
        )
    canonical = replay.compute_up_price(svi, forward.center, strike)
    trace.check_parity(f"{label} up price", scalar.center, canonical)
    return scalar


def _trace_range_price(
    trace: AlgebraTrace,
    scenario: Scenario,
    forward: TraceValue,
    lower: int,
    higher: int,
    label: str,
) -> TraceValue:
    lower_up = _trace_up_price(trace, scenario.svi, forward, lower, f"{label}_lower")
    higher_up = _trace_up_price(trace, scenario.svi, forward, higher, f"{label}_higher")
    difference = trace.sub(
        f"{label}_boundary_difference",
        lower_up,
        higher_up,
        "pricing",
        move_site="pricing::compute_range_price",
        expression="up(lower)-up(higher)",
    )
    price = trace.clamp_nonnegative(
        f"{label}_range_price",
        difference,
        "pricing",
        move_site="pricing::compute_range_price",
        boundary="pricing_policy",
        note="A non-monotone boundary result is floored at zero.",
    )
    canonical = replay.compute_range_price(scenario.svi, forward.center, lower, higher)
    trace.check_parity(f"{label} range price", price.center, canonical)
    return price


def trace_scenario(scenario: Scenario) -> AlgebraTrace:
    trace = AlgebraTrace(scenario)
    pyth_spot = trace.input(
        "pyth_spot",
        scenario.pyth_spot,
        "oracle",
        unit="price_1e9",
        scale=F,
        move_site="pricing::resolve_live_pricer",
    )
    block_scholes_spot = trace.input(
        "block_scholes_spot",
        scenario.block_scholes_spot,
        "oracle",
        unit="price_1e9",
        scale=F,
        move_site="pricing::resolve_live_pricer",
    )
    block_scholes_forward = trace.input(
        "block_scholes_forward",
        scenario.pushed_forward,
        "oracle",
        unit="price_1e9",
        scale=F,
        move_site="pricing::resolve_live_pricer",
    )
    live_forward = trace.mul_div_down(
        "live_forward",
        pyth_spot,
        block_scholes_forward,
        block_scholes_spot,
        "oracle",
        move_site="pricing::resolve_live_pricer",
        unit="price_1e9",
        expression="pyth_spot*bs_forward/bs_spot",
        note="Move re-anchors the forward with one fused floor.",
    )
    trace.check_parity(
        "live forward",
        live_forward.center,
        replay.live_forward(
            scenario.pyth_spot,
            scenario.pushed_forward,
            scenario.block_scholes_spot,
        ),
    )

    aligned_strike = replay.align_strike_to_tick(scenario.strike)
    lower, higher = replay.binary_range_bounds(aligned_strike, scenario.is_up)
    entry_probability = _trace_range_price(trace, scenario, live_forward, lower, higher, "mint")
    quantity = trace.input(
        "mint_quantity",
        scenario.quantity,
        "mint",
        unit="dusdc_1e6",
        scale=replay.DUSDC_DECIMALS,
        move_site="strike_exposure_config::assert_mint_admission",
    )
    leverage = trace.input(
        "mint_leverage",
        scenario.leverage,
        "mint",
        unit="multiplier_1e9",
        scale=F,
        move_site="strike_exposure_config::assert_mint_admission",
    )
    entry_value = trace.mul_scaled(
        "entry_exposure_value",
        entry_probability,
        quantity,
        "mint",
        move_site="strike_exposure_config::assert_mint_admission",
        unit="dusdc_1e6",
        boundary="derived_fact",
        expression="entry_probability*quantity",
    )
    contribution = trace.div_scaled_up(
        "net_premium",
        entry_value,
        leverage,
        "mint",
        move_site="strike_exposure_config::assert_mint_admission",
        unit="dusdc_1e6",
        boundary="money",
        flow_direction="protocol_inflow",
        dust_owner="pool",
        expression="(entry_probability*quantity)/leverage",
    )
    floor_shares = trace.sub(
        "floor_shares",
        entry_value,
        contribution,
        "mint",
        move_site="strike_exposure_config::assert_mint_admission",
        unit="dusdc_1e6",
        boundary="storage_commitment",
    )
    fee_rate_value = replay.assert_mint_fee_rate(entry_probability.center)
    fee_rate = trace.input(
        "trading_fee_rate",
        fee_rate_value,
        "mint",
        unit="probability_1e9",
        scale=F,
        move_site="strike_exposure_config::trading_fee",
    )
    trading_fee = trace.mul_scaled_up(
        "trading_fee",
        fee_rate,
        quantity,
        "mint",
        move_site="strike_exposure_config::trading_fee",
        unit="dusdc_1e6",
        boundary="money",
        flow_direction="protocol_inflow",
        dust_owner="pool",
    )
    stored_quantity = trace.alias(
        "stored_order_quantity",
        quantity,
        "index_insert",
        boundary="storage_commitment",
        move_site="order::new_from_ticks",
    )
    stored_floor = trace.alias(
        "stored_order_floor",
        floor_shares,
        "index_insert",
        boundary="storage_commitment",
        move_site="order::new_from_ticks",
    )
    trace.alias(
        "payout_tree_quantity_term",
        stored_quantity,
        "index_insert",
        boundary="index_insert",
        move_site="strike_payout_tree::insert_range",
    )
    trace.alias(
        "payout_tree_floor_term",
        stored_floor,
        "index_insert",
        boundary="index_insert",
        move_site="strike_payout_tree::insert_range",
    )

    canonical_mint = replay.compute_mint_terms(entry_probability.center, scenario.quantity, scenario.leverage)
    trace.check_parity("mint entry exposure", entry_value.center, canonical_mint["entry_exposure_value"])
    trace.check_parity("mint contribution", contribution.center, canonical_mint["contribution"])
    trace.check_parity("mint floor", floor_shares.center, canonical_mint["floor_shares"])
    trace.check_identity(
        "mint exposure decomposes into premium plus floor",
        entry_value.center,
        contribution.center + floor_shares.center,
    )

    close_quantity = trace.input(
        "close_quantity",
        scenario.close_quantity,
        "partial_close",
        unit="dusdc_1e6",
        scale=replay.DUSDC_DECIMALS,
        move_site="strike_exposure::quote_live_close",
    )
    remaining_quantity = trace.sub(
        "remaining_quantity",
        stored_quantity,
        close_quantity,
        "partial_close",
        move_site="strike_exposure::quote_live_close",
        unit="dusdc_1e6",
    )
    remaining_floor = trace.mul_div_down(
        "remaining_floor_shares",
        stored_floor,
        remaining_quantity,
        stored_quantity,
        "partial_close",
        move_site="strike_exposure::quote_live_close",
        unit="dusdc_1e6",
        boundary="storage_commitment",
        expression="floor*remaining_quantity/original_quantity",
        note="The survivor floor is one fused floor; the closed slice receives the conserved remainder.",
    )
    removed_floor = trace.sub(
        "remove_floor_shares",
        stored_floor,
        remaining_floor,
        "partial_close",
        move_site="strike_exposure::quote_live_close",
        unit="dusdc_1e6",
        boundary="accounting_commitment",
    )
    close_gross = trace.mul_scaled(
        "gross_redeem_amount",
        entry_probability,
        close_quantity,
        "partial_close",
        move_site="strike_exposure::quote_live_close",
        unit="dusdc_1e6",
    )
    redeem_amount = trace.saturating_sub(
        "redeem_amount",
        close_gross,
        removed_floor,
        "partial_close",
        move_site="strike_exposure::quote_live_close",
        flow_direction="protocol_outflow",
        dust_owner="pool",
        note="A partial slice can owe one more conserved floor unit than its rounded gross value; clamp-to-zero is the explicit liveness policy.",
    )
    canonical_close = replay.compute_live_close_terms(
        entry_probability.center,
        scenario.quantity,
        floor_shares.center,
        scenario.close_quantity,
    )
    trace.check_parity("partial-close remaining floor", remaining_floor.center, canonical_close["remaining_floor_shares"])
    trace.check_parity("partial-close removed floor", removed_floor.center, canonical_close["remove_floor_shares"])
    trace.check_parity("partial-close redeem", redeem_amount.center, canonical_close["redeem_amount"])
    trace.check_identity(
        "partial-close floor is conserved",
        floor_shares.center,
        remaining_floor.center + removed_floor.center,
    )

    settlement_win = trace.sub(
        "settlement_winner_payout",
        stored_quantity,
        stored_floor,
        "settlement",
        move_site="strike_exposure::quote_settled_close",
        unit="dusdc_1e6",
        boundary="money",
        flow_direction="protocol_outflow",
        dust_owner="none",
        note="Settlement liability and payout use these identical stored atoms.",
    )
    trace._node(
        "settlement_loser_payout",
        "settlement",
        "branch_constant",
        0,
        (stored_quantity, stored_floor),
        exact_raw=Fraction(0),
        unit="dusdc_1e6",
        scale=replay.DUSDC_DECIMALS,
        boundary="money",
        flow_direction="protocol_outflow",
        dust_owner="pool",
        move_site="strike_exposure::quote_settled_close",
    )
    trace.check_identity(
        "winner payout equals stored net payout atom",
        settlement_win.center,
        scenario.quantity - floor_shares.center,
    )
    settled_liability = trace.alias(
        "settled_payout_liability_before_close",
        settlement_win,
        "settlement",
        boundary="accounting_commitment",
        move_site="strike_payout_tree::settled_payout_liability",
        note="The one-order winner liability is derived from the same stored quantity and floor atoms as its payout.",
    )
    settled_liability_after = trace.sub(
        "settled_payout_liability_after_close",
        settled_liability,
        settlement_win,
        "settlement",
        move_site="strike_exposure::process_settled_close",
        unit="dusdc_1e6",
        boundary="accounting_commitment",
        note="Exact subtraction is safe because reserve and payout are bit-identical atoms.",
    )
    trace.check_identity(
        "settled payout removal clears the matching liability atom",
        settled_liability_after.center,
        0,
    )

    liquidation_ltv = trace.input(
        "liquidation_ltv",
        replay.LIQUIDATION_LTV,
        "liquidation",
        unit="multiplier_1e9",
        scale=F,
        move_site="strike_exposure::under_liquidation_floor",
    )
    threshold = trace.div_scaled(
        "liquidation_threshold",
        stored_floor,
        liquidation_ltv,
        "liquidation",
        move_site="strike_exposure::under_liquidation_floor",
        unit="dusdc_1e6",
        expression="floor/liquidation_ltv",
    )
    adverse_probability_center = 0
    if floor_shares.center > 0:
        adverse_probability_center = min(entry_probability.center, threshold.center * F // scenario.quantity)
    adverse_probability = trace.input(
        "adverse_mark_probability",
        adverse_probability_center,
        "liquidation",
        unit="probability_1e9",
        scale=F,
        move_site="liquidation_book::correction_value",
        note="Synthetic boundary mark used to exercise the knock-out branch for the same minted accounting atoms.",
    )
    liquidation_gross = trace.mul_scaled(
        "liquidation_gross_value",
        adverse_probability,
        stored_quantity,
        "liquidation",
        move_site="strike_exposure::gross_order_value",
        unit="dusdc_1e6",
    )
    trace._node(
        "liquidation_decision",
        "liquidation",
        "compare_le",
        int(floor_shares.center > 0 and liquidation_gross.center <= threshold.center),
        (liquidation_gross, threshold),
        exact_raw=None,
        unit="boolean",
        boundary="branch",
        move_site="strike_exposure::under_liquidation_floor",
        note="The branch uses scalar centers; Approx error does not select a counterfactual outcome.",
    )

    linear_product = trace.mul_scaled(
        "payout_boundary_start_product",
        entry_probability,
        stored_quantity,
        "nav",
        move_site="strike_payout_tree::walk_linear_subtree",
        unit="dusdc_1e6",
        certify=True,
        expression="range_price*quantity",
    )
    linear = trace._node(
        "payout_tree_linear",
        "nav",
        "signed_shared_boundary_aggregation",
        linear_product.center,
        (entry_probability, stored_quantity, linear_product),
        exact_raw=linear_product.exact_raw,
        error=_sat_add(linear_product.error, 1),
        unit="dusdc_1e6",
        scale=replay.DUSDC_DECIMALS,
        rounding="toward_zero",
        move_site="strike_payout_tree::walk_linear_subtree",
        note="This single-order projection represents its two nonzero signed boundaries with one rounding leaf each; when starts and ends share a boundary, Move multiplies the signed net quantity once.",
    )
    range_value = trace.mul_scaled(
        "correction_range_value",
        entry_probability,
        stored_quantity,
        "nav",
        move_site="liquidation_book::correction_value",
        unit="dusdc_1e6",
        certify=True,
        expression="range_price*quantity",
    )
    correction = trace.clamp_upper(
        "leveraged_floor_correction",
        range_value,
        stored_floor,
        "nav",
        move_site="liquidation_book::correction_value",
        boundary="valuation_policy",
    ) if scenario.leverage != replay.LEVERAGE_ONE_X else trace._node(
        "one_x_floor_correction",
        "nav",
        "constant",
        0,
        (range_value,),
        exact_raw=Fraction(0),
        unit="dusdc_1e6",
        scale=replay.DUSDC_DECIMALS,
        move_site="liquidation_book::correction_value",
    )
    liability_raw = trace.sub(
        "live_liability_raw",
        linear,
        correction,
        "nav",
        move_site="strike_exposure::marked_live_liability",
        unit="dusdc_1e6",
        expression="linear-correction",
    )
    liability = trace.clamp_nonnegative(
        "live_liability",
        liability_raw,
        "nav",
        move_site="strike_exposure::marked_live_liability",
        boundary="valuation_policy",
        note="The economic liability is semantically floored at zero.",
    )
    initial_expiry_cash = trace.input(
        "initial_expiry_cash",
        replay.INITIAL_EXPIRY_CASH,
        "nav",
        unit="dusdc_1e6",
        scale=replay.DUSDC_DECIMALS,
        move_site="expiry_market::current_nav",
    )
    funded_cash = trace.add(
        "expiry_cash_after_mint",
        initial_expiry_cash,
        contribution,
        "nav",
        move_site="expiry_market::current_nav",
    )
    funded_cash = trace.add(
        "expiry_cash_after_fees",
        funded_cash,
        trading_fee,
        "nav",
        move_site="expiry_market::current_nav",
    )
    rebate_rate = trace.input(
        "rebate_reserve_rate",
        replay.TRADING_LOSS_REBATE_RATE,
        "nav",
        unit="probability_1e9",
        scale=F,
        move_site="expiry_cash_config::rebate_reserve_for_fee_basis",
    )
    rebate_reserve = trace.mul_scaled(
        "rebate_reserve",
        trading_fee,
        rebate_rate,
        "nav",
        move_site="expiry_cash_config::rebate_reserve_for_fee_basis",
        unit="dusdc_1e6",
    )
    free_cash_raw = trace.sub(
        "free_cash_raw",
        funded_cash,
        rebate_reserve,
        "nav",
        move_site="expiry_market::current_nav",
        unit="dusdc_1e6",
    )
    free_cash = trace.clamp_nonnegative(
        "free_cash",
        free_cash_raw,
        "nav",
        move_site="expiry_market::current_nav",
        boundary="valuation_policy",
        note="Free cash is an economic floor, not a hidden arithmetic repair.",
    )
    nav_raw = trace.sub(
        "active_market_nav_raw",
        free_cash,
        liability,
        "nav",
        move_site="expiry_market::current_nav",
        unit="dusdc_1e6",
        expression="free_cash-liability",
    )
    nav = trace.clamp_nonnegative(
        "active_market_nav",
        nav_raw,
        "nav",
        move_site="expiry_market::current_nav",
        boundary="valuation_policy",
        note="NAV is semantically floored at zero after subtracting the certified liability.",
    )
    vault_idle = trace.input(
        "vault_idle_balance",
        replay.VAULT_SEED - replay.INITIAL_EXPIRY_CASH,
        "lp",
        unit="dusdc_1e6",
        scale=replay.DUSDC_DECIMALS,
        move_site="plp::lp_pool_value_approx",
    )
    pool_value = trace.add(
        "pool_value",
        vault_idle,
        nav,
        "lp",
        move_site="plp::lp_pool_value_approx",
        unit="dusdc_1e6",
    )
    if pool_value.center == 0:
        withdraw_pool_value_center = 0
        supply_pool_value_center = 0
    else:
        withdraw_pool_value_center = pool_value.center - pool_value.error
        supply_pool_value_center = pool_value.center + pool_value.error
    withdraw_pool_value = trace._node(
        "withdraw_pool_value",
        "lp",
        "nav_bid",
        withdraw_pool_value_center,
        (pool_value,),
        exact_raw=Fraction(withdraw_pool_value_center),
        unit="dusdc_1e6",
        scale=replay.DUSDC_DECIMALS,
        boundary="valuation_policy",
        move_site="plp::finish_flush",
        expression="pool_nav_center-pool_nav_error",
        tags=("nav_bid", "withdrawer"),
        note="The frozen withdrawal mark is the certified NAV lower endpoint.",
    )
    supply_pool_value = trace._node(
        "supply_pool_value",
        "lp",
        "nav_ask",
        supply_pool_value_center,
        (pool_value,),
        exact_raw=Fraction(supply_pool_value_center),
        unit="dusdc_1e6",
        scale=replay.DUSDC_DECIMALS,
        boundary="valuation_policy",
        move_site="plp::finish_flush",
        expression="pool_nav_center+pool_nav_error",
        tags=("nav_ask", "supplier"),
        note="The frozen supply mark is the certified NAV upper endpoint.",
    )
    total_supply = trace.input(
        "plp_total_supply",
        replay.INITIAL_TOTAL_PLP_SUPPLY,
        "lp",
        unit="plp_1e6",
        scale=replay.DUSDC_DECIMALS,
        move_site="lp_book::quote_supply_shares",
    )
    supply_amount = trace.input(
        "supply_amount",
        5_000_000,
        "lp",
        unit="dusdc_1e6",
        scale=replay.DUSDC_DECIMALS,
        move_site="lp_book::quote_supply_shares",
    )
    supplied_shares = trace.mul_div_down(
        "supply_shares",
        supply_amount,
        total_supply,
        supply_pool_value,
        "lp",
        move_site="lp_book::quote_supply_shares",
        unit="plp_1e6",
        boundary="money",
        flow_direction="protocol_inflow",
        dust_owner="pool",
    )
    withdrawn_dusdc = trace.mul_div_down(
        "withdraw_dusdc",
        supplied_shares,
        withdraw_pool_value,
        total_supply,
        "lp",
        move_site="lp_book::quote_withdraw_dusdc",
        unit="dusdc_1e6",
        boundary="money",
        flow_direction="protocol_outflow",
        dust_owner="pool",
    )
    trace.check_parity(
        "LP supply shares",
        supplied_shares.center,
        replay.mul_div_round_down(
            supply_amount.center,
            total_supply.center,
            supply_pool_value.center,
        ),
    )
    trace.check_parity(
        "LP withdraw payout",
        withdrawn_dusdc.center,
        replay.mul_div_round_down(
            supplied_shares.center,
            withdraw_pool_value.center,
            total_supply.center,
        ),
    )
    trace.check_identity(
        "LP round trip never extracts more DUSDC than supplied",
        int(withdrawn_dusdc.center <= supply_amount.center),
        1,
    )
    return trace


def build_trace_bundle() -> dict[str, Any]:
    traces = [trace_scenario(scenario) for scenario in SCENARIOS]
    scenarios = [trace.payload() for trace in traces]
    aggregate_counts = Counter()
    knot_counts = Counter()
    for scenario in scenarios:
        aggregate_counts.update(scenario["operation_counts"])
        knot_counts.update(knot["kind"] for knot in scenario["knots"])
    return {
        "schema": SCHEMA_VERSION,
        "contract_baseline": CONTRACT_BASELINE,
        "pricing_profile": PRICING_PROFILE,
        "canonical_replay": "python_replay.py",
        "scenarios": scenarios,
        "aggregate": {
            "operation_counts": dict(sorted(aggregate_counts.items())),
            "knot_counts": dict(sorted(knot_counts.items())),
            "all_parity_checks_pass": all(
                check["matches"]
                for scenario in scenarios
                for check in scenario["parity_checks"]
            ),
            "all_identities_hold": all(
                identity["holds"]
                for scenario in scenarios
                for identity in scenario["identities"]
            ),
        },
    }


def render_report(bundle: dict[str, Any]) -> str:
    lines = [
        "# Predict algebra lifecycle trace",
        "",
        f"Contract baseline: `{bundle['contract_baseline']}`",
        f"Pricing profile: `{bundle['pricing_profile']}`",
        "",
        f"Scalar parity: **{'PASS' if bundle['aggregate']['all_parity_checks_pass'] else 'FAIL'}**",
        "",
        f"Accounting identities: **{'PASS' if bundle['aggregate']['all_identities_hold'] else 'FAIL'}**",
        "",
        "## Flow coverage",
        "",
    ]
    for scenario in bundle["scenarios"]:
        phases = sorted({node["phase"] for node in scenario["nodes"]})
        lines.append(f"- **{scenario['scenario']}** — {scenario['description']} Phases: {', '.join(phases)}.")
        outputs = scenario["key_outputs"]
        lines.append(
            "  "
            f"Mint price `{outputs['mint_range_price']['center']}` ± `{outputs['mint_range_price']['certificate_error']}`; "
            f"premium `{outputs['net_premium']['center']}`; floor `{outputs['floor_shares']['center']}`; "
            f"partial-close redeem `{outputs['redeem_amount']['center']}`; "
            f"NAV `{outputs['active_market_nav']['center']}` ± `{outputs['active_market_nav']['certificate_error']}`."
        )
    lines.extend(["", "## Operation counts", ""])
    for op, count in bundle["aggregate"]["operation_counts"].items():
        lines.append(f"- `{op}`: {count}")
    lines.extend(["", "## Simplification knots", ""])
    grouped_knots: dict[tuple[str, str, str], dict[str, Any]] = {}
    for scenario in bundle["scenarios"]:
        for knot in scenario["knots"]:
            key = (knot["kind"], knot["summary"], knot.get("proof_obligation", ""))
            grouped = grouped_knots.setdefault(
                key,
                {
                    "kind": knot["kind"],
                    "severity": knot["severity"],
                    "summary": knot["summary"],
                    "proof_obligation": knot.get("proof_obligation", ""),
                    "scenarios": [],
                    "examples": [],
                },
            )
            grouped["scenarios"].append(scenario["scenario"])
            examples = knot.get("nodes") or ([knot["node"]] if knot.get("node") else [])
            grouped["examples"].extend(examples[:2])
    severity_order = {"blocker": 0, "high": 1, "policy": 2, "review": 3, "candidate": 4}
    for knot in sorted(
        grouped_knots.values(),
        key=lambda item: (severity_order.get(item["severity"], 9), item["kind"], item["summary"]),
    ):
        scenarios = ", ".join(sorted(set(knot["scenarios"])))
        examples = ", ".join(knot["examples"][:3])
        suffix = f" Observed in {scenarios}."
        if examples:
            suffix += f" Examples: `{examples}`."
        if knot["proof_obligation"]:
            suffix += f" Gate: {knot['proof_obligation']}"
        lines.append(f"- **{knot['kind']} ({knot['severity']})** — {knot['summary']}{suffix}")
    identity_counts = Counter(
        identity["label"]
        for scenario in bundle["scenarios"]
        for identity in scenario["identities"]
        if identity["holds"]
    )
    lines.extend(["", "## Preserved identities", ""])
    for label, count in sorted(identity_counts.items()):
        lines.append(f"- {label} ({count}/{len(bundle['scenarios'])} scenarios).")
    lines.extend(
        [
            "",
            "## Candidate gate",
            "",
            "A knot is only a hypothesis. Before changing Move, require bit-identical scalar outputs, the same abort and guard domain, identical stored accounting atoms and events, unchanged dust ownership, an equal-or-tighter certificate, and measured Move gas improvement.",
            "",
        ]
    )
    return "\n".join(lines)


def write_bundle(bundle: dict[str, Any], output_dir: Path) -> tuple[Path, Path]:
    output_dir.mkdir(parents=True, exist_ok=True)
    json_path = output_dir / "algebra_trace.json"
    report_path = output_dir / "algebra_knots.md"
    json_path.write_text(json.dumps(bundle, indent=2, sort_keys=True) + "\n")
    report_path.write_text(render_report(bundle))
    return json_path, report_path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path(__file__).with_name("runs") / "algebra-trace",
        help="Ignored directory for algebra_trace.json and algebra_knots.md.",
    )
    args = parser.parse_args()
    bundle = build_trace_bundle()
    json_path, report_path = write_bundle(bundle, args.output_dir)
    print(f"wrote {json_path}")
    print(f"wrote {report_path}")
    if not bundle["aggregate"]["all_parity_checks_pass"]:
        raise SystemExit("algebra trace disagrees with canonical Python replay")
    if not bundle["aggregate"]["all_identities_hold"]:
        raise SystemExit("algebra trace violated an accounting identity")


if __name__ == "__main__":
    main()
