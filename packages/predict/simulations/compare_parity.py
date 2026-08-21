#!/usr/bin/env python3
"""Compare canonical localnet/Python economics while ignoring chain-time telemetry."""

from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path
from typing import Any


OBSERVATIONAL_EVENT_FIELDS = {
    "minted_at_ms",
    "redeemed_at_ms",
    "pyth_spot_source_timestamp_ms",
    "block_scholes_spot_source_timestamp_ms",
    "block_scholes_forward_source_timestamp_ms",
    "block_scholes_svi_source_timestamp_ms",
    "block_scholes_svi_params_timestamp_ms",
}


def parity_projection(payload: dict[str, Any]) -> dict[str, Any]:
    projected = copy.deepcopy(payload)
    for record in projected.get("records", []):
        for update in record.get("updates", []):
            for field in OBSERVATIONAL_EVENT_FIELDS:
                update.pop(field, None)
    return projected


def validate_action_coverage(payload: dict[str, Any], label: str) -> None:
    scenario = payload.get("scenario")
    if not isinstance(scenario, dict):
        raise SystemExit(f"{label}: missing scenario metadata")
    required = scenario.get("required_actions")
    observed = scenario.get("observed_actions")
    if not isinstance(required, list) or not isinstance(observed, list):
        raise SystemExit(f"{label}: invalid action coverage metadata")
    missing = [action for action in required if action not in observed]
    if missing:
        raise SystemExit(f"{label}: missing required actions: {','.join(missing)}")


def first_difference(left: Any, right: Any, path: str = "$") -> str | None:
    if type(left) is not type(right):
        return f"{path}: types differ ({type(left).__name__} != {type(right).__name__})"
    if isinstance(left, dict):
        if left.keys() != right.keys():
            return f"{path}: keys differ ({sorted(left)} != {sorted(right)})"
        for key in left:
            difference = first_difference(left[key], right[key], f"{path}.{key}")
            if difference is not None:
                return difference
        return None
    if isinstance(left, list):
        if len(left) != len(right):
            return f"{path}: lengths differ ({len(left)} != {len(right)})"
        for index, (left_item, right_item) in enumerate(zip(left, right, strict=True)):
            difference = first_difference(left_item, right_item, f"{path}[{index}]")
            if difference is not None:
                return difference
        return None
    if left != right:
        return f"{path}: values differ ({left!r} != {right!r})"
    return None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("local_data", type=Path)
    parser.add_argument("python_data", type=Path)
    args = parser.parse_args()

    local_payload = json.loads(args.local_data.read_text())
    python_payload = json.loads(args.python_data.read_text())
    validate_action_coverage(local_payload, "local")
    validate_action_coverage(python_payload, "python")
    local = parity_projection(local_payload)
    python = parity_projection(python_payload)
    difference = first_difference(local, python)
    if difference is not None:
        raise SystemExit(f"Parity mismatch: {difference}")


if __name__ == "__main__":
    main()
