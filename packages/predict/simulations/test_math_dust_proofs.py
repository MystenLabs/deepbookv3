#!/usr/bin/env python3
"""Mechanical checks for contract-wide Predict dust certificates."""

from __future__ import annotations

import copy
import unittest

import math_dust_proofs as proofs
import money_math_inventory as inventory


class MathDustProofTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.bundle = proofs.build_proof_bundle()

    def test_every_inventoried_money_function_has_a_certificate(self) -> None:
        self.assertEqual(self.bundle["missing_money_functions"], [])
        self.assertEqual(self.bundle["extra_modeled_functions"], [])
        self.assertTrue(
            self.bundle[
                "complete_for_inventoried_money_collapse_functions"
            ]
        )

    def test_every_declared_rounding_relation_holds_exactly(self) -> None:
        self.assertTrue(self.bundle["all_relations_hold"])
        self.assertTrue(self.bundle["all_source_bindings_hold"])
        self.assertGreater(self.bundle["nonzero_dust_witness_count"], 0)

    def test_protocol_bias_exceptions_are_explicit(self) -> None:
        self.assertEqual(self.bundle["protocol_bias_mismatches"], [])

    def test_peer_to_peer_builder_fee_is_not_a_protocol_bias_surface(
        self,
    ) -> None:
        builder = next(
            row
            for row in self.bundle["certificates"]
            if row["name"] == "builder_fee"
        )
        self.assertFalse(builder["protocol_bias_applicable"])
        self.assertTrue(builder["protocol_favored"])

    def test_each_certificate_names_source_and_owner(self) -> None:
        for row in self.bundle["certificates"]:
            self.assertIn("packages/predict/sources/", row["function_id"])
            self.assertIsNotNone(row["owner"])

    def test_rounding_direction_mutation_cannot_refresh_to_green(self) -> None:
        mutated = copy.deepcopy(inventory.build_inventory())
        trading_fee_site = (
            "packages/predict/sources/config/"
            "strike_exposure_config.move::trading_fee::site#1"
        )
        record = next(
            row
            for row in mutated["records"]
            if row["site_id"] == trading_fee_site
        )
        self.assertEqual(record["operator"], "mul_up")
        record["operator"] = "mul_down"
        mutated["source_tree_sha256"] = "refreshed-for-mutation"
        mutated["expected_source_tree_sha256"] = "refreshed-for-mutation"
        mutated["source_tree_matches_baseline"] = True

        bundle = proofs.build_proof_bundle(mutated)
        self.assertFalse(bundle["all_source_bindings_hold"])
        self.assertFalse(
            bundle["complete_for_inventoried_money_collapse_functions"]
        )
        self.assertEqual(
            bundle["source_binding_mismatches"][0]["expected_operator"],
            "mul_up",
        )
        self.assertEqual(
            bundle["source_binding_mismatches"][0]["actual_operator"],
            "mul_down",
        )

    def test_operand_mutation_cannot_refresh_to_green(self) -> None:
        mutated = copy.deepcopy(inventory.build_inventory())
        function_id = (
            "packages/predict/sources/config/"
            "strike_exposure_config.move::trading_fee"
        )
        for record in mutated["records"]:
            if record["function_id"] == function_id:
                record["function_source_sha256"] = "mutated-operands"
        mutated["source_tree_sha256"] = "refreshed-for-mutation"
        mutated["expected_source_tree_sha256"] = "refreshed-for-mutation"
        mutated["source_tree_matches_baseline"] = True

        bundle = proofs.build_proof_bundle(mutated)
        self.assertFalse(bundle["all_source_bindings_hold"])
        mismatch = next(
            row
            for row in bundle["source_binding_mismatches"]
            if row.get("reason") == "function_source_fingerprint_mismatch"
        )
        self.assertEqual(mismatch["function_id"], function_id)
        self.assertEqual(mismatch["actual_sha256"], "mutated-operands")


if __name__ == "__main__":
    unittest.main()
