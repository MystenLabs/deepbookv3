"""Shared chart helpers for Predict simulation visualizations."""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

SIMULATIONS_DIR = Path(__file__).resolve().parents[1]
if str(SIMULATIONS_DIR) not in sys.path:
    sys.path.insert(0, str(SIMULATIONS_DIR))

try:
    import matplotlib

    matplotlib.use("Agg")

    import matplotlib.pyplot as plt
    from matplotlib.ticker import PercentFormatter
except ImportError as exc:
    raise SystemExit("matplotlib is required to render simulation charts") from exc

FLOW_ACTION_LABELS = {
    "mint": "mint",
    "redeem": "redeem",
    "supply": "supply",
    "withdraw": "withdraw",
    "flush": "flush",
}
FLOW_ACTION_COLORS = {
    "mint": "#2563eb",
    "redeem": "#7c3aed",
    "supply": "#0891b2",
    "withdraw": "#f97316",
    "flush": "#dc2626",
}

LIQUIDATION_ACTION_ORDER = ("mint", "redeem", "supply", "withdraw")
LIQUIDATION_ACTION_LABELS = {
    "mint": "passive mint",
    "redeem": "passive redeem",
    "supply": "passive supply",
    "withdraw": "passive withdraw",
}
LIQUIDATION_ACTION_COLORS = {
    **FLOW_ACTION_COLORS,
}


def configure_axis(ax: plt.Axes, *, grid_axis: str = "y") -> None:
    ax.grid(True, axis=grid_axis, color="#d7dde5", linewidth=0.8, alpha=0.7)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)


def timeline_mode(records: list[dict[str, Any]]) -> tuple[str, int, str]:
    return timeline_mode_from_records(records)


def timeline_mode_from_records(*record_sets: list[dict[str, Any]]) -> tuple[str, int, str]:
    for records in record_sets:
        for record in records:
            timestamp_ms = record.get("timestamp_ms")
            if timestamp_ms is not None:
                return "timestamp", int(timestamp_ms), "source elapsed hours"
    return "step", 0, "transaction"


def record_x(record: dict[str, Any], mode: str, origin: int) -> float:
    if mode == "timestamp":
        timestamp_ms = record.get("timestamp_ms")
        if timestamp_ms is not None:
            return (int(timestamp_ms) - origin) / 3_600_000
    return float(record.get("step", 0))


def x_bounds(records: list[dict[str, Any]], mode: str, origin: int) -> tuple[float, float]:
    xs = [record_x(record, mode, origin) for record in records]
    if not xs:
        return 0.0, 1.0
    lo = min(xs)
    hi = max(xs)
    if lo == hi:
        hi = lo + 1.0
    return lo, hi
