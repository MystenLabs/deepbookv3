from __future__ import annotations

import math
import sys
import unittest
from pathlib import Path

SIMULATIONS_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SIMULATIONS_DIR))

import python_replay as replay
from python_indexes.strike_payout_tree import StrikePayoutTree


class PayoutTreeTests(unittest.TestCase):
    def test_quantity_only_ranges_reserve_and_settle_exactly(self) -> None:
        tree = StrikePayoutTree(tick_size=100, pos_inf_tick=1_000)
        tree.insert_range(0, 10, 40)
        tree.insert_range(5, 1_000, 70)

        # Below tick 5 only the DOWN range pays 40; between ticks 5 and 10 both
        # pay 110; above tick 10 only the UP range pays 70.
        self.assertEqual(tree.payout_reserve_terms(), (110, 110))
        self.assertEqual(tree.settled_payout_liability(499), 40)
        self.assertEqual(tree.settled_payout_liability(500), 40)
        self.assertEqual(tree.settled_payout_liability(501), 110)
        self.assertEqual(tree.settled_payout_liability(1_000), 110)
        self.assertEqual(tree.settled_payout_liability(1_001), 70)

        tree.remove_range(5, 1_000, 70)
        self.assertEqual(tree.payout_reserve_terms(), (40, 40))


class BootstrapAccountingTests(unittest.TestCase):
    def test_configured_supply_fee_is_applied_to_bootstrap_shares(self) -> None:
        replay.apply_scenario_config(replay.load_scenario_config())
        state = replay.initial_state()

        # 500,000 USDC at a 0.1% supply fee mints 499,500 PLP. The separate
        # 10-USDC minimum-liquidity lock is included only in total supply.
        self.assertEqual(state["account_plp_balance"], 499_500_000_000)
        self.assertEqual(state["vault_total_plp_supply"], 499_510_000_000)
        self.assertEqual(state["vault_idle_balance"], 450_010_000_000)

    def test_svi_rolls_from_publish_time_to_pricing_time_at_1e18(self) -> None:
        svi = replay.pricing_svi(
            {
                "a": 3,
                "aNegative": False,
                "b": 5,
                "rho": 0,
                "rhoNegative": False,
                "m": 0,
                "mNegative": False,
                "sigma": 1,
                "riskFreeRate": 0,
                "expiryMs": 1_000,
                "pricingTimestampMs": 800,
                "sviSourceTimestampMs": 600,
            }
        )

        # Remaining time is 200ms from a 400ms publish-time anchor, exactly 1/2.
        self.assertEqual(svi["a"], 1_500_000_000)
        self.assertEqual(svi["b"], 2_500_000_000)
        self.assertTrue(svi["at1e18"])


class ScenarioParserTests(unittest.TestCase):
    def test_partial_oracle_refresh_with_only_a_sign_is_rejected(self) -> None:
        row = {column: "" for column in replay.SCENARIO_COLUMNS}
        row.update({"tx": "1", "action": "flush", "a_negative": "true"})
        text = ",".join(replay.SCENARIO_COLUMNS) + "\n" + ",".join(
            row[column] for column in replay.SCENARIO_COLUMNS
        )

        with self.assertRaisesRegex(ValueError, "oracle refresh fields must all be present"):
            replay.parse_scenario_text(text)


class RangeFeeTests(unittest.TestCase):
    def setUp(self) -> None:
        config = replay.load_scenario_config()
        config["protocol"].update(base_fee="100000000", min_fee="22000000")
        replay.apply_scenario_config(config)

    def tearDown(self) -> None:
        replay.apply_scenario_config(replay.load_scenario_config())

    def test_finite_legs_and_sentinels_have_independent_fees(self) -> None:
        # At p=1/2 the rate is 0.05; finite endpoints pay the 0.022 floor.
        for prices, expected in [
            ((500_000_000, None), 50_000_000),
            ((None, 500_000_000), 50_000_000),
            ((None, None), 0),
            ((1_000_000_000, 0), 44_000_000),
            ((500_000_000, 0), 72_000_000),
        ]:
            with self.subTest(prices=prices):
                self.assertEqual(replay.range_trading_fee(prices, 1_000_000_000, None), expected)

    def test_floor_amounts_round_before_summing_and_after_ramp(self) -> None:
        # Each 0.022 * 75 floors to 1. At 1.5x, each 0.033 * 75 floors to 2.
        self.assertEqual(replay.range_trading_fee((1_000_000_000, 0), 75, None), 2)
        self.assertEqual(replay.range_trading_fee((1_000_000_000, 0), 75, replay.EXPIRY_FEE_WINDOW_MS // 2), 4)

    def test_individual_legs_and_upper_below_must_be_eligible(self) -> None:
        for prices in [(1_000_000_000, 500_000_000), (500_000_000, 0)]:
            with self.subTest(prices=prices), self.assertRaisesRegex(ValueError, "entry probability"):
                replay.assert_range_entry_bounds(prices)
        replay.MAX_ENTRY_PROBABILITY = 600_000_000
        with self.assertRaisesRegex(ValueError, "entry probability"):
            replay.assert_range_entry_bounds((550_000_000, 200_000_000))

    def test_finite_range_decodes_both_ticks_and_rejects_inverted_bounds(self) -> None:
        row = {"strike": 100_000_000_000, "isUp": True, "higherStrike": 110_000_000_000}
        self.assertEqual(replay.mint_range_ticks(row), (100, 110))
        with self.assertRaisesRegex(ValueError, "requires is_up"):
            replay.mint_range_ticks({**row, "isUp": False})
        with self.assertRaisesRegex(ValueError, "must exceed"):
            replay.mint_range_ticks({**row, "higherStrike": row["strike"]})
        with self.assertRaisesRegex(ValueError, "whole tick"):
            replay.mint_range_ticks({**row, "higherStrike": row["higherStrike"] + 1})
        with self.assertRaisesRegex(ValueError, "must be finite"):
            replay.mint_range_ticks({**row, "higherStrike": replay.POS_INF_TICK * replay.ORACLE_TICK_SIZE})

    def test_eligible_range_above_maximum_payout_refunds_without_mutating_the_book(self) -> None:
        replay.INVENTORY_IMPACT_MAX_RATE = 0
        model, state = queued_market(expiry_ms=200_000_000, svi_source_ms=120_000)
        row = mint_row(
            "wide", strike=60_000_000_000, higher_strike=140_000_000_000, quantity=1_000_000_000
        )
        before = dict(state)
        record_id, _ = replay.enqueue_mint(model, state, row)
        # Flat variance 0.04 gives ~96.26% range probability. Two 2.2% floors exceed the
        # remaining payout even though both legs pass admission, so resolve refunds it on
        # admission (reason 2) and keeps the order fee.
        updates = replay.commit_and_resolve(model, state, record_id, 90_000_000_000, 120_000)

        self.assertEqual([update["type"] for update in updates], ["queued_order_refunded"])
        self.assertEqual(updates[0]["reason"], "2")
        self.assertEqual(state["account_usdc_balance"], before["account_usdc_balance"] - replay.ORDER_FEE)
        self.assertEqual(state["expiry_cash_balance"], before["expiry_cash_balance"] + replay.ORDER_FEE)
        self.assertEqual(model["orders"], {})
        self.assertEqual(model["next_order_sequence"], 0)
        self.assertEqual(model["tree"].payout_reserve_terms(), (0, 0))


# A market with a flat-variance surface (b = 0, a = 0.04 at its source time), so a digital's
# probability is the plain N(d2) of the rolled variance.
def queued_market(
    expiry_ms: int = 10_000_000,
    svi_source_ms: int = 0,
) -> tuple[dict, dict]:
    model = replay.initial_model(expiry_ms)
    state = replay.initial_state()
    model["last_oracle"] = {
        "spot": 90_000_000_000, "forward": 90_000_000_000,
        "a": 40_000_000, "aNegative": False, "b": 0,
        "rho": 0, "rhoNegative": False, "m": 0, "mNegative": False,
        "sigma": 100_000_000, "riskFreeRate": 0,
        "expiryMs": expiry_ms, "pricingTimestampMs": svi_source_ms,
        "sviSourceTimestampMs": svi_source_ms, "priceSourceTimestampMs": svi_source_ms,
    }
    return model, state


def mint_row(
    order_ref: str,
    *,
    strike: int = 90_000_000_000,
    higher_strike: int | None = None,
    quantity: int = 1_000_000_000,
    max_probability: int | None = None,
) -> dict:
    return {
        "orderRef": order_ref, "strike": strike, "isUp": True, "higherStrike": higher_strike,
        "quantity": quantity, "maxProbability": max_probability, "commitSpot": 90_000_000_000,
    }


def normal_cdf(x: float) -> float:
    return 0.5 * (1 + math.erf(x / math.sqrt(2)))


class QueuedExecutionTests(unittest.TestCase):
    def setUp(self) -> None:
        replay.apply_scenario_config(replay.load_scenario_config())

    def tearDown(self) -> None:
        replay.apply_scenario_config(replay.load_scenario_config())

    def test_cash_needs_bound_the_worst_fill(self) -> None:
        # min_entry_probability 1%: ceil(q * 0.99) + 1. lambda 25%: ceil(q * 0.75) + 1.
        self.assertEqual(replay.cash_need_exact_quantity(1_000_000_000), 990_000_001)
        self.assertEqual(replay.cash_need_exact_quantity(3), 4)  # ceil(2.97) + 1
        self.assertEqual(replay.cash_need_sell(1_000_000_000), 750_000_001)
        self.assertEqual(replay.cash_need_sell(3), 4)  # ceil(2.25) + 1

    def test_tick_pricer_reanchors_the_forward_and_rolls_the_snapshot_to_the_tick(self) -> None:
        record = {"vol": {
            "spot": 100_000_000_000, "forward": 101_000_000_000,
            "a": 3, "aNegative": False, "b": 5, "rho": 0, "rhoNegative": False,
            "m": 0, "mNegative": False, "sigma": 1, "riskFreeRate": 0,
            "expiryMs": 1_000, "pricingTimestampMs": 600, "sviSourceTimestampMs": 600,
        }}
        oracle = replay.tick_oracle(record, 110_000_000_000, 800)

        # 110 * 101 / 100 = 111.1, and 200 ms left of a 400 ms anchor halves a and b.
        self.assertEqual(oracle["forward"], 111_100_000_000)
        svi = replay.pricing_svi(oracle)
        self.assertEqual((svi["a"], svi["b"]), (1_500_000_000, 2_500_000_000))
        self.assertIsNone(replay.tick_oracle(record, 110_000_000_000, 1_000))

    def test_fill_prices_at_the_committed_tick_and_pays_from_escrow(self) -> None:
        model, state = queued_market()
        before = dict(state)
        record_id, enqueued = replay.enqueue_mint(model, state, mint_row("atm"))

        # Enqueue escrows the whole quantity as budget plus the 0.02 USDC order fee.
        self.assertEqual(enqueued[0]["budget"], "1000000000")
        self.assertEqual(enqueued[0]["order_fee"], "20000")
        self.assertEqual(state["account_usdc_balance"], before["account_usdc_balance"] - 1_000_020_000)
        self.assertEqual(state["waiting_cash_need"], 990_000_001)

        updates = replay.commit_and_resolve(model, state, record_id, 90_000_000_000, 5_000_000)
        minted, filled = updates
        # At the tick half the anchored time remains, so w = 0.02 and an at-the-money UP pays
        # N(-sqrt(0.02) / 2). Priced at placement (w = 0.04) it would be N(-0.1), about 0.4602.
        expected = normal_cdf(-math.sqrt(0.02) / 2)
        self.assertAlmostEqual(int(minted["entry_probability"]) / 1e9, expected, delta=1e-6)
        all_in = int(filled["amount"])
        self.assertEqual(
            all_in,
            int(minted["premium"]) + int(minted["trading_fee"]) + int(minted["inventory_impact_charge"]),
        )
        # The trader pays the all-in cost and the order fee, and unused budget comes back.
        self.assertEqual(
            state["account_usdc_balance"],
            before["account_usdc_balance"] - all_in - replay.ORDER_FEE,
        )
        self.assertEqual(
            state["expiry_cash_balance"],
            before["expiry_cash_balance"] + all_in + replay.ORDER_FEE,
        )
        self.assertEqual(model["records"][record_id]["status"], replay.STATUS_OPEN)
        self.assertEqual((state["waiting_cash_need"], state["pending_mints"]), (0, 0))
        self.assertEqual(filled["position_quantity"], "1000000000")

    def test_order_fee_is_kept_on_reasons_1_and_2_and_returned_otherwise(self) -> None:
        for reason, kept in ((1, True), (2, True), (5, False), (7, False), (8, False)):
            with self.subTest(reason=reason):
                model, state = queued_market()
                before = dict(state)
                record_id, _ = replay.enqueue_mint(model, state, mint_row("order"))
                record = model["records"][record_id]
                [update] = replay.refund_record(model, state, record, reason, 1)

                fee = replay.ORDER_FEE
                self.assertEqual(update["escrow_returned"], "1000000000")
                self.assertEqual(update["order_fee_returned"], "0" if kept else str(fee))
                self.assertEqual(
                    state["account_usdc_balance"],
                    before["account_usdc_balance"] - (fee if kept else 0),
                )
                self.assertEqual(
                    state["expiry_cash_balance"],
                    before["expiry_cash_balance"] + (fee if kept else 0),
                )
                self.assertEqual(record["status"], replay.STATUS_REFUNDED)
                self.assertEqual((state["waiting_cash_need"], state["pending_mints"]), (0, 0))

    def test_tick_refunds_report_the_reason_the_fill_failed_on(self) -> None:
        cases = (
            # A committed spot ten times the forward saturates the UP leg at 1, outside the
            # 1%-99% entry band: admission.
            ("saturated", None, 900_000_000_000, "2"),
            # About 47% at the tick, above a 40% cap: the order's own limit.
            ("capped", 400_000_000, 90_000_000_000, "1"),
        )
        for order_ref, cap, commit_spot, reason in cases:
            with self.subTest(order_ref=order_ref):
                model, state = queued_market()
                record_id, _ = replay.enqueue_mint(
                    model, state, mint_row(order_ref, max_probability=cap)
                )
                updates = replay.commit_and_resolve(model, state, record_id, commit_spot, 5_000_000)

                self.assertEqual(updates[0]["type"], "queued_order_refunded")
                self.assertEqual(updates[0]["reason"], reason)
                self.assertEqual(model["next_order_sequence"], 0)
                self.assertEqual(model["tree"].payout_reserve_terms(), (0, 0))

    def test_sell_moves_the_position_into_its_record_and_keeps_the_remainder_open(self) -> None:
        model, state = queued_market()
        source_id, _ = replay.enqueue_mint(model, state, mint_row("pos"))
        replay.commit_and_resolve(model, state, source_id, 90_000_000_000, 4_000_000)
        before = dict(state)

        sell = {"orderRef": "pos", "closeQuantity": 400_000_000}
        sell_id, enqueued = replay.enqueue_redeem_open(model, state, sell)
        self.assertEqual(enqueued[0]["source_record_id"], str(source_id))
        self.assertEqual(enqueued[0]["budget"], "0")
        self.assertEqual(model["records"][source_id]["status"], replay.STATUS_CLOSED)
        self.assertEqual(model["orders"]["pos"]["record_id"], sell_id)

        redeemed, filled = replay.commit_and_resolve(model, state, sell_id, 90_000_000_000, 5_000_000)
        proceeds = int(redeemed["redeem_amount"]) + int(redeemed["inventory_impact_rebate"]) - int(redeemed["trading_fee"])
        self.assertEqual(filled["amount"], str(proceeds))
        self.assertEqual(redeemed["remaining_quantity"], "600000000")
        self.assertEqual(redeemed["replacement_order_sequence"], "1")
        self.assertEqual(filled["position_quantity"], "600000000")
        self.assertEqual(
            state["account_usdc_balance"],
            before["account_usdc_balance"] - replay.ORDER_FEE + proceeds,
        )
        self.assertEqual(model["records"][sell_id]["status"], replay.STATUS_OPEN)
        self.assertEqual(model["orders"]["pos"]["quantity"], 600_000_000)

    def test_try_settle_settles_alone_and_the_queue_walk_refunds_pays_and_cleans_up(self) -> None:
        model, state = queued_market()
        # Two Open positions: DOWN below tick 100 (2 USDC) and UP above it (3 USDC), and one
        # mint still waiting with 5 USDC of budget.
        for record_id, (order_ref, lower, higher, quantity) in enumerate(
            (("down", 0, 100, 2_000_000), ("up", 100, replay.POS_INF_TICK, 3_000_000))
        ):
            model["tree"].insert_range(lower, higher, quantity)
            model["orders"][order_ref] = {
                "lower_tick": lower, "higher_tick": higher, "quantity": quantity,
                "sequence": record_id, "record_id": record_id,
            }
            model["records"][record_id] = {
                "record_id": record_id, "order_ref": order_ref, "kind": 0,
                "status": replay.STATUS_OPEN, "budget": 0, "order_fee": 20_000, "cash_need": 0,
            }
        model["records"][2] = {
            "record_id": 2, "order_ref": "wait", "kind": 0, "status": replay.STATUS_PENDING,
            "budget": 5_000_000, "order_fee": 20_000, "cash_need": 7,
        }
        state.update(queue_next_id=3, waiting_cash_need=7, pending_mints=1)
        account, cash = state["account_usdc_balance"], state["expiry_cash_balance"]

        # Predict's try_settle reads nothing from the queue: the waiting mint keeps waiting.
        settled = replay.settle_market(model, state, {"settlementPrice": 90_000_000_000}, 1)
        self.assertEqual([u["type"] for u in settled], ["market_settled"])
        self.assertEqual(state["account_usdc_balance"], account)
        self.assertEqual((state["pending_mints"], state["waiting_cash_need"]), (1, 7))
        self.assertEqual(model["settled_liability"], 2_000_000)

        # The walk refunds the waiting mint in full (budget and the 0.02 USDC order fee), then
        # pays the DOWN winner 2 USDC and the UP loser 0, then deletes all three records.
        walked = replay.settle_payout(model, state, 2)
        self.assertEqual(
            [(u["type"], u.get("order_ref"), u.get("reason"), u.get("payout")) for u in walked],
            [
                ("queued_order_refunded", "wait", "5", None),
                ("open_record_settled", "down", None, "2000000"),
                ("open_record_settled", "up", None, "0"),
                ("market_payouts_completed", None, None, None),
                ("queued_orders_cleaned", None, None, None),
            ],
        )
        self.assertEqual(walked[-1]["record_ids"], ["0", "1", "2"])
        self.assertEqual(state["account_usdc_balance"], account + 5_020_000 + 2_000_000)
        self.assertEqual(state["expiry_cash_balance"], cash - 2_000_000)
        self.assertEqual((state["pending_mints"], state["waiting_cash_need"]), (0, 0))
        self.assertEqual((state["payout_cursor"], model["settled_liability"]), (3, 0))
        self.assertEqual(model["records"], {})

        swept = replay.rebalance_expiry(model, state, 3)
        self.assertEqual(swept[0]["type"], "expiry_cash_received")
        self.assertEqual(swept[0]["amount"], str(cash - 2_000_000))
        self.assertEqual((state["expiry_cash_balance"], state["active_market_count"]), (0, 0))

    def test_live_rebalance_funds_the_waiting_cash_need(self) -> None:
        model, state = queued_market()
        state["waiting_cash_need"] = 60_000_000_000
        # Nothing is live, so required cash is zero: the target is the 60k waiting need, above
        # the 50k initial cash, and the pool tops the market up by the 10k difference.
        [update] = replay.rebalance_expiry(model, state, 1)
        self.assertEqual(
            (update["amount"], update["to_expiry"], update["target_cash"]),
            ("10000000000", True, "60000000000"),
        )


if __name__ == "__main__":
    unittest.main()
