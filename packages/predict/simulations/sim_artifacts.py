"""Simulation artifact schemas and external gas-benchmark adapter helpers."""

from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Any

LOCAL_TRACE_SCHEMA_VERSION = "predict_local_trace_v5"
LOCAL_TRACE_ACTIONS = {
    "mint",
    "redeem_live",
    "request_supply",
    "request_withdraw",
    "flush",
    "rebalance_expiry_cash",
    "settle",
    "redeem_settled",
}
_TRACE_FIELDS = {"schema_version", "steps"}
_STEP_FIELDS = {
    "step",
    "action",
    "digest",
    "pricingTimestampMs",
    "wallMs",
    "gas",
    "events",
}
_GAS_FIELDS = {
    "computationCost",
    "storageCost",
    "storageRebate",
    "nonRefundableStorageFee",
    "gasTotal",
}
_EVENT_FIELDS = {"type", "full_type", "parsedJson"}


def _require_exact_fields(value: dict[str, Any], expected: set[str], path: str) -> None:
    missing = sorted(expected - value.keys())
    unknown = sorted(value.keys() - expected)
    if missing or unknown:
        details = []
        if missing:
            details.append(f"missing={','.join(missing)}")
        if unknown:
            details.append(f"unknown={','.join(unknown)}")
        raise ValueError(f"{path} schema mismatch; {'; '.join(details)}")


def _is_finite_number(value: Any) -> bool:
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(value)
    )


def load_local_trace(path: Path) -> dict[str, Any]:
    trace = json.loads(path.read_text())
    if not isinstance(trace, dict):
        raise ValueError(f"{path} must contain a JSON object")
    if trace.get("schema_version") != LOCAL_TRACE_SCHEMA_VERSION:
        raise ValueError(
            f"{path} must use schema_version='{LOCAL_TRACE_SCHEMA_VERSION}'"
        )
    _require_exact_fields(trace, _TRACE_FIELDS, str(path))
    steps = trace["steps"]
    if not isinstance(steps, list) or not steps:
        raise ValueError(f"{path}.steps must be a non-empty array")

    for index, step in enumerate(steps):
        location = f"{path}.steps[{index}]"
        if not isinstance(step, dict):
            raise ValueError(f"{location} must be an object")
        _require_exact_fields(step, _STEP_FIELDS, location)
        if type(step["step"]) is not int or step["step"] < 0:
            raise ValueError(f"{location}.step must be a non-negative integer")
        if (
            not isinstance(step["action"], str)
            or step["action"] not in LOCAL_TRACE_ACTIONS
        ):
            raise ValueError(f"{location}.action is invalid")
        if not isinstance(step["digest"], str) or not step["digest"]:
            raise ValueError(f"{location}.digest must be a non-empty string")
        if (
            type(step["pricingTimestampMs"]) is not int
            or step["pricingTimestampMs"] < 0
        ):
            raise ValueError(
                f"{location}.pricingTimestampMs must be a non-negative integer"
            )
        if not _is_finite_number(step["wallMs"]) or step["wallMs"] < 0:
            raise ValueError(f"{location}.wallMs must be a non-negative finite number")

        gas = step["gas"]
        if not isinstance(gas, dict):
            raise ValueError(f"{location}.gas must be an object")
        _require_exact_fields(gas, _GAS_FIELDS, f"{location}.gas")
        for field in _GAS_FIELDS:
            if type(gas[field]) is not int:
                raise ValueError(f"{location}.gas.{field} must be an integer")
            if field != "gasTotal" and gas[field] < 0:
                raise ValueError(f"{location}.gas.{field} must be non-negative")

        events = step["events"]
        if not isinstance(events, list):
            raise ValueError(f"{location}.events must be an array")
        for event_index, event in enumerate(events):
            event_location = f"{location}.events[{event_index}]"
            if not isinstance(event, dict):
                raise ValueError(f"{event_location} must be an object")
            _require_exact_fields(event, _EVENT_FIELDS, event_location)
            for field in ("type", "full_type"):
                if not isinstance(event[field], str) or not event[field]:
                    raise ValueError(f"{event_location}.{field} must be a non-empty string")
            if not isinstance(event["parsedJson"], dict):
                raise ValueError(f"{event_location}.parsedJson must be an object")

    return trace


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def normalized_action(action: str) -> str:
    return action
