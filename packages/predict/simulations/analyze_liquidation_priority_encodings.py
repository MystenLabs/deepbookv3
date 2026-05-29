#!/usr/bin/env python3
"""Compare candidate 32-bit liquidation priority encodings against replay data."""

from __future__ import annotations

import argparse
import csv
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

SIM_DIR = Path(__file__).resolve().parent
if str(SIM_DIR) not in sys.path:
    sys.path.insert(0, str(SIM_DIR))

import python_replay as replay  # noqa: E402
from sim_artifacts import load_json_object, write_json  # noqa: E402


U32_MASK = (1 << 32) - 1
U28_MASK = (1 << 28) - 1
FRONT_SHARES = (0.05, 0.10, 0.25, 0.50)
SCAN_BUDGETS = (24, 48, 96, 192, 500)
MAX_LEVERAGE_CODE = 4


@dataclass(frozen=True)
class Encoding:
    name: str
    bits_used: int
    key_fn: Callable[[dict[str, int]], tuple[int, ...]]


def uint_ratio_bucket(value: int, bits: int, max_value: int = replay.FLOAT_SCALING) -> int:
    if bits == 0:
        return 0
    mask = (1 << bits) - 1
    if value <= 0:
        return 0
    if value >= max_value:
        return mask
    return value * mask // max_value


def saturated_bucket(value: int, bits: int) -> int:
    if bits == 0:
        return 0
    return min((1 << bits) - 1, max(0, value))


def scaled_ratio(numerator: int, denominator: int) -> int:
    if denominator <= 0:
        return 0
    return numerator * replay.FLOAT_SCALING // denominator


def log_bucket(value: int, bits: int) -> int:
    if bits == 0 or value <= 0:
        return 0
    return min((1 << bits) - 1, value.bit_length() - 1)


def quantity_lots(order: dict[str, int]) -> int:
    return order["quantity_lots"]


def user_contribution_probability(order: dict[str, int]) -> int:
    return order["user_contribution_probability"]


def floor_seed_probability(order: dict[str, int]) -> int:
    return order["floor_seed_probability"]


def ltv_headroom_probability(order: dict[str, int]) -> int:
    return order["ltv_headroom_probability"]


def ltv_headroom_ratio(order: dict[str, int]) -> int:
    return order["ltv_headroom_ratio"]


def terminal_ltv_headroom_probability(order: dict[str, int]) -> int:
    return order["terminal_ltv_headroom_probability"]


def liquidation_threshold_probability(order: dict[str, int]) -> int:
    return order["liquidation_threshold_probability"]


def floor_ratio(order: dict[str, int]) -> int:
    return order["floor_ratio"]


def risk_value_score(order: dict[str, int]) -> int:
    return order["risk_value_score"]


def leverage_code(order: dict[str, int]) -> int:
    return order["leverage"]


def range_width_ticks(order: dict[str, int]) -> int:
    return order["range_width_ticks"]


def floor_lots(order: dict[str, int]) -> int:
    return order["floor_lots"]


def order_tie_breakers(order: dict[str, int]) -> tuple[int, ...]:
    return order["tie_breakers"]


def make_old_floor_desc_encoding() -> Encoding:
    def key(order: dict[str, int]) -> tuple[int, ...]:
        priority = U32_MASK - floor_seed_probability(order)
        return (priority, *order_tie_breakers(order))

    return Encoding("old_floor_desc", 32, key)


def make_current_encoding() -> Encoding:
    def key(order: dict[str, int]) -> tuple[int, ...]:
        quantity_bucket = min(quantity_lots(order), U28_MASK)
        priority = ((MAX_LEVERAGE_CODE - leverage_code(order)) << 28) | (U28_MASK - quantity_bucket)
        return (priority, *order_tie_breakers(order))

    return Encoding("current_leverage_quantity", 32, key)


def make_full_probability_encoding(name: str, probability_fn: Callable[[dict[str, int]], int]) -> Encoding:
    def key(order: dict[str, int]) -> tuple[int, ...]:
        priority = uint_ratio_bucket(probability_fn(order), 32)
        return (priority, *order_tie_breakers(order))

    return Encoding(name, 32, key)


def make_desc_probability_encoding(name: str, probability_fn: Callable[[dict[str, int]], int]) -> Encoding:
    def key(order: dict[str, int]) -> tuple[int, ...]:
        priority = U32_MASK - uint_ratio_bucket(probability_fn(order), 32)
        return (priority, *order_tie_breakers(order))

    return Encoding(name, 32, key)


def make_ascending_int_encoding(name: str, metric_fn: Callable[[dict[str, int]], int]) -> Encoding:
    def key(order: dict[str, int]) -> tuple[int, ...]:
        priority = saturated_bucket(metric_fn(order), 32)
        return (priority, *order_tie_breakers(order))

    return Encoding(name, 32, key)


def make_desc_int_encoding(name: str, metric_fn: Callable[[dict[str, int]], int]) -> Encoding:
    def key(order: dict[str, int]) -> tuple[int, ...]:
        priority = U32_MASK - saturated_bucket(metric_fn(order), 32)
        return (priority, *order_tie_breakers(order))

    return Encoding(name, 32, key)


def deterministic_hash_u32(value: int) -> int:
    x = value & U32_MASK
    x ^= (x >> 16)
    x = (x * 0x7FEB352D) & U32_MASK
    x ^= (x >> 15)
    x = (x * 0x846CA68B) & U32_MASK
    x ^= (x >> 16)
    return x & U32_MASK


def make_hash_baseline() -> Encoding:
    def key(order: dict[str, int]) -> tuple[int, ...]:
        return (deterministic_hash_u32(order["sequence"]), *order_tie_breakers(order))

    return Encoding("random_sequence_hash", 32, key)


def value_for_metric(order: dict[str, int], metric: str) -> int:
    if metric == "floor_lots":
        return floor_lots(order)
    if metric == "quantity_lots":
        return quantity_lots(order)
    raise ValueError(f"unknown value metric {metric}")


def make_bucketed_encoding(
    likelihood_name: str,
    likelihood_fn: Callable[[dict[str, int]], int],
    likelihood_bits: int,
    value_metric: str,
    value_bits: int,
    *,
    likelihood_desc: bool = False,
    value_log: bool = False,
) -> Encoding:
    bits_used = likelihood_bits + value_bits
    if bits_used > 32:
        raise ValueError("encoding exceeds 32 bits")
    likelihood_mask = (1 << likelihood_bits) - 1 if likelihood_bits > 0 else 0
    value_mask = (1 << value_bits) - 1 if value_bits > 0 else 0
    value_kind = "log_value" if value_log else "value"
    name = f"{likelihood_name}{likelihood_bits}_{value_kind}{value_bits}_{value_metric}"

    def key(order: dict[str, int]) -> tuple[int, ...]:
        likelihood_bucket = uint_ratio_bucket(likelihood_fn(order), likelihood_bits)
        if likelihood_desc:
            likelihood_bucket = likelihood_mask - likelihood_bucket
        value = value_for_metric(order, value_metric)
        value_bucket = log_bucket(value, value_bits) if value_log else saturated_bucket(value, value_bits)
        inverse_value_bucket = value_mask - value_bucket if value_bits > 0 else 0
        priority = (likelihood_bucket << value_bits) | inverse_value_bucket
        if priority > U32_MASK:
            raise ValueError(f"encoding {name} overflowed u32")
        return (priority, *order_tie_breakers(order))

    return Encoding(name, bits_used, key)


def make_three_part_encoding(
    name: str,
    first_fn: Callable[[dict[str, int]], int],
    first_bits: int,
    first_desc: bool,
    second_fn: Callable[[dict[str, int]], int],
    second_bits: int,
    second_desc: bool,
    value_metric: str,
    value_bits: int,
) -> Encoding:
    bits_used = first_bits + second_bits + value_bits
    if bits_used > 32:
        raise ValueError("encoding exceeds 32 bits")
    first_mask = (1 << first_bits) - 1 if first_bits > 0 else 0
    second_mask = (1 << second_bits) - 1 if second_bits > 0 else 0
    value_mask = (1 << value_bits) - 1 if value_bits > 0 else 0

    def key(order: dict[str, int]) -> tuple[int, ...]:
        first_bucket = uint_ratio_bucket(first_fn(order), first_bits)
        if first_desc:
            first_bucket = first_mask - first_bucket
        second_bucket = uint_ratio_bucket(second_fn(order), second_bits)
        if second_desc:
            second_bucket = second_mask - second_bucket
        value_bucket = saturated_bucket(value_for_metric(order, value_metric), value_bits)
        inverse_value_bucket = value_mask - value_bucket if value_bits > 0 else 0
        priority = (first_bucket << (second_bits + value_bits)) | (second_bucket << value_bits) | inverse_value_bucket
        if priority > U32_MASK:
            raise ValueError(f"encoding {name} overflowed u32")
        return (priority, *order_tie_breakers(order))

    return Encoding(name, bits_used, key)


def make_leverage_value_encoding(value_metric: str, value_bits: int) -> Encoding:
    bits_used = 4 + value_bits
    if bits_used > 32:
        raise ValueError("encoding exceeds 32 bits")
    value_mask = (1 << value_bits) - 1 if value_bits > 0 else 0
    name = f"leverage_desc4_value{value_bits}_{value_metric}"

    def key(order: dict[str, int]) -> tuple[int, ...]:
        leverage_bucket = MAX_LEVERAGE_CODE - min(MAX_LEVERAGE_CODE, leverage_code(order))
        value_bucket = saturated_bucket(value_for_metric(order, value_metric), value_bits)
        inverse_value_bucket = value_mask - value_bucket if value_bits > 0 else 0
        priority = (leverage_bucket << value_bits) | inverse_value_bucket
        if priority > U32_MASK:
            raise ValueError(f"encoding {name} overflowed u32")
        return (priority, *order_tie_breakers(order))

    return Encoding(name, bits_used, key)


def leverage_risk(order: dict[str, int]) -> int:
    return scaled_ratio(leverage_code(order), MAX_LEVERAGE_CODE)


def inverse_width_risk(order: dict[str, int]) -> int:
    return scaled_ratio(1, max(1, range_width_ticks(order)))


def default_encodings() -> list[Encoding]:
    encodings = [
        make_current_encoding(),
        make_old_floor_desc_encoding(),
        make_hash_baseline(),
        make_full_probability_encoding("headroom_full", user_contribution_probability),
        make_full_probability_encoding("ltv_headroom_full", ltv_headroom_probability),
        make_full_probability_encoding("ltv_headroom_ratio_full", ltv_headroom_ratio),
        make_full_probability_encoding("terminal_ltv_headroom_full", terminal_ltv_headroom_probability),
        make_desc_probability_encoding("liquidation_threshold_desc_full", liquidation_threshold_probability),
        make_desc_probability_encoding("floor_ratio_desc_full", floor_ratio),
        make_desc_int_encoding("risk_value_desc_full", risk_value_score),
    ]
    for likelihood_name, likelihood_fn in (
        ("headroom", user_contribution_probability),
        ("ltv_headroom", ltv_headroom_probability),
        ("ltv_headroom_ratio", ltv_headroom_ratio),
        ("terminal_ltv_headroom", terminal_ltv_headroom_probability),
    ):
        for value_metric in ("floor_lots", "quantity_lots"):
            for likelihood_bits in range(12, 31, 2):
                value_bits = 32 - likelihood_bits
                if value_bits < 2:
                    continue
                encodings.append(
                    make_bucketed_encoding(
                        likelihood_name,
                        likelihood_fn,
                        likelihood_bits,
                        value_metric,
                        value_bits,
                    )
                )
            for likelihood_bits, value_bits in ((26, 6), (24, 8), (20, 12)):
                encodings.append(
                    make_bucketed_encoding(
                        likelihood_name,
                        likelihood_fn,
                        likelihood_bits,
                        value_metric,
                        value_bits,
                        value_log=True,
                    )
                )
    for likelihood_name, likelihood_fn in (
        ("liquidation_threshold_desc", liquidation_threshold_probability),
        ("floor_ratio_desc", floor_ratio),
    ):
        for value_metric in ("floor_lots", "quantity_lots"):
            for likelihood_bits in range(12, 31, 2):
                value_bits = 32 - likelihood_bits
                if value_bits < 2:
                    continue
                encodings.append(
                    make_bucketed_encoding(
                        likelihood_name,
                        likelihood_fn,
                        likelihood_bits,
                        value_metric,
                        value_bits,
                        likelihood_desc=True,
                    )
                )
    for first_name, first_fn, first_desc in (
        ("leverage_desc", leverage_risk, True),
        ("width_desc", inverse_width_risk, True),
        ("risk_value_desc", risk_value_score, True),
    ):
        encodings.append(
            make_three_part_encoding(
                f"{first_name}4_ltv_headroom20_value8_floor_lots",
                first_fn,
                4,
                first_desc,
                ltv_headroom_probability,
                20,
                False,
                "floor_lots",
                8,
            )
        )
        encodings.append(
            make_three_part_encoding(
                f"ltv_headroom20_{first_name}4_value8_floor_lots",
                ltv_headroom_probability,
                20,
                False,
                first_fn,
                4,
                first_desc,
                "floor_lots",
                8,
            )
        )
    for value_metric in ("floor_lots", "quantity_lots"):
        encodings.append(make_leverage_value_encoding(value_metric, 28))
        encodings.append(
            make_three_part_encoding(
                f"leverage_desc4_ltv_headroom_ratio20_value8_{value_metric}",
                leverage_risk,
                4,
                True,
                ltv_headroom_ratio,
                20,
                False,
                value_metric,
                8,
            )
        )
        encodings.append(
            make_three_part_encoding(
                f"leverage_desc4_floor_ratio_desc20_value8_{value_metric}",
                leverage_risk,
                4,
                True,
                floor_ratio,
                20,
                True,
                value_metric,
                8,
            )
        )
        encodings.append(
            make_three_part_encoding(
                f"ltv_headroom_ratio20_leverage_desc4_value8_{value_metric}",
                ltv_headroom_ratio,
                20,
                False,
                leverage_risk,
                4,
                True,
                value_metric,
                8,
            )
        )
        encodings.append(
            make_three_part_encoding(
                f"floor_ratio_desc20_leverage_desc4_value8_{value_metric}",
                floor_ratio,
                20,
                True,
                leverage_risk,
                4,
                True,
                value_metric,
                8,
            )
        )
    return encodings


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


def liquidatable_floor_by_ref(
    active_orders: dict[str, dict[str, int]],
    current_svi: dict[str, Any],
    current_forward: int,
    timestamp_ms: int,
    expiry_ms: int,
) -> dict[str, int]:
    probabilities: dict[tuple[int, int], int] = {}
    out: dict[str, int] = {}
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
            out[ref] = floor_amount
    return out


def prefix_sums_for_ordered_refs(
    ordered: list[tuple[str, dict[str, int]]],
    liquidatable: dict[str, int],
) -> list[int]:
    prefix: list[int] = []
    running = 0
    for ref, _order in ordered:
        running += liquidatable.get(ref, 0)
        prefix.append(running)
    return prefix


def prefix_capture(prefix_values: list[int], count: int) -> int:
    if not prefix_values or count <= 0:
        return 0
    return prefix_values[min(count, len(prefix_values)) - 1]


def head_budget(scan_budget: int) -> int:
    return (scan_budget + replay.LIQUIDATION_HEAD_SCAN_DIVISOR - 1) // replay.LIQUIDATION_HEAD_SCAN_DIVISOR


def empty_metrics(encodings: list[Encoding]) -> dict[str, dict[str, Any]]:
    return {
        encoding.name: {
            "encoding": encoding.name,
            "bits_used": encoding.bits_used,
            "samples_with_backlog": 0,
            "total_liquidatable_value": 0,
            "front_value": {share: 0 for share in FRONT_SHARES},
            "head_value": {budget: 0 for budget in SCAN_BUDGETS},
            "prefix_value": {budget: 0 for budget in SCAN_BUDGETS},
            "head_nonzero_samples": {budget: 0 for budget in SCAN_BUDGETS},
            "head_full_samples": {budget: 0 for budget in SCAN_BUDGETS},
        }
        for encoding in encodings
    }


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
            if leverage == 0:
                continue
            active_orders[update["order_ref"]] = enrich_order({
                "sequence": int(update["order_sequence"]),
                "lower": int(update["lower_strike"]),
                "higher": int(update["higher_strike"]),
                "leverage": leverage,
                "entry_probability": int(update["entry_probability"]),
                "quantity": int(update["quantity"]),
                "floor_seed_amount": int(update["floor_seed_amount"]),
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


def analyze(
    economic_data: dict[str, Any],
    expiry_ms: int,
    *,
    sample_interval: int,
    max_samples: int | None,
) -> dict[str, Any]:
    encodings = default_encodings()
    metrics = empty_metrics(encodings)
    active_orders: dict[str, dict[str, int]] = {}
    current_forward = 0
    current_svi: dict[str, Any] | None = None
    sampled_records = 0
    samples_with_backlog = 0

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
        liquidatable = liquidatable_floor_by_ref(
            active_orders,
            current_svi,
            current_forward,
            timestamp_ms,
            expiry_ms,
        )
        total_liquidatable_value = sum(liquidatable.values())
        if total_liquidatable_value == 0:
            continue
        samples_with_backlog += 1
        orders = list(active_orders.items())

        for encoding in encodings:
            ordered = sorted(orders, key=lambda item: encoding.key_fn(item[1]))
            prefix_values = prefix_sums_for_ordered_refs(ordered, liquidatable)
            metric = metrics[encoding.name]
            metric["samples_with_backlog"] += 1
            metric["total_liquidatable_value"] += total_liquidatable_value
            for share in FRONT_SHARES:
                count = max(1, int(len(ordered) * share))
                metric["front_value"][share] += prefix_capture(prefix_values, count)
            for budget in SCAN_BUDGETS:
                head_count = min(head_budget(budget), len(ordered))
                prefix_count = min(budget, len(ordered))
                head_captured = prefix_capture(prefix_values, head_count)
                prefix_captured = prefix_capture(prefix_values, prefix_count)
                metric["head_value"][budget] += head_captured
                metric["prefix_value"][budget] += prefix_captured
                if head_captured > 0:
                    metric["head_nonzero_samples"][budget] += 1
                if head_captured >= total_liquidatable_value:
                    metric["head_full_samples"][budget] += 1

        if max_samples is not None and sampled_records >= max_samples:
            break

    return {
        "sample_interval": sample_interval,
        "sampled_records": sampled_records,
        "samples_with_backlog": samples_with_backlog,
        "scan_budgets": list(SCAN_BUDGETS),
        "front_shares": list(FRONT_SHARES),
        "encodings": [finalize_metric(metric) for metric in metrics.values()],
    }


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
        f"sample_interval={results['sample_interval']}"
    )
    print(
        "rank,encoding,bits,score,front10,front25,head24,head48,head96,head192,prefix24"
    )
    for index, row in enumerate(ranked[:limit], start=1):
        print(
            f"{index},"
            f"{row['encoding']},"
            f"{row['bits_used']},"
            f"{row['score']:.6f},"
            f"{row['front_capture']['10pct']:.6f},"
            f"{row['front_capture']['25pct']:.6f},"
            f"{row['head_capture']['24']:.6f},"
            f"{row['head_capture']['48']:.6f},"
            f"{row['head_capture']['96']:.6f},"
            f"{row['head_capture']['192']:.6f},"
            f"{row['prefix_capture']['24']:.6f}"
        )

    baseline = next(row for row in ranked if row["encoding"] == "current_leverage_quantity")
    print("\nbaseline_current_leverage_quantity:")
    print(json.dumps(baseline, indent=2, sort_keys=True))


def write_csv(path: Path, results: dict[str, Any]) -> None:
    rows = sorted(results["encodings"], key=lambda item: item["score"], reverse=True)
    with path.open("w", newline="") as outfile:
        writer = csv.DictWriter(
            outfile,
            fieldnames=[
                "encoding",
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
    parser.add_argument("python_long_data", type=Path, help="path to python_long_data.json")
    parser.add_argument(
        "--config",
        type=Path,
        default=SIM_DIR / "data" / "scenario_config.json",
        help="scenario config with expiry/protocol settings",
    )
    parser.add_argument("--sample-interval", type=int, default=replay.GLOBAL_OBSERVABILITY_INTERVAL)
    parser.add_argument("--max-samples", type=int)
    parser.add_argument("--top", type=int, default=20)
    parser.add_argument("--out-json", type=Path)
    parser.add_argument("--out-csv", type=Path)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.sample_interval <= 0:
        raise SystemExit("--sample-interval must be positive")

    config = replay.load_scenario_config(args.config)
    replay.apply_scenario_config(config)
    expiry_ms = replay.config_source_value(config, "expiry_ms")
    if expiry_ms is None:
        raise SystemExit("scenario config must include source.expiry_ms")

    economic_data = load_json_object(args.python_long_data)
    if economic_data.get("schema_version") != replay.ECONOMIC_SCHEMA_VERSION:
        raise SystemExit("input must use predict_economic_v1 schema")

    results = analyze(
        economic_data,
        expiry_ms,
        sample_interval=args.sample_interval,
        max_samples=args.max_samples,
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
