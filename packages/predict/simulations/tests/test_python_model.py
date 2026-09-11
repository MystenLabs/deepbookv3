from __future__ import annotations

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


if __name__ == "__main__":
    unittest.main()
