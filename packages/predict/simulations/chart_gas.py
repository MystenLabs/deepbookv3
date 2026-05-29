#!/usr/bin/env python3
"""Render gas charts from a localnet trace."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

import matplotlib

matplotlib.use("Agg")

import matplotlib.pyplot as plt


MIST_PER_SUI = 1_000_000_000
ACTION_LABELS = {
    "mint": "mint",
    "redeem": "redeem",
    "supply": "supply",
    "withdraw": "withdraw",
}
ACTION_COLORS = {
    "mint": "#2563eb",
    "redeem": "#7c3aed",
    "supply": "#0891b2",
    "withdraw": "#f97316",
}
TRADE_ACTIONS = ("mint", "redeem")
POOL_ACTIONS = ("supply", "withdraw")


def load_trace(path: Path) -> dict[str, Any]:
    data = json.loads(path.read_text())
    if not isinstance(data, dict):
        raise ValueError(f"{path} must contain a JSON object")
    if not isinstance(data.get("steps"), list):
        raise ValueError(f"{path} is missing steps[]")
    return data


def normalized_action(action: str) -> str:
    return "mint" if action == "oracle_mint_ptb" else action


def gas_total(step: dict[str, Any]) -> int:
    gas = step.get("gas")
    if not isinstance(gas, dict) or gas.get("gasTotal") is None:
        raise ValueError(f"trace step {step.get('step')} is missing gas.gasTotal")
    return int(gas["gasTotal"])


def sui(value: int) -> float:
    return value / MIST_PER_SUI


def extract_series(steps: list[dict[str, Any]]) -> dict[str, list[Any]]:
    series: dict[str, list[Any]] = {
        "step": [],
        "action": [],
        "gas_sui": [],
    }
    for step in steps:
        action = normalized_action(str(step.get("action", "")))
        series["step"].append(float(step.get("step", 0)))
        series["action"].append(action)
        series["gas_sui"].append(sui(gas_total(step)))
    return series


def configure_axis(ax: plt.Axes) -> None:
    ax.grid(True, axis="y", color="#d7dde5", linewidth=0.8, alpha=0.7)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)


def plot_timeline_panel(
    ax: plt.Axes,
    series: dict[str, list[Any]],
    actions: tuple[str, ...],
    title: str,
) -> None:
    for action in actions:
        xs = [
            step
            for step, item_action in zip(series["step"], series["action"])
            if item_action == action
        ]
        ys = [
            gas
            for gas, item_action in zip(series["gas_sui"], series["action"])
            if item_action == action
        ]
        if not xs:
            continue
        ax.scatter(
            xs,
            ys,
            s=14,
            alpha=0.72,
            color=ACTION_COLORS.get(action, "#64748b"),
            label=ACTION_LABELS.get(action, action),
        )

    ax.set_title(
        title,
        loc="left",
        fontsize=11,
    )
    ax.set_ylabel("SUI")
    configure_axis(ax)
    ax.legend(loc="upper left", ncols=len(actions), fontsize=8, frameon=False)


def render(trace_path: Path, output_path: Path) -> None:
    trace = load_trace(trace_path)
    steps = trace["steps"]
    if not steps:
        raise ValueError(f"{trace_path} has no trace steps")

    series = extract_series(steps)

    fig, axes = plt.subplots(2, 1, figsize=(13, 8), constrained_layout=True)
    plot_timeline_panel(
        axes[0],
        series,
        TRADE_ACTIONS,
        "Mint And Redeem Gas\nEach point is one localnet trade transaction.",
    )
    plot_timeline_panel(
        axes[1],
        series,
        POOL_ACTIONS,
        "Supply And Withdraw Gas\nEach point is one localnet pool transaction.",
    )
    axes[1].set_xlabel("transaction")

    fig.suptitle("Predict Localnet Gas", fontsize=14, fontweight="bold")
    fig.savefig(output_path, dpi=180)
    plt.close(fig)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: chart_gas.py <local_trace.json>", file=sys.stderr)
        return 1
    trace_path = Path(sys.argv[1])
    output_path = trace_path.with_name("chart_gas.png")
    render(trace_path, output_path)
    print(f"wrote {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
