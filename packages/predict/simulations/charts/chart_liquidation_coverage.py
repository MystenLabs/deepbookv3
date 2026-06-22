#!/usr/bin/env python3
"""Render liquidation coverage and attribution from Python derived data."""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

from chart_common import (
    LIQUIDATION_ACTION_COLORS,
    LIQUIDATION_ACTION_LABELS,
    LIQUIDATION_ACTION_ORDER,
    PercentFormatter,
    configure_axis,
    plt,
    record_x,
    timeline_mode,
    x_bounds,
)
from sim_artifacts import (
    PREDICT_DERIVED_SCHEMA_VERSION,
    dusdc as to_dusdc,
    int_or_none,
    load_records,
    normalized_action,
)

BUCKET_COUNT = 48


def bucket_index(x: float, x_min: float, x_max: float) -> int:
    index = int((x - x_min) / (x_max - x_min) * BUCKET_COUNT)
    return max(0, min(BUCKET_COUNT - 1, index))


def extract_pressure_series(
    records: list[dict[str, Any]], mode: str, origin: int
) -> dict[str, list[float]]:
    series = {
        "x": [],
        "value_pressure": [],
        "count_pressure": [],
    }
    for record in records:
        liquidation = record.get("liquidation", {})
        count = int_or_none(liquidation.get("liquidatable_count"))
        value = int_or_none(liquidation.get("liquidatable_value"))
        active_count = int_or_none(liquidation.get("active_count"))
        leveraged_floor = int_or_none(liquidation.get("leveraged_floor_value"))
        if count is None or value is None or active_count is None or leveraged_floor is None:
            continue
        series["x"].append(record_x(record, mode, origin))
        series["value_pressure"].append(0.0 if leveraged_floor <= 0 else value / leveraged_floor)
        series["count_pressure"].append(0.0 if active_count <= 0 else count / active_count)
    return series


def bucket_liquidation_flow(
    records: list[dict[str, Any]], mode: str, origin: int
) -> dict[str, Any]:
    x_min, x_max = x_bounds(records, mode, origin)
    width = (x_max - x_min) / BUCKET_COUNT
    centers = [x_min + width * (index + 0.5) for index in range(BUCKET_COUNT)]
    by_action = {action: [0.0 for _ in range(BUCKET_COUNT)] for action in LIQUIDATION_ACTION_ORDER}
    has_interval_fields = any(
        record.get("liquidation", {}).get("interval_liquidated_value_by_action") is not None
        for record in records
    )

    if has_interval_fields:
        for record in records:
            liquidation = record.get("liquidation", {})
            values_by_action = liquidation.get("interval_liquidated_value_by_action")
            if values_by_action is None:
                continue
            x = record_x(record, mode, origin)
            index = bucket_index(x, x_min, x_max)
            for action, raw_value in values_by_action.items():
                if action in by_action:
                    by_action[action][index] += to_dusdc(int(raw_value))
        return {
            "centers": centers,
            "width": width * 0.86,
            "by_action": by_action,
        }

    for record in records:
        liquidation = record.get("liquidation", {})
        index = bucket_index(record_x(record, mode, origin), x_min, x_max)

        value = int(liquidation.get("liquidated_value") or 0)
        if value <= 0:
            continue
        action = normalized_action(record["action"])
        if action not in by_action:
            continue
        by_action[action][index] += to_dusdc(value)

    return {
        "centers": centers,
        "width": width * 0.86,
        "by_action": by_action,
    }


def apply_percent_ylim(ax: plt.Axes, values: list[float], minimum_top: float = 0.02) -> None:
    if not values:
        ax.set_ylim(0, minimum_top)
        return
    observed = max(values)
    top = min(1.0, max(minimum_top, observed * 1.2))
    ax.set_ylim(0, top)


def plot_pressure_panel(ax: plt.Axes, pressure: dict[str, list[float]]) -> None:
    ax.plot(
        pressure["x"],
        pressure["value_pressure"],
        color="#dc2626",
        linewidth=1.5,
        label="value pressure (% leveraged floor)",
    )
    ax.plot(
        pressure["x"],
        pressure["count_pressure"],
        color="#2563eb",
        linewidth=1.25,
        label="count pressure (% active orders)",
    )
    ax.axhline(0, color="#64748b", linewidth=0.8)
    ax.yaxis.set_major_formatter(PercentFormatter(xmax=1.0))
    apply_percent_ylim(ax, pressure["value_pressure"] + pressure["count_pressure"])
    ax.set_title(
        "Backlog Pressure\n"
        "Point-in-time percentages show what share of the leveraged floor book and active orders is liquidatable.",
        loc="left",
        fontsize=11,
    )
    ax.set_ylabel("share of leveraged book")
    configure_axis(ax)
    ax.legend(loc="upper left", ncols=2, fontsize=8, frameon=False)


def plot_throughput_panel(ax: plt.Axes, buckets: dict[str, Any]) -> None:
    bottoms = [0.0 for _ in buckets["centers"]]
    for action in LIQUIDATION_ACTION_ORDER:
        values = buckets["by_action"][action]
        ax.bar(
            buckets["centers"],
            values,
            width=buckets["width"],
            bottom=bottoms,
            color=LIQUIDATION_ACTION_COLORS[action],
            alpha=0.82,
            label=LIQUIDATION_ACTION_LABELS[action],
        )
        bottoms = [bottom + value for bottom, value in zip(bottoms, values)]

    ax.set_title(
        "Liquidated Value By Trigger\n"
        "Bucketed liquidation throughput shows which transaction types actually clear risk.",
        loc="left",
        fontsize=11,
    )
    ax.set_ylabel("DUSDC")
    configure_axis(ax)
    ax.legend(loc="upper left", ncols=3, fontsize=8, frameon=False)


def render(derived_path: Path, output_path: Path) -> None:
    records = load_records(derived_path, PREDICT_DERIVED_SCHEMA_VERSION)
    if not records:
        raise ValueError(f"{derived_path} has no records")

    mode, origin, x_label = timeline_mode(records)
    pressure = extract_pressure_series(records, mode, origin)
    buckets = bucket_liquidation_flow(records, mode, origin)

    fig = plt.figure(figsize=(13, 8), constrained_layout=False)
    grid = fig.add_gridspec(
        2,
        1,
        height_ratios=[2.0, 2.0],
        hspace=0.34,
        top=0.84,
    )
    ax_pressure = fig.add_subplot(grid[0])
    ax_throughput = fig.add_subplot(grid[1], sharex=ax_pressure)

    fig.suptitle("Liquidation Coverage And Attribution", fontsize=16, fontweight="bold", x=0.075, ha="left")
    fig.text(
        0.075,
        0.93,
        "Shows normalized liquidation pressure and which transaction types clear liquidation risk.",
        fontsize=10,
        color="#475569",
        ha="left",
    )

    plot_pressure_panel(ax_pressure, pressure)
    plot_throughput_panel(ax_throughput, buckets)

    ax_pressure.tick_params(labelbottom=False)
    ax_throughput.set_xlabel(x_label)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(output_path, dpi=180, bbox_inches="tight")
    plt.close(fig)


def main() -> None:
    if len(sys.argv) != 2:
        print(
            "usage: chart_liquidation_coverage.py <python_derived.json>",
            file=sys.stderr,
        )
        raise SystemExit(2)

    derived_path = Path(sys.argv[1])
    output_path = derived_path.with_name("chart_liquidation_coverage.png")
    render(derived_path, output_path)
    print(f"wrote {output_path}")


if __name__ == "__main__":
    main()
