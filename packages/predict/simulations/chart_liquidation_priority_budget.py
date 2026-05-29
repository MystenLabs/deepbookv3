#!/usr/bin/env python3
"""Render liquidation scanner effectiveness charts."""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

from chart_common import PercentFormatter, configure_axis, plt
from sim_artifacts import FLOAT_SCALING, PREDICT_DERIVED_SCHEMA_VERSION, int_or_none, load_records, percentile


def aggregate_priority_curve(records: list[dict[str, Any]]) -> tuple[list[float], list[float]]:
    bucket_totals: list[int] | None = None
    for record in records:
        values = record.get("liquidation", {}).get("rank_bucket_liquidatable_value")
        if values is None:
            continue
        parsed = [int(value) for value in values]
        if bucket_totals is None:
            bucket_totals = [0 for _ in parsed]
        for index, value in enumerate(parsed):
            bucket_totals[index] += value

    if not bucket_totals or sum(bucket_totals) == 0:
        return [], []
    total = sum(bucket_totals)
    running = 0
    xs: list[float] = []
    ys: list[float] = []
    for index, value in enumerate(bucket_totals, start=1):
        running += value
        xs.append(index / len(bucket_totals))
        ys.append(running / total)
    return xs, ys


def policy_capture_stats(records: list[dict[str, Any]]) -> dict[str, dict[str, float]]:
    values_by_budget: dict[str, list[float]] = {}
    for record in records:
        shares = record.get("liquidation", {}).get("policy_capture_share_by_budget")
        if not isinstance(shares, dict):
            continue
        for budget, value in shares.items():
            parsed = int_or_none(value)
            if parsed is None:
                continue
            values_by_budget.setdefault(budget, []).append(parsed / FLOAT_SCALING)

    stats: dict[str, dict[str, float]] = {}
    for budget, values in values_by_budget.items():
        ordered = sorted(values)
        stats[budget] = {
            "p50": percentile(ordered, 0.50),
            "p95": percentile(ordered, 0.95),
            "max": ordered[-1],
        }
    return dict(sorted(stats.items(), key=lambda item: int(item[0])))


def mean_capture_breakdown(records: list[dict[str, Any]]) -> dict[str, dict[str, float]]:
    totals: dict[str, dict[str, float]] = {}
    counts: dict[str, int] = {}
    for record in records:
        liquidation = record.get("liquidation", {})
        head = liquidation.get("head_capture_share_by_budget")
        watermark = liquidation.get("watermark_capture_share_by_budget")
        missed = liquidation.get("missed_share_by_budget")
        if not isinstance(head, dict) or not isinstance(watermark, dict) or not isinstance(missed, dict):
            continue
        for budget in sorted(set(head) | set(watermark) | set(missed), key=int):
            head_value = int_or_none(head.get(budget))
            watermark_value = int_or_none(watermark.get(budget))
            missed_value = int_or_none(missed.get(budget))
            if head_value is None or watermark_value is None or missed_value is None:
                continue
            totals.setdefault(budget, {"head": 0.0, "watermark": 0.0, "missed": 0.0})
            totals[budget]["head"] += head_value / FLOAT_SCALING
            totals[budget]["watermark"] += watermark_value / FLOAT_SCALING
            totals[budget]["missed"] += missed_value / FLOAT_SCALING
            counts[budget] = counts.get(budget, 0) + 1
    return {
        budget: {component: value / counts[budget] for component, value in values.items()}
        for budget, values in sorted(totals.items(), key=lambda item: int(item[0]))
        if counts.get(budget, 0) > 0
    }


def plot_priority_curve(ax: plt.Axes, xs: list[float], ys: list[float]) -> None:
    ax.plot(xs, ys, color="#2563eb", linewidth=1.8, label="liquidation vector")
    ax.plot([0, 1], [0, 1], color="#64748b", linewidth=0.9, linestyle="--", label="random baseline")
    ax.set_xlim(0, 1)
    ax.set_ylim(0, 1)
    ax.xaxis.set_major_formatter(PercentFormatter(xmax=1.0))
    ax.yaxis.set_major_formatter(PercentFormatter(xmax=1.0))
    ax.set_title(
        "Priority Concentration\n"
        "Aggregate curve shows whether the static priority key concentrates liquidatable value near the front.",
        loc="left",
        fontsize=11,
    )
    ax.set_xlabel("front of liquidation vector scanned")
    ax.set_ylabel("liquidatable value captured")
    configure_axis(ax)
    ax.legend(loc="upper left", fontsize=8, frameon=False)


def plot_policy_capture(ax: plt.Axes, stats: dict[str, dict[str, float]]) -> None:
    budgets = list(stats.keys())
    x_values = list(range(len(budgets)))
    p50 = [stats[budget]["p50"] for budget in budgets]
    p95 = [stats[budget]["p95"] for budget in budgets]
    max_values = [stats[budget]["max"] for budget in budgets]
    ax.plot(x_values, p50, color="#93c5fd", marker="o", linewidth=1.4, label="p50 capture")
    ax.plot(x_values, p95, color="#2563eb", marker="s", linewidth=1.4, label="p95 capture")
    ax.plot(x_values, max_values, color="#7c3aed", marker="^", linewidth=1.2, label="max capture")
    ax.set_xticks(x_values)
    ax.set_xticklabels(budgets)
    ax.set_ylim(0, 1)
    ax.yaxis.set_major_formatter(PercentFormatter(xmax=1.0))
    ax.set_title(
        "Policy Capture By Budget\n"
        "Uses the scanner's head-plus-watermark policy to show p50/p95/max capture of standing liquidatable value.",
        loc="left",
        fontsize=11,
    )
    ax.set_xlabel("scan budget")
    ax.set_ylabel("capture share")
    configure_axis(ax)
    ax.legend(loc="upper left", ncols=3, fontsize=8, frameon=False)


def plot_capture_breakdown(ax: plt.Axes, breakdown: dict[str, dict[str, float]]) -> None:
    budgets = list(breakdown.keys())
    x_values = list(range(len(budgets)))
    head = [breakdown[budget]["head"] for budget in budgets]
    watermark = [breakdown[budget]["watermark"] for budget in budgets]
    missed = [breakdown[budget]["missed"] for budget in budgets]
    ax.bar(x_values, head, color="#2563eb", alpha=0.82, label="head scan")
    ax.bar(x_values, watermark, bottom=head, color="#0891b2", alpha=0.82, label="watermark scan")
    ax.bar(
        x_values,
        missed,
        bottom=[head_value + watermark_value for head_value, watermark_value in zip(head, watermark)],
        color="#dc2626",
        alpha=0.72,
        label="missed",
    )
    ax.set_xticks(x_values)
    ax.set_xticklabels(budgets)
    ax.set_ylim(0, 1)
    ax.yaxis.set_major_formatter(PercentFormatter(xmax=1.0))
    ax.set_title(
        "Head vs Watermark Contribution\n"
        "Mean capture split shows whether policy performance comes from priority head scan or watermark sweep.",
        loc="left",
        fontsize=11,
    )
    ax.set_xlabel("scan budget")
    ax.set_ylabel("mean share of liquidatable value")
    configure_axis(ax)
    ax.legend(loc="upper left", ncols=3, fontsize=8, frameon=False)


def render(derived_path: Path, output_path: Path) -> bool:
    records = load_records(derived_path, PREDICT_DERIVED_SCHEMA_VERSION)
    if not records:
        raise ValueError(f"{derived_path} has no records")
    curve_x, curve_y = aggregate_priority_curve(records)
    capture_stats = policy_capture_stats(records)
    breakdown = mean_capture_breakdown(records)
    if not curve_x or not capture_stats or not breakdown:
        print(
            f"skipping {output_path}: derived data has no scanner policy fields; rerun python_replay.py"
        )
        return False

    fig = plt.figure(figsize=(13, 12), constrained_layout=False)
    grid = fig.add_gridspec(
        3,
        1,
        height_ratios=[2.0, 2.0, 2.0],
        hspace=0.38,
        top=0.88,
    )
    ax_priority = fig.add_subplot(grid[0])
    ax_capture = fig.add_subplot(grid[1])
    ax_breakdown = fig.add_subplot(grid[2])

    fig.suptitle("Liquidation Scanner Effectiveness", fontsize=16, fontweight="bold", x=0.075, ha="left")
    fig.text(
        0.075,
        0.93,
        "Shows whether priority ordering concentrates risk and how the actual head-plus-watermark scanner captures it.",
        fontsize=10,
        color="#475569",
        ha="left",
    )

    plot_priority_curve(ax_priority, curve_x, curve_y)
    plot_policy_capture(ax_capture, capture_stats)
    plot_capture_breakdown(ax_breakdown, breakdown)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(output_path, dpi=180, bbox_inches="tight")
    plt.close(fig)
    return True


def main() -> None:
    if len(sys.argv) != 2:
        print(
            "usage: chart_liquidation_priority_budget.py <python_derived.json>",
            file=sys.stderr,
        )
        raise SystemExit(2)

    derived_path = Path(sys.argv[1])
    output_path = derived_path.with_name("chart_liquidation_priority_budget.png")
    if render(derived_path, output_path):
        print(f"wrote {output_path}")


if __name__ == "__main__":
    main()
