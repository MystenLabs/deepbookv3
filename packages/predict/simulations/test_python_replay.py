import sys
import unittest
from pathlib import Path

SIMULATIONS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SIMULATIONS_DIR))

import python_replay as replay


class NetPremiumParityTests(unittest.TestCase):
    def test_fractional_leverage_rounds_net_premium_up(self) -> None:
        entry_probability = 100_000_000
        quantity = 1_000_000_000
        entry_value = 100_000_000
        leverage = 1_500_000_000

        # ceil(100_000_000 / 1.5) = 66_666_667.
        terms = replay.compute_mint_terms(entry_probability, quantity, leverage)
        self.assertEqual(terms["entry_exposure_value"], entry_value)
        self.assertEqual(
            terms["contribution"],
            66_666_667,
        )


if __name__ == "__main__":
    unittest.main()
