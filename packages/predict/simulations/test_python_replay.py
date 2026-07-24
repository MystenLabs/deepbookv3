import sys
import unittest
from pathlib import Path

SIMULATIONS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SIMULATIONS_DIR))

import python_replay as replay


class MoneyKernelParityTests(unittest.TestCase):
    def test_stake_discount_uses_the_staged_floor_complement(self) -> None:
        benefit = replay.stake_benefit_ratio(
            73_000_001,
            100_000_003,
            300_000_011,
        )
        discount = replay.deepbook_mul(benefit, 250_000_000)

        self.assertEqual(
            replay.fee_amount_after_discount(
                17_000_003,
                73_000_001,
                100_000_003,
                300_000_011,
                250_000_000,
            ),
            replay.fee_after_discount_fraction(17_000_003, discount),
        )

    def test_builder_fee_floors_both_caps_before_minimum(self) -> None:
        self.assertEqual(
            replay.builder_fee_amount(
                17_000_003,
                31_000_009,
                True,
                200_000_000,
                50_000_000,
            ),
            min(
                replay.deepbook_mul(17_000_003, 200_000_000),
                replay.deepbook_mul(31_000_009, 50_000_000),
            ),
        )

    def test_lp_quotes_share_the_fused_floor_kernel(self) -> None:
        self.assertEqual(
            replay.quote_supply_shares(
                5_000_003,
                500_000_000_000,
                499_999_999_937,
            ),
            replay.mul_div_round_down(
                5_000_003,
                500_000_000_000,
                499_999_999_937,
            ),
        )
        self.assertEqual(
            replay.quote_withdraw_dusdc(
                5_000_003,
                499_999_999_911,
                500_000_000_000,
            ),
            replay.mul_div_round_down(
                5_000_003,
                499_999_999_911,
                500_000_000_000,
            ),
        )


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


class SharedBoundaryNavParityTests(unittest.TestCase):
    def test_shared_boundary_center_is_not_per_order_floor_sum(self) -> None:
        orders = [
            {
                "lower": 100,
                "higher": 200,
                "quantity": 1,
            },
            {
                "lower": 100,
                "higher": 300,
                "quantity": 1,
            },
        ]
        prices = {
            100: 500_000_001,
            200: 333_333_333,
            300: 123_456_789,
        }

        shared = replay.shared_boundary_linear(orders, prices)
        per_order = (
            (prices[100] - prices[200]) // replay.FLOAT_SCALING
            + (prices[100] - prices[300]) // replay.FLOAT_SCALING
        )

        self.assertEqual(shared, 1)
        self.assertEqual(per_order, 0)


if __name__ == "__main__":
    unittest.main()
