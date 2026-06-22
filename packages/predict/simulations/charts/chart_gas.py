#!/usr/bin/env python3
"""Render gas charts from a localnet trace."""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

from chart_common import FLOW_ACTION_COLORS, FLOW_ACTION_LABELS, configure_axis, plt
from sim_artifacts import load_json_object, normalized_action, sui

TRADE_ACTIONS = ("mint", "redeem")
POOL_ACTIONS = ("supply", "withdraw")
FLUSH_ACTIONS = ("flush",)


def load_trace(path: Path) -> dict[str, Any]:
    data = load_json_object(path)
    if not isinstance(data.get("steps"), list):
        raise ValueError(f"{path} is missing steps[]")
    return data


def gas_total(step: dict[str, Any]) -> int:
    gas = step.get("gas")
    if not isinstance(gas, dict) or gas.get("gasTotal") is None:
        raise ValueError(f"trace step {step.get('step')} is missing gas.gasTotal")
    return int(gas["gasTotal"])


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


def plot_timeline_panel(
    ax: plt.Axes,
    series: dict[str, list[Any]],
    actions: tuple[str, ...],
    title: str,
) -> None:
    has_points = False
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
        has_points = True
        ax.scatter(
            xs,
            ys,
            s=14,
            alpha=0.72,
            color=FLOW_ACTION_COLORS.get(action, "#64748b"),
            label=FLOW_ACTION_LABELS.get(action, action),
        )

    ax.set_title(
        title,
        loc="left",
        fontsize=11,
    )
    ax.set_ylabel("SUI")
    configure_axis(ax)
    if has_points:
        ax.legend(loc="upper left", ncols=len(actions), fontsize=8, frameon=False)


def render(trace_path: Path, output_path: Path) -> None:
    trace = load_trace(trace_path)
    steps = trace["steps"]
    if not steps:
        raise ValueError(f"{trace_path} has no trace steps")

    series = extract_series(steps)

    fig, axes = plt.subplots(3, 1, figsize=(13, 11), constrained_layout=True)
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
    plot_timeline_panel(
        axes[2],
        series,
        FLUSH_ACTIONS,
        "Flush Gas\nEach point is one runner-synthesized privileged LP drain "
        "(refresh + value_expiry + queue drain).",
    )
    axes[2].set_xlabel("transaction")

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
