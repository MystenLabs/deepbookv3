#!/usr/bin/env python3
"""Render vault PnL and fee coverage charts for a Python long run."""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

from chart_common import configure_axis, plt, record_x, timeline_mode
from sim_artifacts import (
    PREDICT_DERIVED_SCHEMA_VERSION,
    dusdc,
    int_or_none,
    int_or_zero,
    load_records,
)


def extract_series(records: list[dict[str, Any]], mode: str, origin: int) -> dict[str, list[float]]:
    series: dict[str, list[float]] = {
        "x": [],
        "trading_fee": [],
        "net_liquidation": [],
        "net_compensation": [],
        "borrow_x": [],
        "borrow_fee": [],
    }
    cumulative_trading_fee = 0
    cumulative_liquidation_surplus = 0
    cumulative_liquidation_gap = 0
    last_borrow_fee = 0

    for record in records:
        x = record_x(record, mode, origin)
        flows = record.get("flows", {})

        cumulative_trading_fee += int_or_zero(flows.get("trading_fee"))
        cumulative_liquidation_surplus += int_or_zero(flows.get("liquidation_surplus"))
        cumulative_liquidation_gap += int_or_zero(flows.get("liquidation_gap"))
        net_liquidation = cumulative_liquidation_surplus - cumulative_liquidation_gap

        series["x"].append(x)
        series["trading_fee"].append(dusdc(cumulative_trading_fee))
        series["net_liquidation"].append(dusdc(net_liquidation))

        borrow_fee = int_or_none(flows.get("borrow_fee_accrued"))
        if borrow_fee is not None:
            last_borrow_fee = borrow_fee
            series["borrow_x"].append(x)
            series["borrow_fee"].append(dusdc(borrow_fee))

        net_compensation = cumulative_trading_fee + last_borrow_fee + net_liquidation
        series["net_compensation"].append(dusdc(net_compensation))

    return series


def plot_components_panel(ax: plt.Axes, series: dict[str, list[float]]) -> None:
    ax.plot(
        series["x"],
        series["trading_fee"],
        color="#2563eb",
        linewidth=1.5,
        label="cumulative trading fees",
    )
    ax.plot(
        series["borrow_x"],
        series["borrow_fee"],
        color="#7c3aed",
        linewidth=1.5,
        label="borrow fees accrued",
    )
    ax.plot(
        series["x"],
        series["net_liquidation"],
        color="#059669",
        linewidth=1.5,
        label="cumulative net liquidation",
    )
    ax.axhline(0, color="#64748b", linewidth=0.8)
    ax.set_title(
        "Fee And Liquidation Components\n"
        "Cumulative fees, open borrow accrual, and net liquidation show live pre-terminal risk compensation.",
        loc="left",
        fontsize=11,
    )
    ax.set_ylabel("DUSDC")
    configure_axis(ax)
    ax.legend(loc="upper left", ncols=3, fontsize=8, frameon=False)


def plot_net_compensation_panel(ax: plt.Axes, series: dict[str, list[float]]) -> None:
    ax.plot(
        series["x"],
        series["net_compensation"],
        color="#9333ea",
        linewidth=1.8,
        label="net risk compensation mark",
    )
    ax.axhline(0, color="#64748b", linewidth=0.8)
    ax.set_title(
        "Net Risk Compensation Mark\n"
        "Trading fees plus open borrow accrual plus net liquidation shows a live MTM compensation view.",
        loc="left",
        fontsize=11,
    )
    ax.set_ylabel("DUSDC")
    configure_axis(ax)
    ax.legend(loc="upper left", fontsize=8, frameon=False)


def render(derived_path: Path, output_path: Path) -> None:
    records = load_records(derived_path, PREDICT_DERIVED_SCHEMA_VERSION)
    if not records:
        raise ValueError(f"{derived_path} has no records")

    mode, origin, x_label = timeline_mode(records)
    series = extract_series(records, mode, origin)

    fig = plt.figure(figsize=(13, 8), constrained_layout=False)
    grid = fig.add_gridspec(
        2,
        1,
        height_ratios=[2.0, 2.0],
        hspace=0.34,
        top=0.88,
    )
    ax_components = fig.add_subplot(grid[0])
    ax_compensation = fig.add_subplot(grid[1], sharex=ax_components)

    fig.suptitle("Vault PnL And Fee Coverage", fontsize=16, fontweight="bold", x=0.075, ha="left")
    fig.text(
        0.075,
        0.93,
        "Shows fee/risk components and MTM compensation after "
        "liquidation surplus or bad debt before terminal closeout.",
        fontsize=10,
        color="#475569",
        ha="left",
    )

    plot_components_panel(ax_components, series)
    plot_net_compensation_panel(ax_compensation, series)

    ax_components.tick_params(labelbottom=False)
    ax_compensation.set_xlabel(x_label)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(output_path, dpi=180, bbox_inches="tight")
    plt.close(fig)


def main() -> None:
    if len(sys.argv) != 2:
        print(
            "usage: chart_vault_pnl_fee_coverage.py <python_derived.json>",
            file=sys.stderr,
        )
        raise SystemExit(2)

    derived_path = Path(sys.argv[1])
    output_path = derived_path.with_name("chart_vault_pnl_fee_coverage.png")
    render(derived_path, output_path)
    print(f"wrote {output_path}")


if __name__ == "__main__":
    main()
