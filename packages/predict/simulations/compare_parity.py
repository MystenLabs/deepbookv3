#!/usr/bin/env python3
"""Compare canonical localnet/Python economics while ignoring chain-time telemetry."""

from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path
from typing import Any


OBSERVATIONAL_EVENT_FIELDS = {
    "onchain_timestamp_ms",
    "pyth_spot_source_timestamp_ms",
    "block_scholes_spot_source_timestamp_ms",
    "block_scholes_forward_source_timestamp_ms",
    "block_scholes_svi_source_timestamp_ms",
}
ECONOMIC_SCHEMA_VERSION = "predict_economic_v4"
REQUIRED_ACTIONS = [
    "mint",
    "redeem_live",
    "request_supply",
    "request_withdraw",
    "flush",
    "rebalance_expiry_cash",
    "settle",
    "redeem_settled",
]
EXPECTED_ACTION_SEQUENCE = [
    "mint",
    "mint",
    "redeem_live",
    "request_supply",
    "flush",
    "request_withdraw",
    "flush",
    "mint",
    "redeem_live",
    "rebalance_expiry_cash",
    "mint",
    "mint",
    "settle",
    "redeem_settled",
    "redeem_settled",
    "redeem_settled",
    "redeem_settled",
    "flush",
    "request_supply",
    "flush",
]
TOP_LEVEL_FIELDS = {"schema_version", "scenario", "records"}
SCENARIO_FIELDS = {"quantity_scale", "required_actions", "observed_actions"}
RECORD_FIELDS = {"step", "action", "input", "updates", "state"}
ORACLE_INPUT_FIELDS = {
    "spot": "decimal",
    "forward": "decimal",
    "a": "decimal",
    "a_negative": "boolean",
    "b": "decimal",
    "rho": "decimal",
    "rho_negative": "boolean",
    "m": "decimal",
    "m_negative": "boolean",
    "sigma": "decimal",
    "risk_free_rate": "decimal",
}
INPUT_SCHEMAS = {
    "mint": {
        **ORACLE_INPUT_FIELDS,
        "order_ref": "string",
        "lower_tick": "decimal",
        "higher_tick": "decimal",
        "quantity": "decimal",
    },
    "redeem_live": {
        **ORACLE_INPUT_FIELDS,
        "order_ref": "string",
        "close_quantity": "decimal",
        "replacement_order_ref": "nullable_string",
    },
    "request_supply": {
        "amount": "decimal",
        "min_output": "decimal",
        "lp_ref": "string",
    },
    "request_withdraw": {
        "shares": "decimal",
        "min_output": "decimal",
        "lp_ref": "string",
    },
    "rebalance_expiry_cash": {},
    "settle": {"settlement_price": "decimal"},
    "redeem_settled": {"order_ref": "string"},
}
STATE_FIELDS = {
    field: "decimal"
    for field in {
        "account_dusdc_balance",
        "account_plp_balance",
        "expiry_cash_balance",
        "inventory_impact_reserve",
        "payout_liability",
        "required_cash",
        "fee_incentive_balance",
        "vault_idle_balance",
        "vault_protocol_reserve_balance",
        "vault_pending_protocol_profit",
        "profit_basis_debits",
        "profit_basis_credits",
        "vault_total_plp_supply",
        "supply_requests_pending",
        "withdraw_requests_pending",
        "is_settled",
        "active_market_count",
    }
}
UPDATE_SCHEMAS = {
    "order_minted": {
        "order_ref": "string",
        "order_sequence": "decimal",
        "lower_tick": "decimal",
        "higher_tick": "decimal",
        "entry_probability": "decimal",
        "quantity": "decimal",
        "premium": "decimal",
        "trading_fee": "decimal",
        "fee_incentive_subsidy": "decimal",
        "builder_fee": "decimal",
        "penalty_fee": "decimal",
        "referral_fee": "decimal",
        "inventory_impact_charge": "decimal",
        "onchain_timestamp_ms": "decimal",
        "pyth_spot_source_timestamp_ms": "decimal",
        "block_scholes_spot_source_timestamp_ms": "decimal",
        "block_scholes_forward_source_timestamp_ms": "decimal",
        "block_scholes_svi_source_timestamp_ms": "decimal",
    },
    "live_order_redeemed": {
        "order_ref": "string",
        "order_sequence": "decimal",
        "quantity_closed": "decimal",
        "remaining_quantity": "decimal",
        "replacement_order_ref": "nullable_string",
        "replacement_order_sequence": "nullable_decimal",
        "redeem_amount": "decimal",
        "trading_fee": "decimal",
        "builder_fee": "decimal",
        "penalty_fee": "decimal",
        "inventory_impact_rebate": "decimal",
        "onchain_timestamp_ms": "decimal",
        "pyth_spot_source_timestamp_ms": "decimal",
        "block_scholes_spot_source_timestamp_ms": "decimal",
        "block_scholes_forward_source_timestamp_ms": "decimal",
        "block_scholes_svi_source_timestamp_ms": "decimal",
    },
    "supply_requested": {
        "lp_ref": "string",
        "index": "decimal",
        "amount": "decimal",
        "min_output": "decimal",
        "requests_pending_after": "decimal",
    },
    "withdraw_requested": {
        "lp_ref": "string",
        "index": "decimal",
        "amount": "decimal",
        "min_output": "decimal",
        "requests_pending_after": "decimal",
    },
    "request_cancelled": {
        "index": "decimal",
        "amount": "decimal",
        "is_supply": "boolean",
        "reason": "decimal",
        "requests_pending_after": "decimal",
    },
    "supply_filled": {
        "index": "decimal",
        "dusdc_amount": "decimal",
        "shares_minted": "decimal",
        "fee_dusdc": "decimal",
        "dusdc_remaining": "decimal",
        "requests_pending_after": "decimal",
    },
    "withdraw_filled": {
        "index": "decimal",
        "shares_burned": "decimal",
        "dusdc_amount": "decimal",
        "fee_dusdc": "decimal",
        "shares_remaining": "decimal",
        "requests_pending_after": "decimal",
    },
    "flush_executed": {
        "pool_value": "decimal",
        "total_supply": "decimal",
        "supply_fee_rate": "decimal",
        "withdraw_fee_rate": "decimal",
        "active_market_nav": "decimal",
        "market_count": "decimal",
        "idle_balance_before": "decimal",
        "supplies_filled": "decimal",
        "withdrawals_filled": "decimal",
        "requests_processed": "decimal",
        "idle_balance_after": "decimal",
        "total_supply_after": "decimal",
    },
    "expiry_cash_rebalanced": {
        "amount": "decimal",
        "to_expiry": "boolean",
        "target_cash": "decimal",
        "protocol_profit_realized": "decimal",
    },
    "market_settled": {
        "settlement_price": "decimal",
        "settlement_source": "decimal",
        "onchain_timestamp_ms": "decimal",
    },
    "expiry_cash_received": {
        "settlement_price": "decimal",
        "amount": "decimal",
    },
    "expiry_profit_materialized": {
        "lp_profit": "decimal",
        "protocol_profit": "decimal",
        "protocol_reserve_balance_after": "decimal",
        "profit_basis_after": "decimal",
        "pending_protocol_profit_after": "decimal",
    },
    "settled_order_redeemed": {
        "order_ref": "string",
        "order_sequence": "decimal",
        "payout_amount": "decimal",
        "onchain_timestamp_ms": "decimal",
    },
}
ACTION_UPDATE_TYPES = {
    "mint": {"order_minted"},
    "redeem_live": {"live_order_redeemed"},
    "request_supply": {"supply_requested"},
    "request_withdraw": {"withdraw_requested"},
    "flush": {
        "request_cancelled",
        "supply_filled",
        "withdraw_filled",
        "flush_executed",
        "expiry_cash_rebalanced",
    },
    "rebalance_expiry_cash": {"expiry_cash_rebalanced"},
    "settle": {
        "market_settled",
        "expiry_cash_received",
        "expiry_profit_materialized",
    },
    "redeem_settled": {"settled_order_redeemed"},
}
REQUIRED_SINGLE_UPDATE_TYPES = {
    "mint": {"order_minted"},
    "redeem_live": {"live_order_redeemed"},
    "request_supply": {"supply_requested"},
    "request_withdraw": {"withdraw_requested"},
    "flush": {"flush_executed"},
    "rebalance_expiry_cash": {"expiry_cash_rebalanced"},
    "settle": {"market_settled", "expiry_cash_received"},
    "redeem_settled": {"settled_order_redeemed"},
}
OPTIONAL_SINGLE_UPDATE_TYPES = {"settle": {"expiry_profit_materialized"}}


def parity_projection(payload: dict[str, Any]) -> dict[str, Any]:
    projected = copy.deepcopy(payload)
    for record in projected.get("records", []):
        for update in record.get("updates", []):
            for field in OBSERVATIONAL_EVENT_FIELDS:
                update.pop(field, None)
    return projected


def _fail(label: str, path: str, message: str) -> None:
    raise SystemExit(f"{label}: {path} {message}")


def _exact_fields(value: Any, expected: set[str], label: str, path: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        _fail(label, path, "must be an object")
    missing = sorted(expected - value.keys())
    unknown = sorted(value.keys() - expected)
    if missing or unknown:
        details = []
        if missing:
            details.append(f"missing={','.join(missing)}")
        if unknown:
            details.append(f"unknown={','.join(unknown)}")
        _fail(label, path, f"schema mismatch; {'; '.join(details)}")
    return value


def _validate_value(value: Any, kind: str, label: str, path: str) -> None:
    if kind == "decimal":
        valid = isinstance(value, str) and value.isdecimal()
    elif kind == "boolean":
        valid = type(value) is bool
    elif kind == "string":
        valid = isinstance(value, str) and bool(value)
    elif kind == "nullable_string":
        valid = value is None or (isinstance(value, str) and bool(value))
    elif kind == "nullable_decimal":
        valid = value is None or (isinstance(value, str) and value.isdecimal())
    else:
        raise AssertionError(f"unknown schema kind {kind}")
    if not valid:
        _fail(label, path, f"must be {kind}")


def _validate_typed_object(
    value: Any,
    schema: dict[str, str],
    label: str,
    path: str,
) -> None:
    obj = _exact_fields(value, set(schema), label, path)
    for field, kind in schema.items():
        _validate_value(obj[field], kind, label, f"{path}.{field}")


def validate_economic_payload(payload: Any, label: str) -> None:
    root = _exact_fields(payload, TOP_LEVEL_FIELDS, label, "$")
    if root["schema_version"] != ECONOMIC_SCHEMA_VERSION:
        _fail(label, "$.schema_version", f"unsupported economic schema {root['schema_version']!r}")

    scenario = _exact_fields(root["scenario"], SCENARIO_FIELDS, label, "$.scenario")
    if scenario["quantity_scale"] != "1":
        _fail(label, "$.scenario.quantity_scale", "must equal '1'")
    required = scenario["required_actions"]
    observed = scenario["observed_actions"]
    if required != REQUIRED_ACTIONS:
        _fail(label, "$.scenario.required_actions", "does not match the current schema")
    if not isinstance(observed, list) or any(action not in REQUIRED_ACTIONS for action in observed):
        _fail(label, "$.scenario.observed_actions", "must contain only current actions")

    records = root["records"]
    if not isinstance(records, list) or not records:
        _fail(label, "$.records", "must be a non-empty array")
    if len(records) != len(EXPECTED_ACTION_SEQUENCE):
        _fail(
            label,
            "$.records",
            f"must contain exactly {len(EXPECTED_ACTION_SEQUENCE)} scenario steps",
        )
    derived_observed: list[str] = []
    for index, raw_record in enumerate(records):
        path = f"$.records[{index}]"
        record = _exact_fields(raw_record, RECORD_FIELDS, label, path)
        step = record["step"]
        if type(step) is not int or step != index + 1:
            _fail(label, f"{path}.step", f"must equal {index + 1}")
        action = record["action"]
        if not isinstance(action, str) or action not in REQUIRED_ACTIONS:
            _fail(label, f"{path}.action", "must be a current action")
        if action != EXPECTED_ACTION_SEQUENCE[index]:
            _fail(
                label,
                f"{path}.action",
                f"must equal {EXPECTED_ACTION_SEQUENCE[index]}",
            )
        if action not in derived_observed:
            derived_observed.append(action)

        input_schemas = (
            [{}, ORACLE_INPUT_FIELDS]
            if action == "flush"
            else [INPUT_SCHEMAS[action]]
        )
        if not isinstance(record["input"], dict):
            _fail(label, f"{path}.input", "must be an object")
        matching_input = next(
            (schema for schema in input_schemas if record["input"].keys() == schema.keys()),
            None,
        )
        if matching_input is None:
            expected = " or ".join(str(sorted(schema)) for schema in input_schemas)
            _fail(label, f"{path}.input", f"fields must equal {expected}")
        _validate_typed_object(record["input"], matching_input, label, f"{path}.input")

        updates = record["updates"]
        if not isinstance(updates, list) or not updates:
            _fail(label, f"{path}.updates", "must be a non-empty array")
        update_types: list[str] = []
        for update_index, raw_update in enumerate(updates):
            update_path = f"{path}.updates[{update_index}]"
            if not isinstance(raw_update, dict):
                _fail(label, update_path, "must be an object")
            update_type = raw_update.get("type")
            if not isinstance(update_type, str) or update_type not in UPDATE_SCHEMAS:
                _fail(label, f"{update_path}.type", "must be a current update type")
            if update_type not in ACTION_UPDATE_TYPES[action]:
                _fail(label, f"{update_path}.type", f"is invalid for action {action}")
            update_types.append(update_type)
            schema = {"type": "string", **UPDATE_SCHEMAS[update_type]}
            _validate_typed_object(raw_update, schema, label, update_path)
            if raw_update["type"] != update_type:
                raise AssertionError("validated update type changed")
        for required_type in REQUIRED_SINGLE_UPDATE_TYPES[action]:
            if update_types.count(required_type) != 1:
                _fail(
                    label,
                    f"{path}.updates",
                    f"must contain exactly one {required_type}",
                )
        for optional_type in OPTIONAL_SINGLE_UPDATE_TYPES.get(action, set()):
            if update_types.count(optional_type) > 1:
                _fail(
                    label,
                    f"{path}.updates",
                    f"must contain at most one {optional_type}",
                )

        _validate_typed_object(record["state"], STATE_FIELDS, label, f"{path}.state")
        if record["state"]["is_settled"] not in {"0", "1"}:
            _fail(label, f"{path}.state.is_settled", "must equal '0' or '1'")

    if observed != derived_observed:
        _fail(label, "$.scenario.observed_actions", "does not match record actions")
    missing = [action for action in REQUIRED_ACTIONS if action not in derived_observed]
    if missing:
        _fail(label, "$.records", f"missing required actions: {','.join(missing)}")


def first_difference(left: Any, right: Any, path: str = "$") -> str | None:
    if type(left) is not type(right):
        return f"{path}: types differ ({type(left).__name__} != {type(right).__name__})"
    if isinstance(left, dict):
        if left.keys() != right.keys():
            return f"{path}: keys differ ({sorted(left)} != {sorted(right)})"
        for key in left:
            difference = first_difference(left[key], right[key], f"{path}.{key}")
            if difference is not None:
                return difference
        return None
    if isinstance(left, list):
        if len(left) != len(right):
            return f"{path}: lengths differ ({len(left)} != {len(right)})"
        for index, (left_item, right_item) in enumerate(zip(left, right, strict=True)):
            difference = first_difference(left_item, right_item, f"{path}[{index}]")
            if difference is not None:
                return difference
        return None
    if left != right:
        return f"{path}: values differ ({left!r} != {right!r})"
    return None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("local_data", type=Path)
    parser.add_argument("python_data", type=Path)
    args = parser.parse_args()

    local_payload = json.loads(args.local_data.read_text())
    python_payload = json.loads(args.python_data.read_text())
    validate_economic_payload(local_payload, "local")
    validate_economic_payload(python_payload, "python")
    local = parity_projection(local_payload)
    python = parity_projection(python_payload)
    difference = first_difference(local, python)
    if difference is not None:
        raise SystemExit(f"Parity mismatch: {difference}")


if __name__ == "__main__":
    main()
