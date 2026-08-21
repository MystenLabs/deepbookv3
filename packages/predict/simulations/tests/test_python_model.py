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

        # 500,000 DUSDC at a 0.1% supply fee mints 499,500 PLP. The separate
        # 10-DUSDC minimum-liquidity lock is included only in total supply.
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


if __name__ == "__main__":
    unittest.main()
