from __future__ import annotations

import copy
import sys
import unittest
from pathlib import Path


SIMULATIONS_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SIMULATIONS_DIR))

import compare_parity as compare


STATE = {
    "account_usdc_balance": "0",
    "account_plp_balance": "0",
    "expiry_cash_balance": "0",
    "inventory_impact_reserve": "0",
    "payout_liability": "0",
    "required_cash": "0",
    "fee_incentive_balance": "0",
    "vault_idle_balance": "0",
    "vault_protocol_reserve_balance": "0",
    "vault_pending_protocol_profit": "0",
    "profit_basis_debits": "0",
    "profit_basis_credits": "0",
    "vault_total_plp_supply": "0",
    "supply_requests_pending": "0",
    "withdraw_requests_pending": "0",
    "is_settled": "0",
    "active_market_count": "1",
}
ORACLE_INPUT = {
    "spot": "1",
    "forward": "1",
    "a": "1",
    "a_negative": False,
    "b": "1",
    "rho": "1",
    "rho_negative": False,
    "m": "1",
    "m_negative": False,
    "sigma": "1",
    "risk_free_rate": "1",
}


def decimal_update(update_type: str, fields: list[str]) -> dict[str, object]:
    return {"type": update_type, **{field: "0" for field in fields}}


def record(step: int, action: str) -> dict[str, object]:
    extra_updates: list[dict[str, object]] = []
    if action == "mint":
        input_value = {
            **ORACLE_INPUT,
            "order_ref": "order",
            "lower_tick": "0",
            "higher_tick": "1",
            "quantity": "1",
        }
        update = decimal_update(
            "order_minted",
            [
                "order_sequence",
                "lower_tick",
                "higher_tick",
                "entry_probability",
                "quantity",
                "premium",
                "trading_fee",
                "fee_incentive_subsidy",
                "builder_fee",
                "penalty_fee",
                "referral_fee",
                "inventory_impact_charge",
                "onchain_timestamp_ms",
                "pyth_spot_source_timestamp_ms",
                "block_scholes_spot_source_timestamp_ms",
                "block_scholes_forward_source_timestamp_ms",
                "block_scholes_svi_source_timestamp_ms",
            ],
        )
        update["order_ref"] = "order"
    elif action == "redeem_live":
        input_value = {
            **ORACLE_INPUT,
            "order_ref": "order",
            "close_quantity": "1",
            "replacement_order_ref": None,
        }
        update = decimal_update(
            "live_order_redeemed",
            [
                "order_sequence",
                "quantity_closed",
                "remaining_quantity",
                "redeem_amount",
                "trading_fee",
                "builder_fee",
                "penalty_fee",
                "inventory_impact_rebate",
                "onchain_timestamp_ms",
                "pyth_spot_source_timestamp_ms",
                "block_scholes_spot_source_timestamp_ms",
                "block_scholes_forward_source_timestamp_ms",
                "block_scholes_svi_source_timestamp_ms",
            ],
        )
        update.update(
            {
                "order_ref": "order",
                "replacement_order_ref": None,
                "replacement_order_sequence": None,
            }
        )
    elif action == "request_supply":
        input_value = {"amount": "1", "min_output": "0", "lp_ref": "supply"}
        update = decimal_update(
            "supply_requested",
            ["index", "amount", "min_output", "requests_pending_after"],
        )
        update["lp_ref"] = "supply"
    elif action == "request_withdraw":
        input_value = {"shares": "1", "min_output": "0", "lp_ref": "withdraw"}
        update = decimal_update(
            "withdraw_requested",
            ["index", "amount", "min_output", "requests_pending_after"],
        )
        update["lp_ref"] = "withdraw"
    elif action == "flush":
        input_value = {}
        update = decimal_update(
            "flush_executed",
            [
                "pool_value",
                "total_supply",
                "supply_fee_rate",
                "withdraw_fee_rate",
                "active_market_nav",
                "market_count",
                "idle_balance_before",
                "supplies_filled",
                "withdrawals_filled",
                "requests_processed",
                "idle_balance_after",
                "total_supply_after",
            ],
        )
    elif action == "rebalance_expiry_cash":
        input_value = {}
        update = decimal_update(
            "expiry_cash_rebalanced",
            ["amount", "target_cash", "protocol_profit_realized"],
        )
        update["to_expiry"] = True
    elif action == "settle":
        input_value = {"settlement_price": "1"}
        update = decimal_update(
            "market_settled",
            ["settlement_price", "settlement_source", "onchain_timestamp_ms"],
        )
        extra_updates = [
            decimal_update(
                "expiry_cash_received",
                ["settlement_price", "amount"],
            )
        ]
    else:
        input_value = {"order_ref": "order", "permissionless": False}
        update = decimal_update(
            "settled_order_redeemed",
            ["order_sequence", "payout_amount", "onchain_timestamp_ms"],
        )
        update["order_ref"] = "order"
    return {
        "step": step,
        "action": action,
        "input": input_value,
        "updates": [update, *extra_updates],
        "state": copy.deepcopy(STATE),
    }


def current_payload() -> dict[str, object]:
    payload = {
        "schema_version": compare.ECONOMIC_SCHEMA_VERSION,
        "scenario": {
            "quantity_scale": "1",
            "required_actions": list(compare.REQUIRED_ACTIONS),
            "observed_actions": list(compare.REQUIRED_ACTIONS),
        },
        "records": [],
    }
    settled_modes = iter(compare.EXPECTED_SETTLED_REDEMPTION_MODES)
    for step, action in enumerate(compare.EXPECTED_ACTION_SEQUENCE, start=1):
        item = record(step, action)
        if action == "redeem_settled":
            item["input"]["permissionless"] = next(settled_modes)
        payload["records"].append(item)
    payload["scenario"]["observed_actions"] = list(
        dict.fromkeys(compare.EXPECTED_ACTION_SEQUENCE)
    )
    return payload


class ParityArtifactValidationTests(unittest.TestCase):
    def test_accepts_exact_current_schema_and_action_coverage(self) -> None:
        compare.validate_economic_payload(current_payload(), "local")

    def test_rejects_stale_economic_schema(self) -> None:
        payload = current_payload()
        payload["schema_version"] = "predict_economic_v4"

        with self.assertRaisesRegex(SystemExit, "unsupported economic schema"):
            compare.validate_economic_payload(payload, "local")

    def test_rejects_self_declared_action_coverage_without_records(self) -> None:
        payload = copy.deepcopy(current_payload())
        payload["records"] = payload["records"][:-1]

        with self.assertRaisesRegex(SystemExit, "must contain exactly 20 scenario steps"):
            compare.validate_economic_payload(payload, "python")

    def test_rejects_truncated_scenario_after_all_action_names_appear(self) -> None:
        payload = copy.deepcopy(current_payload())
        payload["records"] = payload["records"][:14]
        payload["scenario"]["observed_actions"] = list(
            dict.fromkeys(record["action"] for record in payload["records"])
        )

        with self.assertRaisesRegex(SystemExit, "must contain exactly 20 scenario steps"):
            compare.validate_economic_payload(payload, "local")

    def test_rejects_empty_records_and_missing_or_unknown_fields(self) -> None:
        empty = copy.deepcopy(current_payload())
        empty["records"] = []
        missing = copy.deepcopy(current_payload())
        del missing["scenario"]["quantity_scale"]
        unknown = copy.deepcopy(current_payload())
        unknown["records"][0]["state"]["shadow_balance"] = "0"

        for payload, message in (
            (empty, "must be a non-empty array"),
            (missing, "missing=quantity_scale"),
            (unknown, "unknown=shadow_balance"),
        ):
            with self.subTest(message=message), self.assertRaisesRegex(SystemExit, message):
                compare.validate_economic_payload(payload, "local")

    def test_rejects_wrong_nested_types_and_update_for_wrong_action(self) -> None:
        wrong_type = copy.deepcopy(current_payload())
        wrong_type["records"][0]["input"]["a_negative"] = "false"
        wrong_update = copy.deepcopy(current_payload())
        wrong_update["records"][0]["updates"] = copy.deepcopy(
            wrong_update["records"][2]["updates"]
        )

        with self.assertRaisesRegex(SystemExit, "must be boolean"):
            compare.validate_economic_payload(wrong_type, "local")
        with self.assertRaisesRegex(SystemExit, "invalid for action mint"):
            compare.validate_economic_payload(wrong_update, "local")

    def test_rejects_incomplete_or_duplicated_settlement_accounting(self) -> None:
        missing_cash = copy.deepcopy(current_payload())
        settle = missing_cash["records"][12]
        settle["updates"] = [
            update for update in settle["updates"] if update["type"] != "expiry_cash_received"
        ]
        duplicate_profit = copy.deepcopy(current_payload())
        settle = duplicate_profit["records"][12]
        profit = decimal_update(
            "expiry_profit_materialized",
            [
                "lp_profit",
                "protocol_profit",
                "protocol_reserve_balance_after",
                "profit_basis_after",
                "pending_protocol_profit_after",
            ],
        )
        settle["updates"].extend([profit, copy.deepcopy(profit)])

        with self.assertRaisesRegex(SystemExit, "exactly one expiry_cash_received"):
            compare.validate_economic_payload(missing_cash, "local")
        with self.assertRaisesRegex(SystemExit, "at most one expiry_profit_materialized"):
            compare.validate_economic_payload(duplicate_profit, "python")


if __name__ == "__main__":
    unittest.main()
