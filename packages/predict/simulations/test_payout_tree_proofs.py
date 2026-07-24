#!/usr/bin/env python3
"""Mechanical checks for multi-order payout-tree proofs."""

from __future__ import annotations

import unittest

import payout_tree_proofs as proofs


class PayoutTreeProofTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.bundle = proofs.build_payout_tree_bundle()

    def test_bounded_live_aggregation_contains_direct_liability(self) -> None:
        live = self.bundle["live_aggregation"]
        self.assertEqual(live["containment_failures"], [])
        self.assertIsNotNone(live["scalar_difference_witness"])
        self.assertIsNotNone(live["clamp_witness"])
        self.assertTrue(live["all_invariants_hold"])

    def test_settled_redemption_is_order_independent_and_dust_free(
        self,
    ) -> None:
        settled = self.bundle["settled_redemption"]
        self.assertEqual(settled["failures"], [])
        self.assertTrue(settled["all_invariants_hold"])

    def test_prefix_summary_recurrence_is_associative_and_minimal(self) -> None:
        result = self.bundle["prefix_summary_monoid"]
        self.assertTrue(result["all_invariants_hold"])
        self.assertEqual(
            result["source_function_fingerprint_mismatches"],
            {},
        )
        self.assertTrue(all(result["source_expression_bindings"].values()))
        self.assertEqual(result["concatenation_failures"], [])
        self.assertEqual(result["associativity_failures"], [])
        self.assertEqual(
            result["plain_subtraction_mutation"]["plain_unsigned_subtraction"],
            "underflow",
        )
        self.assertNotEqual(
            result["remove_outer_max_mutation"]["correct_max_prefix"],
            result["remove_outer_max_mutation"]["right_only_shifted_prefix"],
        )

    def test_full_payout_tree_bundle_holds(self) -> None:
        self.assertTrue(self.bundle["all_invariants_hold"])
        self.assertIn(
            "not bit-equivalent",
            self.bundle["minimality_disposition"],
        )


if __name__ == "__main__":
    unittest.main()
