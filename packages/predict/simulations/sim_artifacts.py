"""Shared artifact, schema, and numeric helpers for Predict simulations."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Sequence, TypeVar

PREDICT_ECONOMIC_SCHEMA_VERSION = "predict_economic_v2"
PREDICT_DERIVED_SCHEMA_VERSION = "predict_derived_v2"

DUSDC_DECIMALS = 1_000_000
DUSDC_SCALING = DUSDC_DECIMALS
FLOAT_SCALING = 1_000_000_000
MIST_PER_SUI = 1_000_000_000

Number = TypeVar("Number", int, float)


def load_json(path: Path) -> Any:
    return json.loads(path.read_text())


def load_optional_json(path: Path) -> Any | None:
    if not path.exists():
        return None
    return load_json(path)


def load_json_object(path: Path, schema_version: str | None = None) -> dict[str, Any]:
    data = load_json(path)
    if not isinstance(data, dict):
        raise ValueError(f"{path} must contain a JSON object")
    if schema_version is not None and data.get("schema_version") != schema_version:
        raise ValueError(f"{path} must use schema_version='{schema_version}'")
    return data


def records_from_payload(payload: dict[str, Any], path: Path) -> list[dict[str, Any]]:
    records = payload.get("records")
    if not isinstance(records, list):
        raise ValueError(f"{path} is missing records[]")
    return records


def load_records(path: Path, schema_version: str | None = None) -> list[dict[str, Any]]:
    return records_from_payload(load_json_object(path, schema_version), path)


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def int_or_none(value: Any) -> int | None:
    if value is None:
        return None
    return int(value)


def int_or_zero(value: Any) -> int:
    if value is None:
        return 0
    return int(value)


def dusdc(value: int) -> float:
    return value / DUSDC_DECIMALS


def sui(value: int) -> float:
    return value / MIST_PER_SUI


def ratio(value: int) -> float:
    return value / FLOAT_SCALING


def normalized_action(action: str) -> str:
    return "mint" if action == "oracle_mint_ptb" else action


def percentile(sorted_values: Sequence[Number], pct: float) -> Number | int:
    if not sorted_values:
        return 0
    if len(sorted_values) == 1:
        return sorted_values[0]
    return sorted_values[round((len(sorted_values) - 1) * pct)]
