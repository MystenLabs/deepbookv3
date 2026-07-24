#!/usr/bin/env python3
"""Completeness checks for the source-backed Predict math inventory."""

from __future__ import annotations

import unittest

import money_math_inventory as inventory


class MoneyMathInventoryTests(unittest.TestCase):
    def test_every_fixed_point_clamp_and_custody_candidate_is_classified(
        self,
    ) -> None:
        result = inventory.build_inventory()
        self.assertTrue(result["source_tree_matches_baseline"])
        self.assertEqual(result["unclassified_candidates"], [])
        self.assertEqual(result["stale_function_classifications"], [])
        self.assertTrue(result["complete_for_candidate_pattern"])

    def test_inventory_separates_money_births_from_exact_custody(self) -> None:
        result = inventory.build_inventory()
        self.assertGreater(result["counts"][inventory.MONEY_COLLAPSE], 0)
        self.assertGreater(result["counts"][inventory.EXACT_CUSTODY], 0)
        self.assertGreater(
            result["counts"][inventory.NUMERICAL_EVALUATION],
            0,
        )

    def test_core_rounding_surfaces_are_present(self) -> None:
        result = inventory.build_inventory()
        functions = {
            record["function_id"]: record["classification"]
            for record in result["records"]
        }
        self.assertEqual(
            functions[
                "packages/predict/sources/config/"
                "strike_exposure_config.move::assert_mint_admission"
            ],
            inventory.MONEY_COLLAPSE,
        )
        self.assertEqual(
            functions[
                "packages/predict/sources/strike_exposure/"
                "strike_exposure.move::quote_live_close"
            ],
            inventory.MONEY_COLLAPSE,
        )
        self.assertEqual(
            functions[
                "packages/predict/sources/plp/"
                "lp_book.move::quote_withdraw_dusdc"
            ],
            inventory.MONEY_COLLAPSE,
        )

    def test_scanner_covers_sqrt_variants_and_integer_remainders(
        self,
    ) -> None:
        operators = {
            record["operator"]
            for record in inventory.build_inventory()["records"]
        }
        self.assertIn("sqrt_down", operators)
        self.assertIn("sqrt_u128_down", operators)
        self.assertIn("sqrt_u128_up", operators)
        self.assertIn("from_certified_parts", operators)
        self.assertIn("raw_mod", operators)

    def test_scanner_preserves_directed_rounding_operator(self) -> None:
        relative = "packages/predict/sources/example.move"
        source = """
module example::example;
fun charge(a: u64, b: u64): u64 {
    math::mul_up(a, b)
}
"""
        original = inventory.scan_source_text(relative, source)
        mutated = inventory.scan_source_text(
            relative,
            source.replace("math::mul_up", "math::mul_down"),
        )
        self.assertEqual(original[0].site_id, mutated[0].site_id)
        self.assertEqual(original[0].operator, "mul_up")
        self.assertEqual(mutated[0].operator, "mul_down")
        self.assertNotIn("mul", {original[0].operator, mutated[0].operator})


if __name__ == "__main__":
    unittest.main()
