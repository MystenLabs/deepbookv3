#!/usr/bin/env python3
"""Write the legacy gas-benchmark results file from a local trace."""

from __future__ import annotations

import sys
from collections import defaultdict
from pathlib import Path
from typing import Any

from sim_artifacts import load_json_object, normalized_action, write_json


RESULTS_SCHEMA_VERSION = "results_v3"


def stat(values: list[float]) -> dict[str, float]:
    if not values:
        return {"avg": 0.0, "min": 0.0, "max": 0.0}
    return {
        "avg": sum(values) / len(values),
        "min": min(values),
        "max": max(values),
    }


def execution_result(step: dict[str, Any]) -> dict[str, float]:
    gas = step.get("gas") or {}
    return {
        "wallMs": float(step.get("wallMs") or 0),
        "computationCost": float(gas.get("computationCost") or 0),
        "storageCost": float(gas.get("storageCost") or 0),
        "storageRebate": float(gas.get("storageRebate") or 0),
        "gasTotal": float(gas.get("gasTotal") or 0),
    }


def summarize(rows: list[dict[str, float]]) -> dict[str, Any]:
    return {
        "count": len(rows),
        "gas": stat([row["gasTotal"] for row in rows]),
        "wallMs": stat([row["wallMs"] for row in rows]),
    }


def build_results(trace: dict[str, Any]) -> dict[str, Any]:
    by_action: dict[str, list[dict[str, float]]] = defaultdict(list)

    for step in trace.get("steps", []):
        action = normalized_action(str(step.get("action", "")))
        by_action[action].append(execution_result(step))

    mints = by_action.get("mint", [])
    supplies = by_action.get("supply", [])

    return {
        "schema_version": RESULTS_SCHEMA_VERSION,
        "summary": {
            "totalTxs": sum(len(rows) for rows in by_action.values()),
            "attemptedMints": len(mints),
            "successfulMints": len(mints),
            "rejectedMints": 0,
            "targetMints": len(mints),
            "byAction": {
                action: summarize(rows)
                for action, rows in sorted(by_action.items())
                if rows
            },
        },
        "mints": mints,
        "supplies": supplies,
        "rejectedMints": [],
    }


def main() -> None:
    if len(sys.argv) != 3:
        print("usage: write_benchmark_results.py <local_trace.json> <results.json>", file=sys.stderr)
        raise SystemExit(2)

    trace_path = Path(sys.argv[1])
    out_path = Path(sys.argv[2])
    trace = load_json_object(trace_path, "predict_local_trace_v2")
    write_json(out_path, build_results(trace))
    print(f"wrote {out_path}")


if __name__ == "__main__":
    main()
