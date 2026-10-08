#!/usr/bin/env python3
"""Write the gas-benchmark results file from a local trace."""

from __future__ import annotations

import sys
from collections import defaultdict
from pathlib import Path
from typing import Any

from sim_artifacts import load_local_trace, write_json


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
    gas = step["gas"]
    return {
        "wallMs": float(step["wallMs"]),
        "computationCost": float(gas["computationCost"]),
        "storageCost": float(gas["storageCost"]),
        "storageRebate": float(gas["storageRebate"]),
        "gasTotal": float(gas["gasTotal"]),
    }


def summarize(rows: list[dict[str, float]]) -> dict[str, Any]:
    return {
        "count": len(rows),
        "gas": stat([row["gasTotal"] for row in rows]),
        "wallMs": stat([row["wallMs"] for row in rows]),
    }


def filled(step: dict[str, Any]) -> bool:
    # A queued mint step covers enqueue, commit, and resolve. It filled when resolve emitted
    # QueuedOrderFilled; otherwise it was refunded at its tick or left waiting.
    return any(event["type"] == "QueuedOrderFilled" for event in step["events"])


def build_results(trace: dict[str, Any]) -> dict[str, Any]:
    by_action: dict[str, list[dict[str, float]]] = defaultdict(list)
    successful_mints: list[dict[str, float]] = []
    rejected_mints: list[dict[str, float]] = []

    for step in trace["steps"]:
        result = execution_result(step)
        by_action[step["action"]].append(result)
        if step["action"] == "mint":
            (successful_mints if filled(step) else rejected_mints).append(result)

    mints = by_action.get("mint", [])
    supplies = by_action.get("request_supply", [])

    return {
        "schema_version": RESULTS_SCHEMA_VERSION,
        "summary": {
            "totalTxs": sum(len(rows) for rows in by_action.values()),
            "attemptedMints": len(mints),
            "successfulMints": len(successful_mints),
            "rejectedMints": len(rejected_mints),
            "targetMints": len(mints),
            "byAction": {
                action: summarize(rows)
                for action, rows in sorted(by_action.items())
                if rows
            },
        },
        "mints": successful_mints,
        "supplies": supplies,
        "rejectedMints": rejected_mints,
    }


def main() -> None:
    if len(sys.argv) != 3:
        print("usage: write_benchmark_results.py <local_trace.json> <results.json>", file=sys.stderr)
        raise SystemExit(2)

    trace_path = Path(sys.argv[1])
    out_path = Path(sys.argv[2])
    trace = load_local_trace(trace_path)
    write_json(out_path, build_results(trace))
    print(f"wrote {out_path}")


if __name__ == "__main__":
    main()
