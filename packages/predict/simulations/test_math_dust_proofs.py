#!/usr/bin/env python3
"""Mechanical checks for contract-wide Predict dust certificates."""

from __future__ import annotations

import unittest

import math_dust_proofs as proofs


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


if __name__ == "__main__":
    unittest.main()
