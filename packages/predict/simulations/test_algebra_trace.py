#!/usr/bin/env python3
"""Deterministic regression coverage for the Predict algebra lifecycle trace."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import algebra_trace
import python_replay as replay


# The 1e9 tables freeze contract SHA 94758ffd before the retained-1e18
# variance-to-sqrt seam. The accepted tables freeze current contract SHA
# 1a9489f6 after the canonical round-up premium and fee changes. These pin change
# detection only; the committed reference enclosures remain the independent
# mathematical correctness oracle for price containment.
TARGET_94758FFD_1E9_KEY_OUTPUTS = {
    "ordinary_1x": {
        "active_market_nav": (50_000_059_904, 9),
        "floor_shares": (0, 0),
        "liquidation_decision": (0, 0),
        "mint_range_price": (528_329_890, 534),
        "net_premium": (6_339_958, 0),
        "pool_value": (500_000_059_904, 9),
        "redeem_amount": (2_113_319, 0),
        "settlement_winner_payout": (12_000_000, 0),
        "supply_shares": (5_000_099, 0),
        "withdraw_dusdc": (4_999_999, 0),
    },
    "leveraged_boundary": {
        "active_market_nav": (50_000_100_000, 83),
        "floor_shares": (5_989_561, 0),
        "liquidation_decision": (1, 0),
        "mint_range_price": (499_130_082, 1_959),
        "net_premium": (3_993_040, 0),
        "pool_value": (500_000_100_000, 83),
        "redeem_amount": (1_996, 0),
        "settlement_winner_payout": (14_010_439, 0),
        "supply_shares": (5_000_098, 0),
        "withdraw_dusdc": (4_999_999, 0),
    },
    "precision_sensitive": {
        "active_market_nav": (50_000_098_480, 247),
        "floor_shares": (15_788_680, 0),
        "liquidation_decision": (1, 0),
        "mint_range_price": (877_148_869, 4_043),
        "net_premium": (10_525_786, 0),
        "pool_value": (500_000_098_480, 247),
        "redeem_amount": (3_508_594, 0),
        "settlement_winner_payout": (14_211_320, 0),
        "supply_shares": (5_000_099, 0),
        "withdraw_dusdc": (4_999_999, 0),
    },
}

TARGET_94758FFD_1E9_PARITY_VALUES = {
    "ordinary_1x": {
        "LP supply shares": 5_000_099,
        "LP withdraw payout": 4_999_999,
        "live forward": 75_799_394_374_445,
        "mint contribution": 6_339_958,
        "mint entry exposure": 6_339_958,
        "mint floor": 0,
        "mint range price": 528_329_890,
        "mint_lower up price": 528_329_890,
        "partial-close redeem": 2_113_319,
        "partial-close remaining floor": 0,
        "partial-close removed floor": 0,
    },
    "leveraged_boundary": {
        "LP supply shares": 5_000_098,
        "LP withdraw payout": 4_999_999,
        "live forward": 75_044_761_049_821,
        "mint contribution": 3_993_040,
        "mint entry exposure": 9_982_601,
        "mint floor": 5_989_561,
        "mint range price": 499_130_082,
        "mint_lower up price": 499_130_082,
        "partial-close redeem": 1_996,
        "partial-close remaining floor": 5_986_566,
        "partial-close removed floor": 2_995,
    },
    "precision_sensitive": {
        "LP supply shares": 5_000_099,
        "LP withdraw payout": 4_999_999,
        "live forward": 74_212_629_180_749,
        "mint contribution": 10_525_786,
        "mint entry exposure": 26_314_466,
        "mint floor": 15_788_680,
        "mint range price": 877_148_869,
        "mint_lower up price": 877_148_869,
        "partial-close redeem": 3_508_594,
        "partial-close remaining floor": 10_525_786,
        "partial-close removed floor": 5_262_894,
    },
}

ACCEPTED_SQRT_ISLAND_KEY_OUTPUTS = {
    "ordinary_1x": {
        "active_market_nav": (50_000_059_904, 8),
        "floor_shares": (0, 0),
        "liquidation_decision": (0, 0),
        "mint_range_price": (528_329_883, 448),
        "net_premium": (6_339_958, 0),
        "pool_value": (500_000_059_904, 8),
        "redeem_amount": (2_113_319, 0),
        "settlement_winner_payout": (12_000_000, 0),
        "supply_pool_value": (500_000_059_912, 0),
        "supply_shares": (5_000_099, 0),
        "withdraw_dusdc": (4_999_999, 0),
        "withdraw_pool_value": (500_000_059_896, 0),
    },
    "leveraged_boundary": {
        "active_market_nav": (50_000_100_000, 83),
        "floor_shares": (5_989_560, 0),
        "liquidation_decision": (1, 0),
        "mint_range_price": (499_130_085, 1_951),
        "net_premium": (3_993_041, 0),
        "pool_value": (500_000_100_000, 83),
        "redeem_amount": (1_996, 0),
        "settlement_winner_payout": (14_010_440, 0),
        "supply_pool_value": (500_000_100_083, 0),
        "supply_shares": (5_000_098, 0),
        "withdraw_dusdc": (4_999_998, 0),
        "withdraw_pool_value": (500_000_099_917, 0),
    },
    "precision_sensitive": {
        "active_market_nav": (50_000_098_481, 93),
        "floor_shares": (15_788_661, 0),
        "liquidation_decision": (1, 0),
        "mint_range_price": (877_147_899, 1_468),
        "net_premium": (10_525_775, 0),
        "pool_value": (500_000_098_481, 93),
        "redeem_amount": (3_508_591, 0),
        "settlement_winner_payout": (14_211_339, 0),
        "supply_pool_value": (500_000_098_574, 0),
        "supply_shares": (5_000_099, 0),
        "withdraw_dusdc": (4_999_999, 0),
        "withdraw_pool_value": (500_000_098_388, 0),
    },
}

ACCEPTED_SQRT_ISLAND_PARITY_VALUES = {
    "ordinary_1x": {
        "LP supply shares": 5_000_099,
        "LP withdraw payout": 4_999_999,
        "live forward": 75_799_394_374_445,
        "mint contribution": 6_339_958,
        "mint entry exposure": 6_339_958,
        "mint floor": 0,
        "mint range price": 528_329_883,
        "mint_lower up price": 528_329_883,
        "partial-close redeem": 2_113_319,
        "partial-close remaining floor": 0,
        "partial-close removed floor": 0,
    },
    "leveraged_boundary": {
        "LP supply shares": 5_000_098,
        "LP withdraw payout": 4_999_998,
        "live forward": 75_044_761_049_821,
        "mint contribution": 3_993_041,
        "mint entry exposure": 9_982_601,
        "mint floor": 5_989_560,
        "mint range price": 499_130_085,
        "mint_lower up price": 499_130_085,
        "partial-close redeem": 1_996,
        "partial-close remaining floor": 5_986_565,
        "partial-close removed floor": 2_995,
    },
    "precision_sensitive": {
        "LP supply shares": 5_000_099,
        "LP withdraw payout": 4_999_999,
        "live forward": 74_212_629_180_749,
        "mint contribution": 10_525_775,
        "mint entry exposure": 26_314_436,
        "mint floor": 15_788_661,
        "mint range price": 877_147_899,
        "mint_lower up price": 877_147_899,
        "partial-close redeem": 3_508_591,
        "partial-close remaining floor": 10_525_774,
        "partial-close removed floor": 5_262_887,
    },
}


def normalized_key_outputs(bundle: dict) -> dict[str, dict[str, tuple[int, int]]]:
    return {
        scenario["scenario"]: {
            name: (int(output["center"]), int(output["certificate_error"]))
            for name, output in scenario["key_outputs"].items()
        }
        for scenario in bundle["scenarios"]
    }


def normalized_parity_values(bundle: dict) -> dict[str, dict[str, int]]:
    return {
        scenario["scenario"]: {
            check["label"]: int(check["traced"])
            for check in scenario["parity_checks"]
        }
        for scenario in bundle["scenarios"]
    }


class AlgebraTraceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.bundle = algebra_trace.build_trace_bundle()

    def test_representative_flows_match_canonical_replay(self) -> None:
        self.assertTrue(self.bundle["aggregate"]["all_parity_checks_pass"])
        self.assertTrue(self.bundle["aggregate"]["all_identities_hold"])
        self.assertEqual(
            [scenario["scenario"] for scenario in self.bundle["scenarios"]],
            ["ordinary_1x", "leveraged_boundary", "precision_sensitive"],
        )

    def test_live_forward_uses_fused_three_input_reanchoring(self) -> None:
        pyth_spot = 80_123_456_789_012
        block_scholes_forward = 75_799_394_374_445
        block_scholes_spot = 75_852_009_440_344
        fused = pyth_spot * block_scholes_forward // block_scholes_spot
        stale_two_floor = replay.deepbook_mul(
            pyth_spot,
            replay.deepbook_div(block_scholes_forward, block_scholes_spot),
        )

        self.assertEqual(
            replay.live_forward(pyth_spot, block_scholes_forward, block_scholes_spot),
            fused,
        )
        self.assertNotEqual(fused, stale_two_floor)

    def test_live_forward_reanchors_when_oracle_spots_differ(self) -> None:
        pyth_spot = 75_100_000_000_000
        block_scholes_forward = 75_050_000_000_000
        block_scholes_spot = 75_000_000_000_000
        self.assertEqual(
            replay.live_forward(
                pyth_spot,
                block_scholes_forward,
                block_scholes_spot,
            ),
            75_150_066_666_666,
        )
        self.assertNotEqual(
            replay.live_forward(
                pyth_spot,
                block_scholes_forward,
                block_scholes_spot,
            ),
            replay.deepbook_mul(
                pyth_spot,
                replay.deepbook_div(
                    block_scholes_forward,
                    block_scholes_spot,
                ),
            ),
        )

    def test_negative_a_svi_branch_remains_positive_and_uses_sqrt_island(
        self,
    ) -> None:
        svi = {
            "a": 1_000,
            "aNegative": True,
            "b": 1_000_000,
            "rho": 200_000_000,
            "rhoNegative": True,
            "m": 1_000_000,
            "mNegative": True,
            "sigma": 10_000_000,
        }
        forward = 75_050_000_000_000
        strike = 75_000_000_000_000
        accepted = replay.compute_nd2(svi, forward, strike)
        self.assertEqual(accepted, 598_464_213)
        self.assertTrue(0 <= accepted <= replay.FLOAT_SCALING)

    def test_key_outputs_match_accepted_sqrt_island_oracle(self) -> None:
        self.assertEqual(
            normalized_key_outputs(self.bundle),
            ACCEPTED_SQRT_ISLAND_KEY_OUTPUTS,
        )

    def test_aggregate_counts_include_every_scenario(self) -> None:
        expected: dict[str, int] = {}
        for scenario in self.bundle["scenarios"]:
            for operation, count in scenario["operation_counts"].items():
                expected[operation] = expected.get(operation, 0) + count
        self.assertEqual(
            self.bundle["aggregate"]["operation_counts"],
            dict(sorted(expected.items())),
        )

    def test_lifecycle_parity_values_match_accepted_sqrt_island_oracle(
        self,
    ) -> None:
        self.assertEqual(
            normalized_parity_values(self.bundle),
            ACCEPTED_SQRT_ISLAND_PARITY_VALUES,
        )

    def test_sqrt_island_preserves_nav_center_while_bid_ask_changes_lp_quotes(
        self,
    ) -> None:
        accepted = normalized_key_outputs(self.bundle)
        changed_prices = {
            scenario: (
                TARGET_94758FFD_1E9_KEY_OUTPUTS[scenario]["mint_range_price"],
                accepted[scenario]["mint_range_price"],
            )
            for scenario in accepted
        }
        self.assertTrue(
            all(before != after for before, after in changed_prices.values())
        )
        changed_lp_quotes = []
        for scenario in accepted:
            center, error = accepted[scenario]["pool_value"]
            self.assertEqual(
                accepted[scenario]["withdraw_pool_value"],
                (center - error, 0),
            )
            self.assertEqual(
                accepted[scenario]["supply_pool_value"],
                (center + error, 0),
            )
            changed_lp_quotes.append(
                (
                    accepted[scenario]["supply_shares"],
                    accepted[scenario]["withdraw_dusdc"],
                )
                != (
                    TARGET_94758FFD_1E9_KEY_OUTPUTS[scenario][
                        "supply_shares"
                    ],
                    TARGET_94758FFD_1E9_KEY_OUTPUTS[scenario][
                        "withdraw_dusdc"
                    ],
                )
            )
        self.assertTrue(any(changed_lp_quotes))

    def test_frozen_oracle_detects_shared_pricing_mutation(self) -> None:
        original_normal_cdf = replay.normal_cdf
        replay.compute_up_price_cached.cache_clear()
        replay.compute_range_price_cached.cache_clear()
        replay.normal_cdf = lambda value: min(
            replay.FLOAT_SCALING,
            original_normal_cdf(value) + 1,
        )
        try:
            mutated = algebra_trace.build_trace_bundle()
        finally:
            replay.normal_cdf = original_normal_cdf
            replay.compute_up_price_cached.cache_clear()
            replay.compute_range_price_cached.cache_clear()

        # The tracer and replay share this primitive, so their internal comparison
        # alone cannot detect the mutation. The frozen Move oracle must detect it.
        self.assertTrue(mutated["aggregate"]["all_parity_checks_pass"])
        self.assertNotEqual(
            normalized_key_outputs(mutated),
            ACCEPTED_SQRT_ISLAND_KEY_OUTPUTS,
        )

    def test_partial_close_uses_move_fused_floor_split(self) -> None:
        terms = replay.compute_live_close_terms(
            range_probability=499_130_082,
            old_quantity=20_000_000,
            old_floor_shares=5_989_561,
            close_quantity=10_000,
        )
        self.assertEqual(terms["remaining_floor_shares"], 5_986_566)
        self.assertEqual(terms["remove_floor_shares"], 2_995)
        self.assertEqual(
            terms["remaining_floor_shares"] + terms["remove_floor_shares"],
            5_989_561,
        )
        for close_quantity in range(10_000, 20_000_001, 1_990_000):
            split = replay.compute_live_close_terms(
                499_130_082,
                20_000_000,
                5_989_561,
                close_quantity,
            )
            self.assertEqual(
                split["remove_floor_shares"],
                replay.mul_div_round_up(5_989_561, close_quantity, 20_000_000),
            )

    def test_replay_partial_close_uses_the_shared_terms(self) -> None:
        scenario = algebra_trace.SCENARIOS[1]
        self.assertEqual(scenario.pyth_spot, scenario.block_scholes_spot)
        oracle = {
            **scenario.svi,
            "spot": scenario.pyth_spot,
            "forward": scenario.pushed_forward,
            "riskFreeRate": 0,
        }
        rows = [
            {
                "action": "oracle_mint_ptb",
                "lineNumber": 2,
                "step": 1,
                "replayTimestampMs": 1,
                "sourceTimestampMs": 1,
                "priceSourceTimestampMs": 1,
                **oracle,
                "strike": scenario.strike,
                "isUp": scenario.is_up,
                "quantity": scenario.quantity,
                "leverage": scenario.leverage,
                "orderRef": "order-a",
            },
            {
                "action": "redeem",
                "lineNumber": 3,
                "step": 2,
                "replayTimestampMs": 2,
                "sourceTimestampMs": 2,
                "priceSourceTimestampMs": 2,
                "oracleRefresh": oracle,
                "orderRef": "order-a",
                "closeQuantity": scenario.close_quantity,
                "replacementOrderRef": "order-b",
            },
        ]
        canonical_replacement_floor = None
        analytics_replacement_floor = None
        original_insert_active_order = replay.insert_active_order
        original_analytics_insert_order = replay.analytics_insert_order

        def capture_active_order(model: dict, ref: str) -> None:
            nonlocal canonical_replacement_floor
            original_insert_active_order(model, ref)
            if ref == "order-b":
                canonical_replacement_floor = model["orders"][ref]["floor_shares"]

        def capture_analytics_order(analytics: dict, order: dict) -> None:
            nonlocal analytics_replacement_floor
            original_analytics_insert_order(analytics, order)
            if order["ref"] == "order-b":
                analytics_replacement_floor = order["floor_shares"]

        with (
            patch.object(replay, "insert_active_order", side_effect=capture_active_order),
            patch.object(replay, "analytics_insert_order", side_effect=capture_analytics_order),
        ):
            result, _ = replay.replay(rows, collect_derived=True)

        close = result["records"][1]["updates"][-1]
        self.assertEqual(close["redeem_amount"], "1996")
        self.assertEqual(result["records"][1]["state"]["open_order_quantity"], "19990000")
        self.assertEqual(canonical_replacement_floor, 5_986_565)
        self.assertEqual(analytics_replacement_floor, 5_986_565)
        self.assertEqual(5_989_560 - canonical_replacement_floor, 2_995)

    def test_sigma_square_births_the_target_rounding_leaf(self) -> None:
        gaps = [
            knot
            for scenario in self.bundle["scenarios"]
            for knot in scenario["knots"]
            if knot["kind"] == "certificate_provenance_gap"
        ]
        self.assertEqual(gaps, [])
        for scenario in self.bundle["scenarios"]:
            sigma_squares = [
                node
                for node in scenario["nodes"]
                if node["name"].endswith("_sigma_squared")
            ]
            self.assertEqual(len(sigma_squares), 1)
            self.assertEqual(sigma_squares[0]["op"], "square_scaled")
            self.assertEqual(sigma_squares[0]["certificate_error"], "1")

    def test_price_certificates_cover_committed_reference_enclosures(self) -> None:
        for scenario, traced in zip(algebra_trace.SCENARIOS, self.bundle["scenarios"], strict=True):
            price = traced["key_outputs"]["mint_range_price"]
            center = int(price["center"])
            error = int(price["certificate_error"])
            self.assertLessEqual(abs(center - scenario.reference_lower), error)
            self.assertLessEqual(abs(center - scenario.reference_upper), error)

    def test_price_certificate_errors_match_accepted_sqrt_island_move(self) -> None:
        actual = {
            scenario["scenario"]: int(
                scenario["key_outputs"]["mint_range_price"]["certificate_error"]
            )
            for scenario in self.bundle["scenarios"]
        }
        self.assertEqual(
            actual,
            {
                "ordinary_1x": 448,
                "leveraged_boundary": 1_951,
                "precision_sensitive": 1_468,
            },
        )

    def test_signed_fused_product_uses_xor_sign(self) -> None:
        trace = algebra_trace.AlgebraTrace(algebra_trace.SCENARIOS[0])
        positive = trace.input("positive", 6, "test", unit="raw")
        negative = trace.input("negative", -6, "test", unit="raw")
        factor = trace.input("factor", 3, "test", unit="raw")
        divisor = trace.input("divisor", 2, "test", unit="raw")
        one_negative = trace.mul_div_down(
            "one_negative",
            negative,
            factor,
            divisor,
            "test",
            move_site="fixed_math::approx::mul_div_down",
            unit="raw",
        )
        two_negatives = trace.mul_div_down(
            "two_negatives",
            negative,
            factor,
            trace.input("negative_divisor", -2, "test", unit="raw"),
            "test",
            move_site="fixed_math::approx::mul_div_down",
            unit="raw",
        )
        self.assertEqual(one_negative.center, -9)
        self.assertEqual(two_negatives.center, 9)
        self.assertEqual(positive.center, 6)

    def test_bundle_and_report_are_deterministic(self) -> None:
        rebuilt = algebra_trace.build_trace_bundle()
        self.assertEqual(self.bundle, rebuilt)
        with tempfile.TemporaryDirectory() as directory:
            json_path, report_path = algebra_trace.write_bundle(self.bundle, Path(directory))
            self.assertEqual(json.loads(json_path.read_text()), self.bundle)
            report = report_path.read_text()
            self.assertIn("Scalar parity: **PASS**", report)
            self.assertNotIn("certificate_provenance_gap", report)
            self.assertNotIn("dust_direction_review", report)
            self.assertIn("Candidate gate", report)


if __name__ == "__main__":
    unittest.main()
