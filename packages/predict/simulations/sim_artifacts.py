"""Artifact helpers retained by the external gas-benchmark adapter."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any


def load_json_object(path: Path, schema_version: str) -> dict[str, Any]:
    data = json.loads(path.read_text())
    if not isinstance(data, dict):
        raise ValueError(f"{path} must contain a JSON object")
    if data.get("schema_version") != schema_version:
        raise ValueError(f"{path} must use schema_version='{schema_version}'")
    return data


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def normalized_action(action: str) -> str:
    return "mint" if action == "oracle_mint_ptb" else action
