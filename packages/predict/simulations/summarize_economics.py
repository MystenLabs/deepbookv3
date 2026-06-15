#!/usr/bin/env python3
"""Write a compact economic summary for a Predict simulation run."""

from __future__ import annotations

import statistics
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

from sim_artifacts import (
    dusdc,
    int_or_none,
    load_optional_json as load_json,
    normalized_action,
    percentile,
    ratio,
    sui,
    write_json,
)

SCHEMA_VERSION = "predict_economic_summary_v3"


def integer_stats(values: list[int]) -> dict[str, int] | None:
    if not values:
        return None
    ordered = sorted(values)
    return {
        "count": len(values),
        "min": ordered[0],
        "p50": percentile(ordered, 0.50),
        "p95": percentile(ordered, 0.95),
        "max": ordered[-1],
        "avg": round(sum(values) / len(values)),
        "final": values[-1],
    }


def dusdc_stats(values: list[int]) -> dict[str, Any] | None:
    raw = integer_stats(values)
    if raw is None:
        return None
    return {
        **{f"{key}_raw": str(value) for key, value in raw.items() if key != "count"},
        "count": raw["count"],
        "min_dusdc": dusdc(raw["min"]),
        "p50_dusdc": dusdc(raw["p50"]),
        "p95_dusdc": dusdc(raw["p95"]),
        "max_dusdc": dusdc(raw["max"]),
        "avg_dusdc": dusdc(raw["avg"]),
        "final_dusdc": dusdc(raw["final"]),
    }


def ratio_stats(values: list[int]) -> dict[str, Any] | None:
    raw = integer_stats(values)
    if raw is None:
        return None
    return {
        **{f"{key}_raw": str(value) for key, value in raw.items() if key != "count"},
        "count": raw["count"],
        "min": ratio(raw["min"]),
        "p50": ratio(raw["p50"]),
        "p95": ratio(raw["p95"]),
        "max": ratio(raw["max"]),
        "avg": ratio(raw["avg"]),
        "final": ratio(raw["final"]),
    }


def counter_dict(values: list[str]) -> dict[str, int]:
    return dict(sorted(Counter(values).items()))


def update_totals(records: list[dict[str, Any]]) -> dict[str, int]:
    totals = defaultdict(int)
    for record in records:
        for update in record["updates"]:
            update_type = update["type"]
            if update_type == "order_minted":
                totals["premium"] += int(update["contribution"])
                totals["trading_fee"] += int(update["trading_fee"])
            elif update_type == "live_order_redeemed":
                totals["redeem_payout"] += int(update["redeem_amount"])
                totals["trading_fee"] += int(update["trading_fee"])
            elif update_type == "settled_order_redeemed":
                totals["redeem_payout"] += int(update["payout_amount"])
            elif update_type == "terminal_closeout":
                settled_payout = int(update["settled_payout_amount"])
                totals["redeem_payout"] += settled_payout
                totals["terminal_settled_payout"] += settled_payout
                totals["terminal_gross_profit_before_rebate"] += int(update["gross_profit_before_rebate"])
                totals["terminal_resolved_rebate_reserve"] += int(update["resolved_rebate_reserve"])
                totals["terminal_eligible_rebate"] += int(update["eligible_rebate"])
                totals["terminal_rebate_amount"] += int(update["rebate_amount"])
                totals["terminal_residual_rebate_reserve"] += int(update["residual_rebate_reserve"])
                totals["terminal_returned_rebate_reserve"] += int(update["returned_rebate_reserve"])
                totals["terminal_returned_pool_cash"] += int(update["returned_pool_cash"])
                totals["terminal_returned_cash"] += int(update["returned_cash"])
                totals["terminal_materialized_profit"] += int(update["materialized_profit"])
                totals["terminal_lp_profit"] += int(update["lp_profit"])
                totals["terminal_protocol_profit"] += int(update["protocol_profit"])
            elif update_type == "order_liquidated":
                floor_value = int(update["floor_amount"])
                gross_value = int(update["gross_value"])
                totals["liquidated_floor_value"] += floor_value
                totals["liquidated_gross_value"] += gross_value
                totals["liquidation_bad_debt"] += max(0, floor_value - gross_value)
                totals["liquidation_surplus"] += max(0, gross_value - floor_value)
            elif update_type == "supply_filled":
                totals["supply_payment"] += int(update["dusdc_amount"])
            elif update_type == "withdraw_filled":
                totals["withdraw_payout"] += int(update["dusdc_amount"])
    totals["liquidation_gap"] = totals["liquidation_bad_debt"]
    return dict(totals)


def totals_with_dusdc(totals: dict[str, int]) -> dict[str, Any]:
    return {
        key: {
            "raw": str(value),
            "dusdc": dusdc(value),
        }
        for key, value in sorted(totals.items())
    }


def summarize_canonical(data: dict[str, Any] | None) -> dict[str, Any] | None:
    if data is None:
        return None
    records = data["records"]
    updates = [update for record in records for update in record["updates"]]
    terminal_updates = [update for update in updates if update["type"] == "terminal_closeout"]
    return {
        "records": len(records),
        "action_counts": counter_dict([record["action"] for record in records]),
        "update_counts": counter_dict([update["type"] for update in updates]),
        "totals": totals_with_dusdc(update_totals(records)),
        "terminal_closeout": terminal_updates[-1] if terminal_updates else None,
        "final_state": records[-1]["state"] if records else {},
    }


def field_values(records: list[dict[str, Any]], path: tuple[str, ...]) -> list[int]:
    values: list[int] = []
    for record in records:
        value: Any = record
        for field in path:
            if not isinstance(value, dict) or field not in value:
                value = None
                break
            value = value[field]
        parsed = int_or_none(value)
        if parsed is not None:
            values.append(parsed)
    return values


def cumulative_sum(values: list[int]) -> list[int]:
    out, running = [], 0
    for value in values:
        running += value
        out.append(running)
    return out


def sampled_backlog_area(records: list[dict[str, Any]]) -> int:
    points: list[tuple[int, int]] = []
    for record in records:
        value = record["liquidation"]["liquidatable_value"]
        if value is not None:
            points.append((int(record["step"]), int(value)))
    if len(points) < 2:
        return 0
    area = 0
    prev_step, prev_value = points[0]
    for step, value in points[1:]:
        area += prev_value * max(0, step - prev_step)
        prev_step, prev_value = step, value
    return area


def last_sampled(records: list[dict[str, Any]], path: tuple[str, ...]) -> str | None:
    for record in reversed(records):
        value: Any = record
        for field in path:
            if not isinstance(value, dict) or field not in value:
                value = None
                break
            value = value[field]
        if value is not None:
            return str(value)
    return None


def sample_interval(records: list[dict[str, Any]]) -> int | None:
    sampled_steps = [
        int(record["step"])
        for record in records
        if record["liquidation"].get("sampled")
    ]
    if len(sampled_steps) < 2:
        return None
    return sampled_steps[1] - sampled_steps[0]


def summarize_derived(data: dict[str, Any] | None) -> dict[str, Any] | None:
    if data is None:
        return None
    records = data["records"]
    sampled = [record for record in records if record["liquidation"].get("sampled")]
    premiums = field_values(records, ("flows", "premium"))
    fees = field_values(records, ("flows", "trading_fee"))
    redeem_payouts = field_values(records, ("flows", "redeem_payout"))
    liquidation_gaps = field_values(records, ("flows", "liquidation_gap"))
    liquidation_surplus = field_values(records, ("flows", "liquidation_surplus"))
    total_fees = sum(fees)
    total_liquidation_gap = sum(liquidation_gaps)

    liquidated_by_action = defaultdict(int)
    liquidated_value_by_action = defaultdict(int)
    txs_with_liquidations_by_action = Counter()
    for record in records:
        action = normalized_action(record["action"])
        liquidated_count = int(record["liquidation"]["liquidated_count"])
        liquidated_value = int(record["liquidation"]["liquidated_value"])
        if liquidated_count > 0:
            txs_with_liquidations_by_action[action] += 1
            liquidated_by_action[action] += liquidated_count
            liquidated_value_by_action[action] += liquidated_value

    last_live_lp_pnl = last_sampled(records, ("valuation", "lp_live_mtm_pnl"))
    last_live_active_pnl = last_sampled(records, ("valuation", "active_book_live_pnl"))
    last_live_liability = last_sampled(records, ("valuation", "position_liability"))
    backlog_area = sampled_backlog_area(records)

    return {
        "records": len(records),
        "sampled_records": len(sampled),
        "sample_interval_txs": sample_interval(records),
        "totals": totals_with_dusdc(
            {
                "premium": sum(premiums),
                "trading_fee": total_fees,
                "redeem_payout": sum(redeem_payouts),
                "liquidation_gap": total_liquidation_gap,
                "liquidation_surplus": sum(liquidation_surplus),
                "liquidated_floor_value": sum(field_values(records, ("flows", "liquidated_floor_value"))),
                "liquidated_gross_value": sum(field_values(records, ("flows", "liquidated_gross_value"))),
            }
        ),
        "fee_coverage": None
        if total_liquidation_gap <= 0
        else {
            "fees_over_liquidation_gap": total_fees / total_liquidation_gap,
        },
        "pnl": {
            "lp_live_mtm_pnl": dusdc_stats(field_values(records, ("valuation", "lp_live_mtm_pnl"))),
            "active_book_live_pnl": dusdc_stats(field_values(records, ("valuation", "active_book_live_pnl"))),
            "last_sampled_live_lp_mtm_pnl_raw": last_live_lp_pnl,
            "last_sampled_live_lp_mtm_pnl_dusdc": None
            if last_live_lp_pnl is None
            else dusdc(int(last_live_lp_pnl)),
            "last_sampled_live_active_book_pnl_raw": last_live_active_pnl,
            "last_sampled_live_active_book_pnl_dusdc": None
            if last_live_active_pnl is None
            else dusdc(int(last_live_active_pnl)),
            "last_sampled_live_position_liability_raw": last_live_liability,
            "last_sampled_live_position_liability_dusdc": None
            if last_live_liability is None
            else dusdc(int(last_live_liability)),
        },
        "risk": {
            "expiry_funding_basis": dusdc_stats(field_values(records, ("risk", "expiry_funding_basis"))),
            "position_liability_over_funding": ratio_stats(
                field_values(records, ("risk", "position_liability_over_funding"))
            ),
            "active_open_contribution_over_funding": ratio_stats(
                field_values(records, ("risk", "active_open_contribution_over_funding"))
            ),
            "lp_live_mtm_pnl_over_funding": ratio_stats(
                field_values(records, ("risk", "lp_live_mtm_pnl_over_funding"))
            ),
            "active_book_live_pnl_over_funding": ratio_stats(
                field_values(records, ("risk", "active_book_live_pnl_over_funding"))
            ),
            "active_book_live_pnl_over_liability": ratio_stats(
                field_values(records, ("risk", "active_book_live_pnl_over_liability"))
            ),
            "liquidatable_value_over_liability": ratio_stats(
                field_values(records, ("risk", "liquidatable_value_over_liability"))
            ),
            "step_trading_fee_over_funding": ratio_stats(
                field_values(records, ("risk", "step_trading_fee_over_funding"))
            ),
            "step_liquidation_gap_over_funding": ratio_stats(
                field_values(records, ("risk", "step_liquidation_gap_over_funding"))
            ),
            "step_net_liquidation_over_funding": ratio_stats(
                field_values(records, ("risk", "step_net_liquidation_over_funding"))
            ),
        },
        "liquidation": {
            "liquidated_count": sum(field_values(records, ("liquidation", "liquidated_count"))),
            "txs_with_liquidations": sum(1 for record in records if int(record["liquidation"]["liquidated_count"]) > 0),
            "liquidated_by_action": dict(sorted(liquidated_by_action.items())),
            "liquidated_value_by_action": totals_with_dusdc(dict(liquidated_value_by_action)),
            "txs_with_liquidations_by_action": dict(sorted(txs_with_liquidations_by_action.items())),
            "standing_backlog_count": integer_stats(field_values(records, ("liquidation", "liquidatable_count"))),
            "standing_backlog_value": dusdc_stats(field_values(records, ("liquidation", "liquidatable_value"))),
            "liquidated_value_per_tx": dusdc_stats(field_values(records, ("liquidation", "liquidated_value"))),
            "interval_liquidated_count": integer_stats(field_values(records, ("liquidation", "interval_liquidated_count"))),
            "interval_liquidated_value": dusdc_stats(field_values(records, ("liquidation", "interval_liquidated_value"))),
            "scan_active_count": integer_stats(field_values(records, ("liquidation", "scan_active_count"))),
            "scan_coverage": ratio_stats(field_values(records, ("liquidation", "scan_coverage"))),
            "backlog_remaining_ratio": ratio_stats(field_values(records, ("liquidation", "backlog_remaining_ratio"))),
            "all_passive_required_manual_topup_share": ratio_stats(
                field_values(records, ("liquidation", "all_passive_required_manual_topup_share"))
            ),
            "mint_redeem_required_manual_topup_share": ratio_stats(
                field_values(records, ("liquidation", "mint_redeem_required_manual_topup_share"))
            ),
            "sampled_backlog_value_area_raw": str(backlog_area),
            "sampled_backlog_value_area_dusdc_txs": dusdc(backlog_area),
        },
    }


def summarize_gas(trace: dict[str, Any] | None) -> dict[str, Any] | None:
    if trace is None:
        return None
    by_action: dict[str, list[int]] = defaultdict(list)
    for step in trace["steps"]:
        action = "mint" if step["action"] == "oracle_mint_ptb" else step["action"]
        by_action[action].append(int(step["gas"]["gasTotal"]))

    result: dict[str, Any] = {}
    for action, values in sorted(by_action.items()):
        ordered = sorted(values)
        result[action] = {
            "count": len(values),
            "min_mist": str(ordered[0]),
            "p50_mist": str(percentile(ordered, 0.50)),
            "p95_mist": str(percentile(ordered, 0.95)),
            "max_mist": str(ordered[-1]),
            "avg_mist": str(round(statistics.mean(values))),
            "min_sui": sui(ordered[0]),
            "p50_sui": sui(percentile(ordered, 0.50)),
            "p95_sui": sui(percentile(ordered, 0.95)),
            "max_sui": sui(ordered[-1]),
            "avg_sui": sui(round(statistics.mean(values))),
        }
    return result


def summarize_artifacts(artifacts_dir: Path) -> dict[str, Any]:
    names = [
        "normal_scenario.csv",
        "local_data.json",
        "python_data.json",
        "python_long_data.json",
        "python_derived.json",
        "local_trace.json",
        "state.json",
        "chart_gas.png",
        "chart_market_overview.png",
        "chart_vault_pnl_fee_coverage.png",
        "chart_vault_risk_profile.png",
        "chart_liquidation_coverage.png",
        "chart_liquidation_execution_quality.png",
    ]
    return {
        name: {"bytes": (artifacts_dir / name).stat().st_size}
        for name in names
        if (artifacts_dir / name).exists()
    }


def build_summary(artifacts_dir: Path) -> dict[str, Any]:
    previous = load_json(artifacts_dir / "economic_summary.json") or {}
    local_data = load_json(artifacts_dir / "local_data.json")
    python_data = load_json(artifacts_dir / "python_data.json")
    python_long_data = load_json(artifacts_dir / "python_long_data.json")
    python_derived = load_json(artifacts_dir / "python_derived.json")
    local_trace = load_json(artifacts_dir / "local_trace.json")
    long_canonical = summarize_canonical(python_long_data)
    derived = summarize_derived(python_derived)

    return {
        "schema_version": SCHEMA_VERSION,
        "artifacts": summarize_artifacts(artifacts_dir),
        "canonical": {
            "local": summarize_canonical(local_data),
            "python": summarize_canonical(python_data),
            "equal": None if local_data is None or python_data is None else local_data == python_data,
        },
        "long_canonical": long_canonical if long_canonical is not None else previous.get("long_canonical"),
        "derived": derived if derived is not None else previous.get("derived"),
        "gas": summarize_gas(local_trace),
    }


def main() -> None:
    if len(sys.argv) != 2:
        print("Usage: python3 summarize_economics.py <artifacts-dir>")
        raise SystemExit(1)

    artifacts_dir = Path(sys.argv[1])
    summary = build_summary(artifacts_dir)
    out_path = artifacts_dir / "economic_summary.json"
    write_json(out_path, summary)
    print(f"  Saved {out_path}")


if __name__ == "__main__":
    main()
