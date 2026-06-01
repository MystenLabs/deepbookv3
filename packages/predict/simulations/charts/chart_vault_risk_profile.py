#!/usr/bin/env python3
"""Render vault risk-normalized economics for a Python long run."""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

from chart_common import PercentFormatter, configure_axis, plt, record_x, timeline_mode
from sim_artifacts import (
    FLOAT_SCALING,
    PREDICT_DERIVED_SCHEMA_VERSION,
    int_or_none,
    int_or_zero,
    load_records,
)


def pct_from_scaled(value: int) -> float:
    return value * 100 / FLOAT_SCALING


def scaled_ratio(numerator: int, denominator: int) -> int | None:
    if denominator <= 0:
        return None
    sign = -1 if numerator < 0 else 1
    return sign * (abs(numerator) * FLOAT_SCALING // denominator)


def append_scaled(series: dict[str, list[float]], x_key: str, y_key: str, x: float, value: Any) -> None:
    parsed = int_or_none(value)
    if parsed is None:
        return
    series[x_key].append(x)
    series[y_key].append(pct_from_scaled(parsed))


def extract_series(records: list[dict[str, Any]], mode: str, origin: int) -> dict[str, list[float]]:
    series: dict[str, list[float]] = {
        "capital_x": [],
        "liability_over_funding": [],
        "contribution_x": [],
        "contribution_over_funding": [],
        "pnl_x": [],
        "lp_pnl_over_funding": [],
        "book_pnl_x": [],
        "book_pnl_over_funding": [],
        "comp_x": [],
        "cumulative_trading_fee_over_funding": [],
        "cumulative_liquidation_gap_over_funding": [],
        "cumulative_net_liquidation_over_funding": [],
        "backlog_x": [],
        "backlog_over_allocated": [],
    }
    cumulative_trading_fee = 0
    cumulative_liquidation_gap = 0
    cumulative_liquidation_surplus = 0

    for record in records:
        x = record_x(record, mode, origin)
        flows = record.get("flows", {})
        risk = record.get("risk", {})
        cumulative_trading_fee += int_or_zero(flows.get("trading_fee"))
        cumulative_liquidation_gap += int_or_zero(flows.get("liquidation_gap"))
        cumulative_liquidation_surplus += int_or_zero(flows.get("liquidation_surplus"))

        append_scaled(
            series,
            "capital_x",
            "liability_over_funding",
            x,
            risk.get("position_liability_over_funding"),
        )
        append_scaled(
            series,
            "contribution_x",
            "contribution_over_funding",
            x,
            risk.get("active_open_contribution_over_funding"),
        )
        append_scaled(
            series,
            "pnl_x",
            "lp_pnl_over_funding",
            x,
            risk.get("lp_live_mtm_pnl_over_funding"),
        )
        append_scaled(
            series,
            "book_pnl_x",
            "book_pnl_over_funding",
            x,
            active_book_pnl_over_funding(record),
        )
        append_scaled(
            series,
            "backlog_x",
            "backlog_over_allocated",
            x,
            risk.get("liquidatable_value_over_allocated"),
        )

        funding = int_or_none(risk.get("expiry_funding_basis"))
        if funding is None or funding <= 0:
            continue
        trading_ratio = scaled_ratio(cumulative_trading_fee, funding)
        gap_ratio = scaled_ratio(cumulative_liquidation_gap, funding)
        net_liquidation_ratio = scaled_ratio(
            cumulative_liquidation_surplus - cumulative_liquidation_gap,
            funding,
        )
        if trading_ratio is None or gap_ratio is None or net_liquidation_ratio is None:
            continue
        series["comp_x"].append(x)
        series["cumulative_trading_fee_over_funding"].append(pct_from_scaled(trading_ratio))
        series["cumulative_liquidation_gap_over_funding"].append(pct_from_scaled(gap_ratio))
        series["cumulative_net_liquidation_over_funding"].append(pct_from_scaled(net_liquidation_ratio))

    return series


def active_book_pnl_over_funding(record: dict[str, Any]) -> int | None:
    risk = record.get("risk", {})
    existing = int_or_none(risk.get("active_book_live_pnl_over_funding"))
    if existing is not None:
        return existing
    funding = int_or_none(risk.get("expiry_funding_basis"))
    active_book_pnl = int_or_none(record.get("valuation", {}).get("active_book_live_pnl"))
    if funding is None or active_book_pnl is None:
        return None
    return scaled_ratio(active_book_pnl, funding)


def use_percent_axis(ax: plt.Axes) -> None:
    ax.yaxis.set_major_formatter(PercentFormatter(xmax=100))
    configure_axis(ax)


def plot_capital_panel(ax: plt.Axes, series: dict[str, list[float]]) -> None:
    ax.plot(
        series["capital_x"],
        series["liability_over_funding"],
        color="#2563eb",
        linewidth=1.6,
        label="position liability / expiry funding",
    )
    ax.plot(
        series["contribution_x"],
        series["contribution_over_funding"],
        color="#0891b2",
        linewidth=1.4,
        label="open contribution / expiry funding",
    )
    ax.set_title(
        "Capital Utilization\n"
        "Shows how much expiry funding is represented by current live liability and trader contribution.",
        loc="left",
        fontsize=11,
    )
    ax.set_ylabel("share of funding")
    use_percent_axis(ax)
    ax.legend(loc="upper left", ncols=2, fontsize=8, frameon=False)


def plot_return_panel(ax: plt.Axes, series: dict[str, list[float]]) -> None:
    ax.plot(
        series["pnl_x"],
        series["lp_pnl_over_funding"],
        color="#9333ea",
        linewidth=1.7,
        label="LP MTM PnL / expiry funding",
    )
    ax.plot(
        series["book_pnl_x"],
        series["book_pnl_over_funding"],
        color="#059669",
        linewidth=1.4,
        label="active book PnL / expiry funding",
    )
    ax.axhline(0, color="#64748b", linewidth=0.8)
    ax.set_title(
        "Risk-Normalized Return\n"
        "Compares live vault PnL and open-book PnL against the same expiry-funding denominator.",
        loc="left",
        fontsize=11,
    )
    ax.set_ylabel("return")
    use_percent_axis(ax)
    ax.legend(loc="upper left", ncols=2, fontsize=8, frameon=False)


def plot_compensation_panel(ax: plt.Axes, series: dict[str, list[float]]) -> None:
    ax.plot(
        series["comp_x"],
        series["cumulative_trading_fee_over_funding"],
        color="#2563eb",
        linewidth=1.4,
        label="cumulative trading fees / funding",
    )
    ax.plot(
        series["comp_x"],
        series["cumulative_liquidation_gap_over_funding"],
        color="#dc2626",
        linewidth=1.4,
        label="cumulative bad debt / funding",
    )
    ax.plot(
        series["comp_x"],
        series["cumulative_net_liquidation_over_funding"],
        color="#059669",
        linewidth=1.6,
        label="cumulative net liquidation / funding",
    )
    ax.axhline(0, color="#64748b", linewidth=0.8)
    ax.set_title(
        "Fees And Liquidation Results On Capital\n"
        "Normalizes cumulative trading fees, bad debt, and net liquidation surplus against expiry funding.",
        loc="left",
        fontsize=11,
    )
    ax.set_ylabel("share of funding")
    use_percent_axis(ax)
    ax.legend(loc="upper left", ncols=3, fontsize=8, frameon=False)


def plot_backlog_panel(ax: plt.Axes, series: dict[str, list[float]]) -> None:
    ax.plot(
        series["backlog_x"],
        series["backlog_over_allocated"],
        color="#be123c",
        linewidth=1.5,
        label="liquidatable value / allocated capital",
    )
    ax.set_title(
        "Liquidatable Backlog On Capital\n"
        "Shows standing liquidatable floor value as a share of allocated counterparty capital.",
        loc="left",
        fontsize=11,
    )
    ax.set_ylabel("share of allocation")
    use_percent_axis(ax)
    ax.legend(loc="upper left", fontsize=8, frameon=False)


def render(derived_path: Path, output_path: Path) -> None:
    records = load_records(derived_path, PREDICT_DERIVED_SCHEMA_VERSION)
    if not records:
        raise ValueError(f"{derived_path} has no records")

    mode, origin, x_label = timeline_mode(records)
    series = extract_series(records, mode, origin)

    fig = plt.figure(figsize=(13, 12), constrained_layout=False)
    grid = fig.add_gridspec(
        4,
        1,
        height_ratios=[1.7, 1.8, 1.8, 1.6],
        hspace=0.38,
        top=0.88,
    )
    ax_capital = fig.add_subplot(grid[0])
    ax_return = fig.add_subplot(grid[1], sharex=ax_capital)
    ax_compensation = fig.add_subplot(grid[2], sharex=ax_capital)
    ax_backlog = fig.add_subplot(grid[3], sharex=ax_capital)

    fig.suptitle("Vault Risk Profile", fontsize=16, fontweight="bold", x=0.075, ha="left")
    fig.text(
        0.075,
        0.93,
        "Shows whether PnL, fees, liquidation losses, and backlog are acceptable relative to capital at risk.",
        fontsize=10,
        color="#475569",
        ha="left",
    )

    plot_capital_panel(ax_capital, series)
    plot_return_panel(ax_return, series)
    plot_compensation_panel(ax_compensation, series)
    plot_backlog_panel(ax_backlog, series)

    ax_capital.tick_params(labelbottom=False)
    ax_return.tick_params(labelbottom=False)
    ax_compensation.tick_params(labelbottom=False)
    ax_backlog.set_xlabel(x_label)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(output_path, dpi=180, bbox_inches="tight")
    plt.close(fig)


def main() -> None:
    if len(sys.argv) != 2:
        print(
            "usage: chart_vault_risk_profile.py <python_derived.json>",
            file=sys.stderr,
        )
        raise SystemExit(2)

    derived_path = Path(sys.argv[1])
    output_path = derived_path.with_name("chart_vault_risk_profile.png")
    render(derived_path, output_path)
    print(f"wrote {output_path}")


if __name__ == "__main__":
    main()
