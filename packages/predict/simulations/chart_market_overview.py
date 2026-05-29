#!/usr/bin/env python3
"""Render the foundational market overview chart for a Python long run."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

import matplotlib

matplotlib.use("Agg")

import matplotlib.pyplot as plt


DUSDC_SCALING = 1_000_000
FLOAT_SCALING = 1_000_000_000
POS_INF_STRIKE = 18_446_744_073_709_551_615


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as infile:
        data = json.load(infile)
    if not isinstance(data, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return data


def int_or_none(value: Any) -> int | None:
    if value is None:
        return None
    return int(value)


def int_or_zero(value: Any) -> int:
    if value is None:
        return 0
    return int(value)


def to_price(value: int | None) -> float | None:
    if value is None:
        return None
    return value / FLOAT_SCALING


def records_from_payload(payload: dict[str, Any], path: Path) -> list[dict[str, Any]]:
    records = payload.get("records")
    if not isinstance(records, list):
        raise ValueError(f"{path} is missing records[]")
    return records


def timeline_mode(
    economic_records: list[dict[str, Any]], derived_records: list[dict[str, Any]]
) -> tuple[str, int, str]:
    for records in (economic_records, derived_records):
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


def finite_order_strike(update: dict[str, Any]) -> int | None:
    lower = int_or_none(update.get("lower_strike"))
    higher = int_or_none(update.get("higher_strike"))
    if lower is not None and lower != 0 and lower != POS_INF_STRIKE:
        return lower
    if higher is not None and higher != POS_INF_STRIKE:
        return higher
    return None


def extract_market_activity(
    economic_records: list[dict[str, Any]], mode: str, origin: int
) -> tuple[list[tuple[float, float]], list[dict[str, Any]]]:
    prices: list[tuple[float, float]] = []
    events: list[dict[str, Any]] = []
    orders: dict[str, dict[str, int]] = {}

    for record in economic_records:
        x = record_x(record, mode, origin)
        for update in record.get("updates", []):
            update_type = update.get("type")
            if update_type == "oracle_prices_updated":
                spot = to_price(int(update["spot"]))
                if spot is not None:
                    prices.append((x, spot))
                continue

            if update_type == "order_minted":
                order_ref = update.get("order_ref")
                strike = finite_order_strike(update)
                quantity = int_or_none(update.get("quantity"))
                if order_ref is None or strike is None or quantity is None:
                    continue
                orders[str(order_ref)] = {"strike": strike, "quantity": quantity}
                events.append(
                    {
                        "kind": "mint",
                        "x": x,
                        "strike": strike,
                        "quantity": quantity,
                    }
                )
                continue

            if update_type == "live_order_redeemed":
                order_ref = update.get("order_ref")
                if order_ref is None:
                    continue
                order_key = str(order_ref)
                meta = orders.get(order_key)
                closed = int_or_zero(update.get("quantity_closed"))
                if meta is not None and closed > 0:
                    events.append(
                        {
                            "kind": "redeem",
                            "x": x,
                            "strike": meta["strike"],
                            "quantity": closed,
                        }
                    )

                remaining = int_or_zero(update.get("remaining_quantity"))
                replacement_ref = update.get("replacement_order_ref")
                orders.pop(order_key, None)
                if meta is not None and remaining > 0 and replacement_ref is not None:
                    orders[str(replacement_ref)] = {
                        "strike": meta["strike"],
                        "quantity": remaining,
                    }
                continue

            if update_type == "order_liquidated":
                order_ref = update.get("order_ref")
                if order_ref is None:
                    continue
                orders.pop(str(order_ref), None)

    return prices, events


def extract_value_series(
    derived_records: list[dict[str, Any]], mode: str, origin: int
) -> dict[str, list[float]]:
    series: dict[str, list[float]] = {
        "lp_pnl_x": [],
        "lp_live_mtm_pnl": [],
        "active_book_x": [],
        "active_book_pnl": [],
        "scale_x": [],
        "active_open_contribution": [],
        "liability_x": [],
        "position_liability": [],
    }

    for record in derived_records:
        x = record_x(record, mode, origin)
        valuation = record.get("valuation", {})

        lp_live_mtm_pnl = int_or_none(valuation.get("lp_live_mtm_pnl"))
        if lp_live_mtm_pnl is not None:
            series["lp_pnl_x"].append(x)
            series["lp_live_mtm_pnl"].append(lp_live_mtm_pnl / DUSDC_SCALING)

        active_book_pnl = int_or_none(valuation.get("active_book_live_pnl"))
        if active_book_pnl is not None:
            series["active_book_x"].append(x)
            series["active_book_pnl"].append(active_book_pnl / DUSDC_SCALING)

        liability = int_or_none(valuation.get("position_liability"))
        if liability is not None:
            series["liability_x"].append(x)
            series["position_liability"].append(liability / DUSDC_SCALING)

        active_open = int_or_none(valuation.get("active_open_contribution"))
        if active_open is not None:
            series["scale_x"].append(x)
            series["active_open_contribution"].append(active_open / DUSDC_SCALING)

    return series


def configure_axis(ax: plt.Axes, *, grid_axis: str = "y") -> None:
    ax.grid(True, axis=grid_axis, color="#d7dde5", linewidth=0.8, alpha=0.7)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)


def plot_activity_panel(
    ax_price: plt.Axes,
    prices: list[tuple[float, float]],
    events: list[dict[str, Any]],
) -> None:
    if prices:
        x_values, spot_values = zip(*prices)
        ax_price.plot(
            x_values,
            spot_values,
            color="#1f2937",
            linewidth=1.7,
            label="BTC spot",
        )

    mint_events = [event for event in events if event["kind"] == "mint"]
    redeem_events = [event for event in events if event["kind"] == "redeem"]
    if mint_events:
        ax_price.scatter(
            [float(event["x"]) for event in mint_events],
            [float(event["strike"]) / FLOAT_SCALING for event in mint_events],
            s=10,
            color="#1f9d55",
            alpha=0.32,
            linewidths=0,
            label="mint strike",
        )
    if redeem_events:
        ax_price.scatter(
            [float(event["x"]) for event in redeem_events],
            [float(event["strike"]) / FLOAT_SCALING for event in redeem_events],
            s=14,
            color="#c2410c",
            alpha=0.4,
            marker="x",
            linewidths=0.7,
            label="redeem strike",
        )

    ax_price.set_title(
        "BTC Price and Mint/Redeem Strikes\n"
        "Dots are plotted at order strike to show strike dispersion over the source window.",
        loc="left",
        fontsize=11,
    )
    ax_price.set_ylabel("BTC / strike")
    configure_axis(ax_price)
    ax_price.legend(loc="upper left", ncols=3, fontsize=8, frameon=False)


def plot_overall_pnl_panel(ax: plt.Axes, series: dict[str, list[float]]) -> None:
    ax.plot(
        series["lp_pnl_x"],
        series["lp_live_mtm_pnl"],
        color="#2563eb",
        linewidth=1.8,
        label="LP live MTM PnL",
    )
    ax.axhline(0, color="#64748b", linewidth=0.8)
    ax.set_title(
        "Overall Vault PnL\n"
        "LP live MTM PnL includes realized cash movements, fee surplus, and current live liability.",
        loc="left",
        fontsize=11,
    )
    ax.set_ylabel("DUSDC")
    configure_axis(ax)
    ax.legend(loc="upper left", fontsize=8, frameon=False)


def plot_scale_panel(ax: plt.Axes, series: dict[str, list[float]]) -> None:
    ax.plot(
        series["scale_x"],
        series["active_open_contribution"],
        color="#0891b2",
        linewidth=1.5,
        label="active open contribution",
    )
    ax.plot(
        series["liability_x"],
        series["position_liability"],
        color="#be123c",
        linewidth=1.5,
        label="position liability",
    )
    ax.plot(
        series["active_book_x"],
        series["active_book_pnl"],
        color="#059669",
        linewidth=1.7,
        label="active book PnL",
    )
    ax.axhline(0, color="#64748b", linewidth=0.8)
    ax.set_title(
        "Live Book Risk\n"
        "Open contribution, live liability, and net open-book PnL share one DUSDC axis.",
        loc="left",
        fontsize=11,
    )
    ax.set_ylabel("DUSDC")
    configure_axis(ax)
    ax.legend(loc="upper left", ncols=3, fontsize=8, frameon=False)


def render(
    economic_path: Path,
    derived_path: Path,
    output_path: Path,
) -> None:
    economic_payload = load_json(economic_path)
    derived_payload = load_json(derived_path)
    economic_records = records_from_payload(economic_payload, economic_path)
    derived_records = records_from_payload(derived_payload, derived_path)
    if not economic_records:
        raise ValueError(f"{economic_path} has no records")
    if not derived_records:
        raise ValueError(f"{derived_path} has no records")

    mode, origin, x_label = timeline_mode(economic_records, derived_records)
    prices, events = extract_market_activity(economic_records, mode, origin)
    series = extract_value_series(derived_records, mode, origin)

    fig = plt.figure(figsize=(13, 11), constrained_layout=False)
    grid = fig.add_gridspec(
        3,
        1,
        height_ratios=[2.0, 2.0, 2.0],
        hspace=0.34,
        top=0.88,
    )
    ax_price = fig.add_subplot(grid[0])
    ax_value = fig.add_subplot(grid[1], sharex=ax_price)
    ax_scale = fig.add_subplot(grid[2], sharex=ax_price)

    fig.suptitle("Market Overview", fontsize=16, fontweight="bold", x=0.075, ha="left")
    fig.text(
        0.075,
        0.93,
        "Shows BTC context, overall vault live MTM PnL, and live open-book risk "
        "over the source window.",
        fontsize=10,
        color="#475569",
        ha="left",
    )

    plot_activity_panel(ax_price, prices, events)
    plot_overall_pnl_panel(ax_value, series)
    plot_scale_panel(ax_scale, series)

    ax_price.tick_params(labelbottom=False)
    ax_value.tick_params(labelbottom=False)
    ax_scale.set_xlabel(x_label)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(output_path, dpi=180, bbox_inches="tight")
    plt.close(fig)


def main() -> None:
    if len(sys.argv) != 3:
        print(
            "usage: chart_market_overview.py <python_long_data.json> "
            "<python_derived.json>",
            file=sys.stderr,
        )
        raise SystemExit(2)

    economic_path = Path(sys.argv[1])
    derived_path = Path(sys.argv[2])
    output_path = economic_path.with_name("chart_market_overview.png")
    render(economic_path, derived_path, output_path)
    print(f"wrote {output_path}")


if __name__ == "__main__":
    main()
