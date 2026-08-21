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


def cost_curve(
    records: Iterable[dict[str, Any]],
    record_type: str,
    sizes: list[tuple[int, int, str]],
) -> list[tuple[int, int]]:
    """Join per-transaction computation cost to the book size in force when it ran.

    `sizes` is `(ts, size, market)` in ascending `ts`, as a size-emitting strategy
    traces it. There is no on-chain read that reports a payout tree's node count,
    so size is carried by the actor that built the book and matched to the measured
    transaction by timestamp, per market: the newest size at or before the
    transaction is the book it saw. Records whose market never reported a size drop
    out rather than being credited with someone else's book.
    """
    latest: dict[str, int] = {}
    by_market: dict[str, list[tuple[int, int]]] = defaultdict(list)
    for ts, size, market in sizes:
        by_market[market].append((ts, size))
    points: list[tuple[int, int]] = []
    for record in sorted(
        (
            record
            for record in records
            if record.get("type") == record_type
            and record.get("ts")
            and record.get("compGas")
            and record.get("market")
        ),
        key=lambda record: record["ts"],
    ):
        market = str(record["market"])
        for ts, size in by_market.get(market, ()):
            if ts <= record["ts"]:
                latest[market] = size
            else:
                break
        size = latest.get(market, 0)
        if size > 0:
            points.append((size, int(record["compGas"])))
    return points


def cap_crossing(
    points: list[tuple[int, int]], cap: int
) -> tuple[float, float, int] | None:
    """Least-squares `(slope, intercept, size at which cost reaches cap)`.

    None when the samples cannot place a line (fewer than two points, one distinct
    size, or a non-increasing fit), so a caller reports the raw peak instead of
    extrapolating a crossing from noise.
    """
    count = len(points)
    if count < 2:
        return None
    sum_size = sum(size for size, _ in points)
    sum_cost = sum(cost for _, cost in points)
    denominator = count * sum(size * size for size, _ in points) - sum_size * sum_size
    if not denominator:
        return None
    slope = (count * sum(size * cost for size, cost in points) - sum_size * sum_cost) / denominator
    if slope <= 0:
        return None
    intercept = (sum_cost - slope * sum_size) / count
    return slope, intercept, int((cap - intercept) / slope)


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
