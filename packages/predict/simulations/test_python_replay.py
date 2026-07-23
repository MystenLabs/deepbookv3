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


class LiveForwardParityTests(unittest.TestCase):
    def test_equal_pyth_and_block_scholes_spots_preserve_forward(self) -> None:
        spot = 1_000_000_003
        forward = 1_200_000_007

        self.assertEqual(
            replay.live_forward(spot, forward, spot),
            forward,
        )


class PartialCloseParityTests(unittest.TestCase):
    def test_survivor_uses_one_fused_floor_and_closed_slice_is_complement(self) -> None:
        remaining_quantity, remaining_floor, removed_floor = (
            replay.split_partial_close_floor(
                old_quantity=1_000_000_000,
                old_floor_shares=300_000_001,
                close_quantity=333_330_000,
            )
        )

        self.assertEqual(remaining_quantity, 666_670_000)
        self.assertEqual(remaining_floor, 200_001_000)
        self.assertEqual(removed_floor, 99_999_001)
        self.assertEqual(remaining_floor + removed_floor, 300_000_001)

    def test_one_atom_closed_floor_can_exceed_zero_gross_slice(self) -> None:
        terms = replay.compute_live_close_terms(
            range_probability=58_530,
            old_quantity=200_000_000,
            old_floor_shares=9_950,
            close_quantity=10_000,
        )

        self.assertEqual(terms["gross_redeem_amount"], 0)
        self.assertEqual(terms["remove_floor_shares"], 1)
        self.assertEqual(terms["redeem_amount"], 0)


if __name__ == "__main__":
    unittest.main()
