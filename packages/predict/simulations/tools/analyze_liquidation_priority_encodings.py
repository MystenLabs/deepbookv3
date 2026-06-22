#!/usr/bin/env python3
"""Compare candidate liquidation priority orderings against replay data."""

from __future__ import annotations

import argparse
import csv
import itertools
import json
import os
import sys
from concurrent.futures import ProcessPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from typing import Any

SIM_DIR = Path(__file__).resolve().parents[1]
if str(SIM_DIR) not in sys.path:
    sys.path.insert(0, str(SIM_DIR))

import python_replay as replay  # noqa: E402
from sim_artifacts import load_json_object, write_json  # noqa: E402


FRONT_SHARES = (0.05, 0.10, 0.25, 0.50)
SCAN_BUDGETS = (24, 48, 96, 192, 500)
LEVERAGE_ONE_X = replay.LEVERAGE_ONE_X


@dataclass(frozen=True)
class LayoutField:
    name: str
    desc: bool


@dataclass(frozen=True)
class LayoutCandidate:
    name: str
    category: str
    fields: tuple[LayoutField, ...]


def scaled_ratio(numerator: int, denominator: int) -> int:
    if denominator <= 0:
        return 0
    return numerator * replay.FLOAT_SCALING // denominator


def field(name: str, desc: bool) -> LayoutField:
    return LayoutField(name, desc)


def field_label(layout_field: LayoutField) -> str:
    return f"{layout_field.name}_{'desc' if layout_field.desc else 'asc'}"


def layout_name(prefix: str, fields: tuple[LayoutField, ...]) -> str:
    return prefix + "__" + "__".join(field_label(layout_field) for layout_field in fields) + "__sequence_asc"


def layout_candidate(
    fields: tuple[LayoutField, ...],
    *,
    category: str = "implementable",
    prefix: str = "layout",
) -> LayoutCandidate:
    return LayoutCandidate(layout_name(prefix, fields), category, fields)


def has_duplicate_field_names(fields: tuple[LayoutField, ...]) -> bool:
    names = [layout_field.name for layout_field in fields]
    return len(names) != len(set(names))


def dedupe_layouts(candidates: list[LayoutCandidate]) -> list[LayoutCandidate]:
    seen: set[tuple[tuple[str, bool], ...]] = set()
    out: list[LayoutCandidate] = []
    for candidate in candidates:
        key = tuple((layout_field.name, layout_field.desc) for layout_field in candidate.fields)
        if key in seen:
            continue
        seen.add(key)
        out.append(candidate)
    return out


def current_order_id_fields() -> tuple[LayoutField, ...]:
    return (
        field("quantity_lots", True),
        field("floor_shares", True),
        field("opened_at_ms", False),
        field("lower_boundary_index", False),
        field("higher_boundary_index", False),
    )


def curated_layout_candidates() -> list[LayoutCandidate]:
    leverage_desc = field("leverage", True)
    quantity_desc = field("quantity_lots", True)
    floor_prob_desc = field("floor_seed_probability", True)
    floor_prob_asc = field("floor_seed_probability", False)
    floor_lots_desc = field("floor_lots", True)
    floor_lots_asc = field("floor_lots", False)
    entry_desc = field("entry_probability", True)
    entry_asc = field("entry_probability", False)
    floor_ratio_desc = field("floor_ratio", True)
    floor_ratio_asc = field("floor_ratio", False)
    headroom_asc = field("ltv_headroom_probability", False)
    headroom_desc = field("ltv_headroom_probability", True)
    terminal_headroom_asc = field("terminal_ltv_headroom_probability", False)
    terminal_headroom_desc = field("terminal_ltv_headroom_probability", True)
    opened_asc = field("opened_at_ms", False)
    opened_desc = field("opened_at_ms", True)
    width_asc = field("range_width_ticks", False)
    width_desc = field("range_width_ticks", True)
    risk_desc = field("risk_value_score", True)

    prefixes = [
        (quantity_desc, leverage_desc),
        (leverage_desc, quantity_desc),
        (leverage_desc, floor_prob_desc),
        (leverage_desc, floor_prob_asc),
        (leverage_desc, floor_lots_desc),
        (leverage_desc, floor_lots_asc),
        (leverage_desc, entry_desc),
        (leverage_desc, entry_asc),
        (leverage_desc, headroom_asc),
        (floor_prob_desc, leverage_desc),
        (floor_prob_asc, leverage_desc),
        (floor_lots_desc, leverage_desc),
        (entry_desc, leverage_desc),
        (entry_asc, leverage_desc),
        (headroom_asc, leverage_desc),
    ]
    suffixes = [
        quantity_desc,
        floor_prob_desc,
        floor_prob_asc,
        floor_lots_desc,
        floor_lots_asc,
        entry_desc,
        entry_asc,
        floor_ratio_desc,
        floor_ratio_asc,
        headroom_asc,
        headroom_desc,
        terminal_headroom_asc,
        terminal_headroom_desc,
        opened_asc,
        opened_desc,
        width_asc,
        width_desc,
        risk_desc,
    ]

    candidates = [
        layout_candidate(current_order_id_fields(), prefix="current"),
        layout_candidate((leverage_desc, quantity_desc), prefix="previous_primary"),
        layout_candidate((floor_prob_desc, quantity_desc), prefix="floor_first"),
        layout_candidate((floor_prob_asc, quantity_desc), prefix="floor_first"),
        layout_candidate((entry_desc, quantity_desc), prefix="entry_first"),
        layout_candidate((entry_asc, quantity_desc), prefix="entry_first"),
        layout_candidate((headroom_asc, quantity_desc), prefix="headroom_first"),
        layout_candidate((headroom_desc, quantity_desc), prefix="headroom_first"),
    ]

    for prefix_fields in prefixes:
        candidates.append(layout_candidate(prefix_fields))
        for suffix in suffixes:
            fields = (*prefix_fields, suffix)
            if has_duplicate_field_names(fields):
                continue
            candidates.append(layout_candidate(fields))

    benchmark_fields = (
        field("live_liquidatable_value", True),
        field("live_bad_debt", True),
        field("live_surplus", False),
    )
    for benchmark in benchmark_fields:
        candidates.append(
            layout_candidate(
                (benchmark, leverage_desc, quantity_desc),
                category="oracle_benchmark",
                prefix="benchmark",
            )
        )

    return dedupe_layouts(candidates)


def wide_layout_candidates(width: int, limit: int | None) -> list[LayoutCandidate]:
    if width < 1:
        raise ValueError("layout width must be positive")
    directed_fields = [
        field("leverage", True),
        field("leverage", False),
        field("quantity_lots", True),
        field("quantity_lots", False),
        field("floor_seed_probability", True),
        field("floor_seed_probability", False),
        field("floor_lots", True),
        field("floor_lots", False),
        field("entry_probability", True),
        field("entry_probability", False),
        field("floor_ratio", True),
        field("floor_ratio", False),
        field("ltv_headroom_probability", True),
        field("ltv_headroom_probability", False),
        field("terminal_ltv_headroom_probability", True),
        field("terminal_ltv_headroom_probability", False),
        field("opened_at_ms", True),
        field("opened_at_ms", False),
        field("range_width_ticks", True),
        field("range_width_ticks", False),
    ]
    candidates: list[LayoutCandidate] = []
    for fields in itertools.permutations(directed_fields, width):
        if has_duplicate_field_names(fields):
            continue
        candidates.append(layout_candidate(fields, prefix=f"wide{width}"))
        if limit is not None and len(candidates) >= limit:
            break
    return dedupe_layouts(candidates)


def signed_svi_field(value: str) -> tuple[int, bool]:
    parsed = int(value)
    return abs(parsed), parsed < 0


def svi_from_update(update: dict[str, str]) -> dict[str, Any]:
    rho, rho_negative = signed_svi_field(update["rho"])
    m, m_negative = signed_svi_field(update["m"])
    return {
        "a": int(update["a"]),
        "b": int(update["b"]),
        "rho": rho,
        "rhoNegative": rho_negative,
        "m": m,
        "mNegative": m_negative,
        "sigma": int(update["sigma"]),
    }


def enrich_order(order: dict[str, int]) -> dict[str, int]:
    quantity_lots_value = order["quantity"] // replay.POSITION_LOT_SIZE
    floor_seed_probability_value = order["entry_probability"] - replay.user_contribution_from_exposure_value(
        order["entry_probability"],
        order["leverage"],
    )
    threshold_probability = replay.liquidation_threshold_value(floor_seed_probability_value)
    floor_probability_shares = replay.order_floor_shares_from_seed(
        floor_seed_probability_value,
        order["leverage"],
        order["open_floor_index"],
    )
    terminal_floor_probability = replay.floor_amount_for_index(
        floor_probability_shares,
        replay.TERMINAL_FLOOR_INDEX,
    )
    terminal_threshold_probability = replay.liquidation_threshold_value(terminal_floor_probability)
    ltv_headroom_value = max(0, order["entry_probability"] - threshold_probability)
    order["quantity_lots"] = quantity_lots_value
    order["user_contribution_probability"] = order["entry_probability"] - floor_seed_probability_value
    order["floor_seed_probability"] = floor_seed_probability_value
    order["liquidation_threshold_probability"] = threshold_probability
    order["ltv_headroom_probability"] = ltv_headroom_value
    order["ltv_headroom_ratio"] = scaled_ratio(ltv_headroom_value, order["entry_probability"])
    order["floor_ratio"] = scaled_ratio(floor_seed_probability_value, order["entry_probability"])
    order["terminal_ltv_headroom_probability"] = max(0, order["entry_probability"] - terminal_threshold_probability)
    order["risk_value_score"] = quantity_lots_value * replay.FLOAT_SCALING // max(1, ltv_headroom_value)
    order["range_width_ticks"] = max(1, (order["higher"] - order["lower"]) // replay.FLOAT_SCALING)
    order["floor_lots"] = order["floor_seed_amount"] // replay.POSITION_LOT_SIZE
    order["floor_shares"] = replay.order_floor_shares_from_seed(
        order["floor_seed_amount"],
        order["leverage"],
        order["open_floor_index"],
    )
    order["tie_breakers"] = (
        order["opened_at_ms"],
        order["lower"],
        order["higher"],
        order["leverage"],
        order["entry_probability"],
        quantity_lots_value,
        order["sequence"],
    )
    return order


def floor_amount_at(order: dict[str, int], floor_index: int) -> int:
    return replay.floor_amount_for_index(order["floor_shares"], floor_index)


def liquidatable_metrics_by_ref(
    active_orders: dict[str, dict[str, int]],
    current_svi: dict[str, Any],
    current_forward: int,
    timestamp_ms: int,
    expiry_ms: int,
) -> dict[str, dict[str, int]]:
    probabilities: dict[tuple[int, int], int] = {}
    out: dict[str, dict[str, int]] = {}
    floor_index = replay.floor_index_at_ms(
        timestamp_ms,
        expiry_ms,
        replay.LEVERAGE_FLOOR_WINDOW_MS,
        replay.MAX_EXPIRY_FLOOR_PREMIUM,
    )
    for ref, order in active_orders.items():
        range_key = (order["lower"], order["higher"])
        probability = probabilities.get(range_key)
        if probability is None:
            probability = replay.compute_range_price(current_svi, current_forward, order["lower"], order["higher"])
            probabilities[range_key] = probability
        floor_amount = floor_amount_at(order, floor_index)
        threshold_value = replay.liquidation_threshold_value(floor_amount)
        gross_value = replay.deepbook_mul(probability, order["quantity"])
        if gross_value <= threshold_value:
            out[ref] = {
                "floor_amount": floor_amount,
                "gross_value": gross_value,
                "bad_debt": max(0, floor_amount - gross_value),
                "surplus": max(0, gross_value - floor_amount),
            }
    return out


def prefix_capture(prefix_values: list[int], count: int) -> int:
    if not prefix_values or count <= 0:
        return 0
    return prefix_values[min(count, len(prefix_values)) - 1]


def head_budget(scan_budget: int) -> int:
    return (scan_budget + replay.LIQUIDATION_HEAD_SCAN_DIVISOR - 1) // replay.LIQUIDATION_HEAD_SCAN_DIVISOR


def apply_order_updates(
    active_orders: dict[str, dict[str, int]],
    updates: list[dict[str, str]],
    timestamp_ms: int,
    expiry_ms: int,
) -> None:
    for update in updates:
        update_type = update["type"]
        if update_type == "order_minted":
            leverage = int(update["leverage"])
            if leverage == LEVERAGE_ONE_X:
                continue
            lower, higher = replay.strikes_from_ticks(
                int(update["lower_tick"]), int(update["higher_tick"])
            )
            active_orders[update["order_ref"]] = enrich_order({
                "sequence": int(update["order_sequence"]),
                "lower": lower,
                "higher": higher,
                "lower_boundary_index": replay.order_boundary_index(lower),
                "higher_boundary_index": replay.order_boundary_index(higher),
                "leverage": leverage,
                "entry_probability": int(update["entry_probability"]),
                "quantity": int(update["quantity"]),
                "floor_seed_amount": replay.compute_mint_terms(
                    int(update["entry_probability"]),
                    int(update["quantity"]),
                    leverage,
                )["floor_seed_amount"],
                "opened_at_ms": timestamp_ms,
                "open_floor_index": replay.floor_index_at_ms(
                    timestamp_ms,
                    expiry_ms,
                    replay.LEVERAGE_FLOOR_WINDOW_MS,
                    replay.MAX_EXPIRY_FLOOR_PREMIUM,
                ),
            })
        elif update_type == "live_order_redeemed":
            ref = update["order_ref"]
            order = active_orders.pop(ref, None)
            replacement_ref = update.get("replacement_order_ref")
            remaining_quantity = int(update.get("remaining_quantity") or 0)
            if order is None or not replacement_ref or remaining_quantity == 0:
                continue
            replacement_terms = replay.compute_mint_terms(
                order["entry_probability"],
                remaining_quantity,
                order["leverage"],
            )
            active_orders[replacement_ref] = enrich_order({
                **order,
                "sequence": int(update["replacement_order_sequence"]),
                "quantity": remaining_quantity,
                "floor_seed_amount": replacement_terms["floor_seed_amount"],
            })
        elif update_type in ("order_liquidated", "liquidated_order_redeemed", "settled_order_redeemed"):
            active_orders.pop(update["order_ref"], None)


def project_order_for_ranking(ref: str, order: dict[str, int]) -> dict[str, int | str]:
    return {
        "ref": ref,
        "sequence": order["sequence"],
        "leverage": order["leverage"],
        "quantity_lots": order["quantity_lots"],
        "lower_boundary_index": order["lower_boundary_index"],
        "higher_boundary_index": order["higher_boundary_index"],
        "floor_seed_probability": order["floor_seed_probability"],
        "floor_shares": order["floor_shares"],
        "floor_lots": order["floor_lots"],
        "entry_probability": order["entry_probability"],
        "floor_ratio": order["floor_ratio"],
        "liquidation_threshold_probability": order["liquidation_threshold_probability"],
        "ltv_headroom_probability": order["ltv_headroom_probability"],
        "ltv_headroom_ratio": order["ltv_headroom_ratio"],
        "terminal_ltv_headroom_probability": order["terminal_ltv_headroom_probability"],
        "risk_value_score": order["risk_value_score"],
        "opened_at_ms": order["opened_at_ms"],
        "range_width_ticks": order["range_width_ticks"],
    }


def first_oracle_spot(economic_data: dict[str, Any]) -> int:
    for record in economic_data["records"]:
        for update in record["updates"]:
            if update["type"] == "oracle_prices_updated":
                return int(update["spot"])
    raise ValueError("economic data has no oracle price update")


def build_ranking_dataset(
    economic_data: dict[str, Any],
    expiry_ms: int,
    *,
    sample_interval: int,
    max_samples: int | None,
) -> dict[str, Any]:
    active_orders: dict[str, dict[str, int]] = {}
    current_forward = 0
    current_svi: dict[str, Any] | None = None
    sampled_records = 0
    samples_with_backlog = 0
    samples: list[dict[str, Any]] = []

    for record in economic_data["records"]:
        if record["action"] == "terminal_closeout":
            break
        timestamp_ms = int(record.get("timestamp_ms") or record["step"])
        for update in record["updates"]:
            if update["type"] == "oracle_prices_updated":
                current_forward = int(update["forward"])
            elif update["type"] == "oracle_svi_updated":
                current_svi = svi_from_update(update)

        apply_order_updates(active_orders, record["updates"], timestamp_ms, expiry_ms)

        if int(record["step"]) % sample_interval != 0:
            continue
        if current_svi is None or current_forward == 0 or not active_orders:
            continue
        sampled_records += 1
        liquidatable = liquidatable_metrics_by_ref(
            active_orders,
            current_svi,
            current_forward,
            timestamp_ms,
            expiry_ms,
        )
        total_liquidatable_value = sum(metrics["floor_amount"] for metrics in liquidatable.values())
        if total_liquidatable_value == 0:
            if max_samples is not None and sampled_records >= max_samples:
                break
            continue
        samples_with_backlog += 1

        orders: list[dict[str, int | str]] = []
        liquidatable_values: list[int] = []
        live_bad_debt: list[int] = []
        live_surplus: list[int] = []
        for ref, order in active_orders.items():
            metrics = liquidatable.get(ref)
            orders.append(project_order_for_ranking(ref, order))
            liquidatable_values.append(0 if metrics is None else metrics["floor_amount"])
            live_bad_debt.append(0 if metrics is None else metrics["bad_debt"])
            live_surplus.append(0 if metrics is None else metrics["surplus"])
        samples.append(
            {
                "step": int(record["step"]),
                "timestamp_ms": timestamp_ms,
                "orders": orders,
                "liquidatable_values": liquidatable_values,
                "live_bad_debt": live_bad_debt,
                "live_surplus": live_surplus,
                "total_liquidatable_value": total_liquidatable_value,
            }
        )

        if max_samples is not None and sampled_records >= max_samples:
            break

    return {
        "sample_interval": sample_interval,
        "sampled_records": sampled_records,
        "samples_with_backlog": samples_with_backlog,
        "liquidation_head_scan_divisor": replay.LIQUIDATION_HEAD_SCAN_DIVISOR,
        "samples": samples,
    }


def empty_layout_metric(candidate: LayoutCandidate) -> dict[str, Any]:
    return {
        "encoding": candidate.name,
        "category": candidate.category,
        "field_order": [field_label(layout_field) for layout_field in candidate.fields] + ["sequence_asc"],
        "bits_used": 0,
        "samples_with_backlog": 0,
        "total_liquidatable_value": 0,
        "front_value": {share: 0 for share in FRONT_SHARES},
        "head_value": {budget: 0 for budget in SCAN_BUDGETS},
        "prefix_value": {budget: 0 for budget in SCAN_BUDGETS},
        "head_nonzero_samples": {budget: 0 for budget in SCAN_BUDGETS},
        "head_full_samples": {budget: 0 for budget in SCAN_BUDGETS},
    }


def layout_field_value(
    order: dict[str, int | str],
    sample: dict[str, Any],
    index: int,
    layout_field: LayoutField,
) -> int:
    if layout_field.name == "live_liquidatable_value":
        return sample["liquidatable_values"][index]
    if layout_field.name == "live_bad_debt":
        return sample["live_bad_debt"][index]
    if layout_field.name == "live_surplus":
        return sample["live_surplus"][index]
    value = order[layout_field.name]
    if not isinstance(value, int):
        raise TypeError(f"layout field {layout_field.name} is not numeric")
    return value


def layout_sort_key(
    order: dict[str, int | str],
    sample: dict[str, Any],
    index: int,
    candidate: LayoutCandidate,
) -> tuple[int, ...]:
    values = []
    for layout_field in candidate.fields:
        value = layout_field_value(order, sample, index, layout_field)
        values.append(-value if layout_field.desc else value)
    sequence = order["sequence"]
    if not isinstance(sequence, int):
        raise TypeError("sequence is not numeric")
    values.append(sequence)
    return tuple(values)


def score_layout_candidate(samples: list[dict[str, Any]], candidate: LayoutCandidate) -> dict[str, Any]:
    metric = empty_layout_metric(candidate)
    for sample in samples:
        orders = sample["orders"]
        liquidatable_values = sample["liquidatable_values"]
        ordered_indices = sorted(
            range(len(orders)),
            key=lambda index: layout_sort_key(orders[index], sample, index, candidate),
        )

        prefix_values = []
        running = 0
        for index in ordered_indices:
            running += liquidatable_values[index]
            prefix_values.append(running)

        total_liquidatable_value = sample["total_liquidatable_value"]
        metric["samples_with_backlog"] += 1
        metric["total_liquidatable_value"] += total_liquidatable_value
        for share in FRONT_SHARES:
            count = max(1, int(len(ordered_indices) * share))
            metric["front_value"][share] += prefix_capture(prefix_values, count)
        for budget in SCAN_BUDGETS:
            head_count = min(head_budget(budget), len(ordered_indices))
            prefix_count = min(budget, len(ordered_indices))
            head_captured = prefix_capture(prefix_values, head_count)
            prefix_captured = prefix_capture(prefix_values, prefix_count)
            metric["head_value"][budget] += head_captured
            metric["prefix_value"][budget] += prefix_captured
            if head_captured > 0:
                metric["head_nonzero_samples"][budget] += 1
            if head_captured >= total_liquidatable_value:
                metric["head_full_samples"][budget] += 1
    return finalize_metric(metric)


_WORKER_SAMPLES: list[dict[str, Any]] = []


def init_layout_worker(samples: list[dict[str, Any]]) -> None:
    global _WORKER_SAMPLES
    _WORKER_SAMPLES = samples


def score_layout_candidate_worker(candidate: LayoutCandidate) -> dict[str, Any]:
    return score_layout_candidate(_WORKER_SAMPLES, candidate)


def score_layout_candidates(
    samples: list[dict[str, Any]],
    candidates: list[LayoutCandidate],
    workers: int,
) -> list[dict[str, Any]]:
    if workers <= 1 or len(candidates) <= 1:
        return [score_layout_candidate(samples, candidate) for candidate in candidates]
    chunksize = max(1, len(candidates) // (workers * 4))
    with ProcessPoolExecutor(
        max_workers=workers,
        initializer=init_layout_worker,
        initargs=(samples,),
    ) as executor:
        return list(executor.map(score_layout_candidate_worker, candidates, chunksize=chunksize))


def select_layout_candidates(
    wide_layout_search: bool,
    layout_width: int,
    max_candidates: int | None,
) -> list[LayoutCandidate]:
    candidates = curated_layout_candidates()
    if wide_layout_search:
        candidates.extend(wide_layout_candidates(layout_width, max_candidates))
        candidates = dedupe_layouts(candidates)
    if max_candidates is not None:
        candidates = candidates[:max_candidates]
    return candidates


def rank_ranking_dataset(
    dataset: dict[str, Any],
    *,
    wide_layout_search: bool,
    layout_width: int,
    max_candidates: int | None,
    workers: int,
) -> dict[str, Any]:
    candidates = select_layout_candidates(wide_layout_search, layout_width, max_candidates)
    if workers <= 0:
        workers = min(8, os.cpu_count() or 1)
    finalized = score_layout_candidates(dataset["samples"], candidates, workers)

    return {
        "sample_interval": dataset["sample_interval"],
        "sampled_records": dataset["sampled_records"],
        "samples_with_backlog": dataset["samples_with_backlog"],
        "ranking_samples": len(dataset["samples"]),
        "candidate_count": len(candidates),
        "workers": workers,
        "scan_budgets": list(SCAN_BUDGETS),
        "front_shares": list(FRONT_SHARES),
        "encodings": finalized,
    }


def analyze(
    economic_data: dict[str, Any],
    expiry_ms: int,
    *,
    sample_interval: int,
    max_samples: int | None,
    wide_layout_search: bool,
    layout_width: int,
    max_candidates: int | None,
    workers: int,
) -> dict[str, Any]:
    dataset = build_ranking_dataset(
        economic_data,
        expiry_ms,
        sample_interval=sample_interval,
        max_samples=max_samples,
    )
    return rank_ranking_dataset(
        dataset,
        wide_layout_search=wide_layout_search,
        layout_width=layout_width,
        max_candidates=max_candidates,
        workers=workers,
    )


def safe_share(numerator: int, denominator: int) -> float:
    return 0.0 if denominator == 0 else numerator / denominator


def finalize_metric(metric: dict[str, Any]) -> dict[str, Any]:
    total = metric["total_liquidatable_value"]
    head_24 = safe_share(metric["head_value"][24], total)
    head_48 = safe_share(metric["head_value"][48], total)
    front_10 = safe_share(metric["front_value"][0.10], total)
    front_25 = safe_share(metric["front_value"][0.25], total)
    score = 0.40 * head_24 + 0.25 * head_48 + 0.20 * front_10 + 0.15 * front_25
    return {
        "encoding": metric["encoding"],
        "category": metric.get("category", "legacy"),
        "field_order": metric.get("field_order", []),
        "bits_used": metric["bits_used"],
        "samples_with_backlog": metric["samples_with_backlog"],
        "total_liquidatable_value_raw": str(total),
        "total_liquidatable_value_dusdc": total / replay.DUSDC_DECIMALS,
        "score": score,
        "front_capture": {
            f"{int(share * 100)}pct": safe_share(value, total)
            for share, value in metric["front_value"].items()
        },
        "head_capture": {
            str(budget): safe_share(value, total)
            for budget, value in metric["head_value"].items()
        },
        "prefix_capture": {
            str(budget): safe_share(value, total)
            for budget, value in metric["prefix_value"].items()
        },
        "head_nonzero_sample_share": {
            str(budget): safe_share(value, metric["samples_with_backlog"])
            for budget, value in metric["head_nonzero_samples"].items()
        },
        "head_full_sample_share": {
            str(budget): safe_share(value, metric["samples_with_backlog"])
            for budget, value in metric["head_full_samples"].items()
        },
    }


def print_table(results: dict[str, Any], limit: int) -> None:
    ranked = sorted(results["encodings"], key=lambda item: item["score"], reverse=True)
    print(
        f"samples={results['sampled_records']} "
        f"samples_with_backlog={results['samples_with_backlog']} "
        f"ranking_samples={results.get('ranking_samples', results['samples_with_backlog'])} "
        f"candidates={results.get('candidate_count', len(results['encodings']))} "
        f"workers={results.get('workers', 1)} "
        f"sample_interval={results['sample_interval']}"
    )
    print(
        "rank,encoding,category,score,front10,front25,head24,head48,head96,head192,prefix24,fields"
    )
    for index, row in enumerate(ranked[:limit], start=1):
        print(
            f"{index},"
            f"{row['encoding']},"
            f"{row.get('category', 'legacy')},"
            f"{row['score']:.6f},"
            f"{row['front_capture']['10pct']:.6f},"
            f"{row['front_capture']['25pct']:.6f},"
            f"{row['head_capture']['24']:.6f},"
            f"{row['head_capture']['48']:.6f},"
            f"{row['head_capture']['96']:.6f},"
            f"{row['head_capture']['192']:.6f},"
            f"{row['prefix_capture']['24']:.6f},"
            f"{' > '.join(row.get('field_order') or [])}"
        )

    baseline = next((row for row in ranked if row["encoding"].startswith("current__")), None)
    if baseline is not None:
        print("\nbaseline_current_order_id_layout:")
        print(json.dumps(baseline, indent=2, sort_keys=True))


def write_csv(path: Path, results: dict[str, Any]) -> None:
    rows = sorted(results["encodings"], key=lambda item: item["score"], reverse=True)
    with path.open("w", newline="") as outfile:
        writer = csv.DictWriter(
            outfile,
            fieldnames=[
                "encoding",
                "category",
                "field_order",
                "bits_used",
                "score",
                "front_10pct",
                "front_25pct",
                "head_24",
                "head_48",
                "head_96",
                "head_192",
                "head_500",
                "prefix_24",
                "prefix_192",
                "samples_with_backlog",
            ],
        )
        writer.writeheader()
        for row in rows:
            writer.writerow(
                {
                    "encoding": row["encoding"],
                    "category": row.get("category", "legacy"),
                    "field_order": " > ".join(row.get("field_order") or []),
                    "bits_used": row["bits_used"],
                    "score": row["score"],
                    "front_10pct": row["front_capture"]["10pct"],
                    "front_25pct": row["front_capture"]["25pct"],
                    "head_24": row["head_capture"]["24"],
                    "head_48": row["head_capture"]["48"],
                    "head_96": row["head_capture"]["96"],
                    "head_192": row["head_capture"]["192"],
                    "head_500": row["head_capture"]["500"],
                    "prefix_24": row["prefix_capture"]["24"],
                    "prefix_192": row["prefix_capture"]["192"],
                    "samples_with_backlog": row["samples_with_backlog"],
                }
            )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("python_long_data", type=Path, nargs="?", help="path to python_long_data.json")
    parser.add_argument(
        "--config",
        type=Path,
        default=SIM_DIR / "data" / "scenario_config.json",
        help="scenario config with expiry/protocol settings",
    )
    parser.add_argument("--sample-interval", type=int, default=replay.GLOBAL_OBSERVABILITY_INTERVAL)
    parser.add_argument("--max-samples", type=int)
    parser.add_argument(
        "--workers",
        type=int,
        default=0,
        help="ranking workers; 0 uses up to 8 local CPUs",
    )
    parser.add_argument(
        "--wide-layout-search",
        action="store_true",
        help="also generate wider directed field permutations",
    )
    parser.add_argument(
        "--layout-width",
        type=int,
        default=3,
        help="field count for --wide-layout-search permutations; sequence is always appended last",
    )
    parser.add_argument(
        "--max-candidates",
        type=int,
        help="cap candidate layouts after curated layouts and optional wide generation",
    )
    parser.add_argument("--top", type=int, default=20)
    parser.add_argument(
        "--ranking-dataset-in",
        type=Path,
        help="read a previously materialized ranking dataset and skip replay reconstruction",
    )
    parser.add_argument(
        "--ranking-dataset-out",
        type=Path,
        help="write the materialized ranking dataset used for scoring",
    )
    parser.add_argument("--out-json", type=Path)
    parser.add_argument("--out-csv", type=Path)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.sample_interval <= 0:
        raise SystemExit("--sample-interval must be positive")
    if args.layout_width <= 0:
        raise SystemExit("--layout-width must be positive")
    if args.max_candidates is not None and args.max_candidates <= 0:
        raise SystemExit("--max-candidates must be positive")

    config = replay.load_scenario_config(args.config)
    replay.apply_scenario_config(config)

    if args.ranking_dataset_in is not None:
        dataset = load_json_object(args.ranking_dataset_in)
    else:
        if args.python_long_data is None:
            raise SystemExit("python_long_data is required unless --ranking-dataset-in is provided")
        expiry_ms = replay.config_source_value(config, "expiry_ms")
        if expiry_ms is None:
            raise SystemExit("scenario config must include source.expiry_ms")
        economic_data = load_json_object(args.python_long_data)
        if economic_data.get("schema_version") != replay.ECONOMIC_SCHEMA_VERSION:
            raise SystemExit(f"input must use {replay.ECONOMIC_SCHEMA_VERSION} schema")
        replay.configure_oracle_grid(first_oracle_spot(economic_data))
        dataset = build_ranking_dataset(
            economic_data,
            expiry_ms,
            sample_interval=args.sample_interval,
            max_samples=args.max_samples,
        )
        if args.ranking_dataset_out is not None:
            write_json(args.ranking_dataset_out, dataset)
            print(f"wrote ranking dataset {args.ranking_dataset_out}")

    results = rank_ranking_dataset(
        dataset,
        wide_layout_search=args.wide_layout_search,
        layout_width=args.layout_width,
        max_candidates=args.max_candidates,
        workers=args.workers,
    )
    print_table(results, args.top)
    if args.out_json is not None:
        write_json(args.out_json, results)
        print(f"\nwrote {args.out_json}")
    if args.out_csv is not None:
        write_csv(args.out_csv, results)
        print(f"wrote {args.out_csv}")


if __name__ == "__main__":
    main()
