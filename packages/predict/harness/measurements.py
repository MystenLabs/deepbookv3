"""Pure measurement reducers for harness trace records."""

from __future__ import annotations

from collections import defaultdict
from typing import Any, Iterable

MONEYNESS_BUCKETS = (
    "ATM (<0.5%)",
    "near (0.5-2%)",
    "far (2-5%)",
    "deep (>5%)",
)


def gas_by_moneyness(records: Iterable[dict[str, Any]]) -> dict[str, list[int]]:
    buckets: dict[str, list[int]] = defaultdict(list)
    for record in records:
        if record.get("type") != "mint" or "gas" not in record:
            continue
        distance = abs(float(record.get("moneyness", 1.0)) - 1.0)
        bucket = (
            MONEYNESS_BUCKETS[0]
            if distance < 0.005
            else MONEYNESS_BUCKETS[1]
            if distance < 0.02
            else MONEYNESS_BUCKETS[2]
            if distance < 0.05
            else MONEYNESS_BUCKETS[3]
        )
        buckets[bucket].append(int(record["gas"]))
    return dict(buckets)


def nav_summary(records: Iterable[dict[str, Any]]) -> dict[str, float | int] | None:
    flushes = sorted(
        (
            record
            for record in records
            if record.get("type") == "flush" and record.get("poolValue") is not None
        ),
        key=lambda record: record["ts"],
    )
    if not flushes:
        return None
    values = [float(record["poolValue"]) for record in flushes]
    peak = values[0]
    max_drawdown = 0.0
    for value in values:
        peak = max(peak, value)
        if peak > 0:
            max_drawdown = max(max_drawdown, (peak - value) / peak)
    return {
        "count": len(values),
        "first": values[0],
        "last": values[-1],
        "min": min(values),
        "max": max(values),
        "max_drawdown": max_drawdown,
    }


def batch_computation(
    records: Iterable[dict[str, Any]],
) -> tuple[list[tuple[str, int, int, int]], list[tuple[str, int]]]:
    grouped: dict[tuple[str, int], list[int]] = defaultdict(list)
    oogs: set[tuple[str, int]] = set()
    for record in records:
        if record.get("type") != "mintBatch":
            continue
        # Namespaced by family: this is no longer the only family emitting mintBatch records, and
        # two families sharing a profile name would otherwise average into one meaningless row.
        family = record.get("family")
        profile = str(record.get("profile") or record.get("phase") or "default")
        if family:
            profile = f"{family}/{profile}"
        size = int(record["n"])
        if record.get("oog"):
            oogs.add((profile, size))
        elif record.get("compGas"):
            grouped[(profile, size)].append(int(record["compGas"]))
    samples = [
        (profile, size, sum(costs) // len(costs), len(costs))
        for (profile, size), costs in sorted(grouped.items())
    ]
    return samples, sorted(oogs)
