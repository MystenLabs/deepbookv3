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
    "waiting_cash_need": "0",
    "pending_mints": "0",
    "pending_sells": "0",
    "payout_cursor": "0",
    "queue_next_id": "0",
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


def enqueued() -> dict[str, object]:
    update = decimal_update(
        "order_enqueued",
        ["record_id", "kind", "quantity", "budget", "order_fee", "cash_need"],
    )
    update.update(order_ref="order", source_record_id=None)
    return update


def filled() -> dict[str, object]:
    update = decimal_update(
        "queued_order_filled",
        [
            "record_id",
            "kind",
            "quantity",
            "amount",
            "trading_fee",
            "builder_fee",
            "referral_fee",
            "order_fee",
            "subsidy_used",
            "inventory_impact",
            "position_quantity",
            "tau_ms",
            "tick_ms",
            "onchain_timestamp_ms",
        ],
    )
    update["order_ref"] = "order"
    return update


def refunded(reason: str) -> dict[str, object]:
    update = decimal_update(
        "queued_order_refunded",
        [
            "record_id",
            "kind",
            "escrow_returned",
            "order_fee_returned",
            "subsidy_returned",
            "onchain_timestamp_ms",
        ],
    )
    update.update(order_ref="order", reason=reason, position_returned=False)
    return update


def minted() -> dict[str, object]:
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
    return update


def settled_record(payout: str) -> dict[str, object]:
    update = decimal_update(
        "open_record_settled",
        ["record_id", "order_sequence", "onchain_timestamp_ms"],
    )
    update.update(order_ref="order", payout=payout)
    return update


def mint_record(role: str) -> tuple[dict[str, object], list[dict[str, object]]]:
    input_value = {
        **ORACLE_INPUT,
        "order_ref": "order",
        "lower_tick": "0",
        "higher_tick": "1",
        "quantity": "1",
        "max_probability": "1" if role == "limit_refund" else None,
        "commit_spot": None if role == "deadline_refund" else "1",
    }
    if role == "fill":
        return input_value, [enqueued(), minted(), filled()]
    if role == "limit_refund":
        return input_value, [enqueued(), refunded("1")]
    return input_value, [enqueued()]


def record(step: int, action: str, mint_role: str = "fill") -> dict[str, object]:
    if action == "mint":
        input_value, updates = mint_record(mint_role)
    elif action == "redeem_open":
        input_value = {
            **ORACLE_INPUT,
            "order_ref": "order",
            "close_quantity": "1",
            "replacement_order_ref": None,
            "commit_spot": "1",
        }
        redeemed = decimal_update(
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
        redeemed.update(
            order_ref="order", replacement_order_ref=None, replacement_order_sequence=None
        )
        updates = [enqueued(), redeemed, filled()]
    elif action == "request_supply":
        input_value = {"amount": "1", "min_output": "0", "lp_ref": "supply"}
        update = decimal_update(
            "supply_requested",
            ["index", "amount", "min_output", "requests_pending_after"],
        )
        update["lp_ref"] = "supply"
        updates = [update]
    elif action == "request_withdraw":
        input_value = {"shares": "1", "min_output": "0", "lp_ref": "withdraw"}
        update = decimal_update(
            "withdraw_requested",
            ["index", "amount", "min_output", "requests_pending_after"],
        )
        update["lp_ref"] = "withdraw"
        updates = [update]
    elif action == "flush":
        input_value = {}
        updates = [
            decimal_update(
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
        ]
    elif action == "rebalance_expiry_cash":
        input_value = {}
        update = decimal_update(
            "expiry_cash_rebalanced",
            ["amount", "target_cash", "protocol_profit_realized"],
        )
        update["to_expiry"] = True
        updates = [update]
    elif action == "settle":
        input_value = {"settlement_price": "1"}
        updates = [
            decimal_update(
                "market_settled",
                ["settlement_price", "settlement_source", "onchain_timestamp_ms"],
            ),
        ]
    else:
        input_value = {}
        cleaned = decimal_update("queued_orders_cleaned", ["onchain_timestamp_ms"])
        cleaned["record_ids"] = ["0", "1", "2"]
        updates = [
            refunded("5"),
            settled_record("7"),
            settled_record("0"),
            decimal_update("market_payouts_completed", ["onchain_timestamp_ms"]),
            cleaned,
        ]
    return {
        "step": step,
        "action": action,
        "input": input_value,
        "updates": updates,
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
    roles = iter(["fill", "fill", "fill", "fill", "fill", "limit_refund", "deadline_refund"])
    for step, action in enumerate(compare.EXPECTED_ACTION_SEQUENCE, start=1):
        payload["records"].append(
            record(step, action, next(roles) if action == "mint" else "fill")
        )
    payload["scenario"]["observed_actions"] = list(
        dict.fromkeys(compare.EXPECTED_ACTION_SEQUENCE)
    )
    return payload


def records_of(payload: dict[str, object], action: str) -> list[dict[str, object]]:
    return [item for item in payload["records"] if item["action"] == action]


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

    def test_rejects_settlement_without_its_single_settle_event(self) -> None:
        missing = copy.deepcopy(current_payload())
        settle = records_of(missing, "settle")[0]
        settle["updates"] = [
            update for update in settle["updates"] if update["type"] != "market_settled"
        ]
        twice = copy.deepcopy(current_payload())
        settle = records_of(twice, "settle")[0]
        settle["updates"].append(copy.deepcopy(settle["updates"][0]))

        with self.assertRaisesRegex(SystemExit, "must be a non-empty array"):
            compare.validate_economic_payload(missing, "local")
        with self.assertRaisesRegex(SystemExit, "exactly one market_settled"):
            compare.validate_economic_payload(twice, "local")

    def test_settlement_refunds_and_cleanup_belong_to_the_queue_walk(self) -> None:
        # `try_settle` only settles: a refund in the settle row is an unmodeled update there.
        refund_in_settle = copy.deepcopy(current_payload())
        records_of(refund_in_settle, "settle")[0]["updates"].insert(0, refunded("5"))
        # The walk must end in exactly one cleanup of the finished records.
        no_cleanup = copy.deepcopy(current_payload())
        walk = records_of(no_cleanup, "settle_payout")[0]
        walk["updates"] = [
            update for update in walk["updates"] if update["type"] != "queued_orders_cleaned"
        ]
        bad_ids = copy.deepcopy(current_payload())
        records_of(bad_ids, "settle_payout")[0]["updates"][-1]["record_ids"] = ["0", "x"]

        for payload, message in (
            (refund_in_settle, "invalid for action settle"),
            (no_cleanup, "exactly one queued_orders_cleaned"),
            (bad_ids, "must be decimal_list"),
        ):
            with self.subTest(message=message), self.assertRaisesRegex(SystemExit, message):
                compare.validate_economic_payload(payload, "local")

    def test_rejects_a_sell_that_neither_fills_nor_refunds(self) -> None:
        payload = copy.deepcopy(current_payload())
        sell = records_of(payload, "redeem_open")[0]
        sell["updates"] = [update for update in sell["updates"] if update["type"] != "queued_order_filled"]

        with self.assertRaisesRegex(SystemExit, "exactly one of queued_order_filled"):
            compare.validate_economic_payload(payload, "local")

    def test_rejects_a_rebalance_that_both_moves_and_sweeps_cash(self) -> None:
        payload = copy.deepcopy(current_payload())
        rebalance = records_of(payload, "rebalance_expiry_cash")[0]
        rebalance["updates"].append(
            decimal_update("expiry_cash_received", ["settlement_price", "amount"])
        )

        with self.assertRaisesRegex(SystemExit, "exactly one of expiry_cash_rebalanced"):
            compare.validate_economic_payload(payload, "python")

    def test_each_mint_must_show_the_outcome_its_role_covers(self) -> None:
        uncommitted = copy.deepcopy(current_payload())
        records_of(uncommitted, "mint")[-1]["updates"].append(refunded("5"))
        # A fill that became an admission refund matches on both sides but loses the fill.
        refunded_fill = copy.deepcopy(current_payload())
        records_of(refunded_fill, "mint")[0]["updates"] = [enqueued(), refunded("2")]
        filled_probe = copy.deepcopy(current_payload())
        records_of(filled_probe, "mint")[5]["updates"] = [enqueued(), minted(), filled()]
        no_cash_probe = copy.deepcopy(current_payload())
        records_of(no_cash_probe, "mint")[5]["updates"][1]["reason"] = "8"

        for payload, message in (
            (uncommitted, "uncommitted mint must only enqueue"),
            (refunded_fill, "committed mint must fill at its tick"),
            (filled_probe, "capped mint must be refunded at its tick"),
            (no_cash_probe, "capped mint must be refunded at its tick"),
        ):
            with self.subTest(message=message), self.assertRaisesRegex(SystemExit, message):
                compare.validate_economic_payload(payload, "local")

    def test_requires_a_kept_and_a_returned_order_fee(self) -> None:
        only_kept = copy.deepcopy(current_payload())
        records_of(only_kept, "settle_payout")[0]["updates"][0]["reason"] = "1"

        with self.assertRaisesRegex(SystemExit, "kept order fee"):
            compare.validate_economic_payload(only_kept, "local")

    def test_requires_the_payout_walk_to_pay_a_winner_and_a_loser(self) -> None:
        losers_only = copy.deepcopy(current_payload())
        for update in records_of(losers_only, "settle_payout")[0]["updates"]:
            if update["type"] == "open_record_settled":
                update["payout"] = "0"

        with self.assertRaisesRegex(SystemExit, "pay a winner and a loser"):
            compare.validate_economic_payload(losers_only, "python")

    def test_projection_ignores_chain_time_but_not_economics(self) -> None:
        local = current_payload()
        python = copy.deepcopy(local)
        records_of(python, "mint")[0]["updates"][2]["tick_ms"] = "123"
        self.assertIsNone(
            compare.first_difference(
                compare.parity_projection(local), compare.parity_projection(python)
            )
        )
        records_of(python, "mint")[0]["updates"][2]["amount"] = "1"
        self.assertIn(
            "amount",
            compare.first_difference(
                compare.parity_projection(local), compare.parity_projection(python)
            ),
        )


if __name__ == "__main__":
    unittest.main()
