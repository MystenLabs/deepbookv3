#!/usr/bin/env python3
"""Render liquidation execution quality from a Predict economic dataset."""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

from chart_common import PercentFormatter, plt
from sim_artifacts import FLOAT_SCALING, PREDICT_ECONOMIC_SCHEMA_VERSION, dusdc as to_dusdc, load_records, percentile


def liquidation_threshold_value(update: dict[str, Any], floor: int) -> int:
    ltv = update.get("liquidation_ltv")
    if ltv is None:
        raise ValueError("order_liquidated update is missing liquidation_ltv")
    numerator = floor * FLOAT_SCALING
    denominator = int(ltv)
    return numerator // denominator + (0 if numerator % denominator == 0 else 1)


def liquidation_events(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    source_start_ms = next((int(record["timestamp_ms"]) for record in records if record.get("timestamp_ms") is not None), None)
    for record in records:
        timestamp_ms = record.get("timestamp_ms")
        for update in record["updates"]:
            if update["type"] != "order_liquidated":
                continue
            floor = int(update["floor_amount"])
            gross = int(update["gross_value"])
            quantity = int(update["quantity"])
            threshold = liquidation_threshold_value(update, floor)
            gap = max(0, floor - gross)
            surplus = max(0, gross - floor)
            events.append(
                {
                    "step": int(record["step"]),
                    "timestamp_ms": None if timestamp_ms is None else int(timestamp_ms),
                    "source_start_ms": source_start_ms,
                    "floor": floor,
                    "gross": gross,
                    "threshold": threshold,
                    "gap": gap,
                    "surplus": surplus,
                    "quantity": quantity,
                    "floor_price": floor / quantity if quantity else 0.0,
                    "gross_price": gross / quantity if quantity else 0.0,
                    "threshold_price": threshold / quantity if quantity else 0.0,
                    "gap_ratio": gap / floor if floor else 0.0,
                }
            )
    return events


def timeline_values(events: list[dict[str, Any]]) -> tuple[list[float], str]:
    timestamps = [event["timestamp_ms"] for event in events]
    if all(timestamp is not None for timestamp in timestamps):
        start = events[0].get("source_start_ms") or min(timestamp for timestamp in timestamps if timestamp is not None)
        return ([(timestamp - start) / 3_600_000 for timestamp in timestamps if timestamp is not None], "source elapsed hours")
    return ([event["step"] for event in events], "CSV tx")


def decorate(ax) -> None:
    ax.grid(True, alpha=0.28)
    ax.legend(loc="upper left")


def set_subtitle(fig, subtitle: str) -> None:
    fig.text(0.5, 0.955, subtitle, ha="center", va="top", fontsize=10, color="#475569")


def chart_execution_quality(events: list[dict[str, Any]], out_path: Path) -> None:
    if not events:
        fig, ax = plt.subplots(1, 1, figsize=(12, 5))
        fig.suptitle("Liquidation Execution Quality", fontsize=16, y=0.98)
        set_subtitle(
            fig,
            "Shows execution value versus debt floor and the LTV trigger, with bad debt only below the floor.",
        )
        ax.text(
            0.5,
            0.5,
            "No order_liquidated updates were produced in this run.",
            ha="center",
            va="center",
            fontsize=12,
            color="#475569",
            transform=ax.transAxes,
        )
        ax.set_axis_off()
        fig.tight_layout(rect=(0, 0, 1, 0.9))
        fig.savefig(out_path, dpi=150)
        plt.close(fig)
        print(f"  Saved {out_path}")
        return

    ratios = sorted(event["gap_ratio"] for event in events)
    p50 = percentile(ratios, 0.50)
    p95 = percentile(ratios, 0.95)
    p99 = percentile(ratios, 0.99)
    total_floor = sum(event["floor"] for event in events)
    total_gap = sum(event["gap"] for event in events)
    weighted_gap_ratio = total_gap / total_floor if total_floor else 0.0

    max_price = max(max(event["floor_price"], event["gross_price"], event["threshold_price"]) for event in events)
    price_pad = max_price * 0.05 if max_price else 0.05
    max_price += price_pad

    net_steps, net_label = timeline_values(events)
    cumulative_bad_debt = []
    cumulative_surplus = []
    cumulative_net = []
    running_bad_debt = 0
    running_surplus = 0
    for event in events:
        running_bad_debt += event["gap"]
        running_surplus += event["surplus"]
        cumulative_bad_debt.append(to_dusdc(running_bad_debt))
        cumulative_surplus.append(to_dusdc(running_surplus))
        cumulative_net.append(to_dusdc(running_surplus - running_bad_debt))

    fig, axes = plt.subplots(3, 1, figsize=(12, 13))
    fig.suptitle("Liquidation Execution Quality", fontsize=16, y=0.988)
    set_subtitle(
        fig,
        "Shows execution value versus debt floor and the LTV trigger, with bad debt only below the floor.",
    )

    ax = axes[0]
    ax.scatter(
        [event["floor_price"] for event in events],
        [event["gross_price"] for event in events],
        s=12,
        alpha=0.42,
        color="#2563eb",
        label="liquidations",
    )
    ax.plot([0, max_price], [0, max_price], color="#334155", linewidth=1.0, linestyle="--", label="no bad debt")
    threshold_slopes = sorted(
        event["threshold_price"] / event["floor_price"]
        for event in events
        if event["floor_price"] > 0 and event["threshold_price"] > 0
    )
    if threshold_slopes:
        slope = percentile(threshold_slopes, 0.50)
        ax.plot(
            [0, max_price / slope],
            [0, max_price],
            color="#ea580c",
            linewidth=1.0,
            linestyle=":",
            label="LTV liquidation trigger",
        )
    ax.set_xlim(0, max_price)
    ax.set_ylim(0, max_price)
    ax.set_xlabel("liquidation floor per contract")
    ax.set_ylabel("execution value per contract")
    ax.set_title("Execution Price vs Liquidation Floor")
    decorate(ax)

    ax = axes[1]
    xs = ratios
    ys = [(index + 1) / len(xs) for index in range(len(xs))]
    ax.plot(xs, ys, color="#0f766e", linewidth=1.5, label="liquidations")
    for label, value, color in (
        ("p50", p50, "#2563eb"),
        ("p95", p95, "#dc2626"),
        ("p99", p99, "#7c3aed"),
    ):
        ax.axvline(value, color=color, linewidth=1.0, linestyle="--", label=f"{label}: {value:.1%}")
    ax.axvline(
        weighted_gap_ratio,
        color="#ea580c",
        linewidth=1.1,
        linestyle="-.",
        label=f"weighted: {weighted_gap_ratio:.1%}",
    )
    ax.set_xlim(0, 1.0)
    ax.set_ylim(0, 1.02)
    ax.xaxis.set_major_formatter(PercentFormatter(xmax=1.0))
    ax.yaxis.set_major_formatter(PercentFormatter(xmax=1.0))
    ax.set_xlabel("bad debt ratio: (floor - execution) / floor")
    ax.set_ylabel("share of liquidations")
    ax.set_title("Bad Debt Ratio Distribution")
    decorate(ax)

    ax = axes[2]
    ax.axhline(0, color="#64748b", linewidth=0.9, linestyle="--", label="break-even")
    ax.plot(net_steps, cumulative_surplus, color="#16a34a", linewidth=1.1, alpha=0.72, label="cumulative surplus")
    ax.plot(net_steps, cumulative_bad_debt, color="#dc2626", linewidth=1.1, alpha=0.72, label="cumulative bad debt")
    ax.plot(net_steps, cumulative_net, color="#2563eb", linewidth=1.5, label="net surplus: surplus - bad debt")
    ax.set_ylabel("DUSDC")
    ax.set_xlabel(net_label)
    ax.set_title("Net Liquidation Surplus Over Time")
    decorate(ax)

    fig.tight_layout(rect=(0, 0, 1, 0.94))
    fig.savefig(out_path, dpi=150)
    plt.close(fig)
    print(f"  Saved {out_path}")


def main() -> None:
    if len(sys.argv) != 2:
        print("Usage: python3 chart_liquidation_execution_quality.py <path-to-python-data.json>")
        raise SystemExit(1)

    path = Path(sys.argv[1])
    chart_execution_quality(
        liquidation_events(load_records(path, PREDICT_ECONOMIC_SCHEMA_VERSION)),
        path.parent / "chart_liquidation_execution_quality.png",
    )


if __name__ == "__main__":
    main()
