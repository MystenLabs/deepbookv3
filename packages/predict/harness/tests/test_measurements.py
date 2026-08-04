from __future__ import annotations

import unittest

from harness import measurements


class MeasurementTests(unittest.TestCase):
    def test_gas_by_moneyness_buckets_mints_only(self) -> None:
        records = [
            {"type": "mint", "moneyness": 1.0, "gas": 10},
            {"type": "mint", "moneyness": 1.01, "gas": 20},
            {"type": "mint", "moneyness": 1.03, "gas": 30},
            {"type": "mint", "moneyness": 1.08, "gas": 40},
            {"type": "redeem", "moneyness": 1.0, "gas": 50},
        ]
        self.assertEqual(
            measurements.gas_by_moneyness(records),
            {
                "ATM (<0.5%)": [10],
                "near (0.5-2%)": [20],
                "far (2-5%)": [30],
                "deep (>5%)": [40],
            },
        )

    def test_nav_summary_uses_timestamp_order_and_peak_drawdown(self) -> None:
        summary = measurements.nav_summary(
            [
                {"type": "flush", "ts": 3, "poolValue": 90},
                {"type": "flush", "ts": 1, "poolValue": 100},
                {"type": "flush", "ts": 2, "poolValue": 120},
            ]
        )
        self.assertEqual(summary["count"], 3)
        self.assertEqual(summary["first"], 100)
        self.assertEqual(summary["last"], 90)
        self.assertAlmostEqual(summary["max_drawdown"], 0.25)

    def test_batch_computation_groups_profiles_and_oog_sizes(self) -> None:
        samples, oogs = measurements.batch_computation(
            [
                {"type": "mintBatch", "profile": "single", "n": 2, "compGas": 10},
                {"type": "mintBatch", "profile": "single", "n": 2, "compGas": 14},
                {"type": "mintBatch", "profile": "pool", "n": 8, "oog": True},
            ]
        )
        self.assertEqual(samples, [("single", 2, 12, 2)])
        self.assertEqual(oogs, [("pool", 8)])


if __name__ == "__main__":
    unittest.main()
