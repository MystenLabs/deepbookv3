#!/usr/bin/env python3
"""Checks that every money function has a mechanical minimality disposition."""

from __future__ import annotations

import unittest

import algebra_minimality as minimality


class AlgebraMinimalityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.bundle = minimality.build_minimality_bundle()

    def test_every_money_function_has_a_minimality_disposition(self) -> None:
        self.assertEqual(self.bundle["missing_money_functions"], [])
        self.assertEqual(self.bundle["stale_function_entries"], [])
        self.assertTrue(self.bundle["all_money_functions_classified"])

    def test_no_equivalent_operation_saving_candidate_remains(self) -> None:
        self.assertEqual(
            self.bundle["equivalent_operation_saving_candidates"],
            [],
        )
        self.assertFalse(self.bundle["universal_maximal_simplicity_proven"])
        self.assertEqual(
            set(self.bundle["rewrite_search_scope"]),
            {
                row["name"] for row in self.bundle["transformations"]
            },
        )

    def test_operation_saving_candidates_have_counterexamples(self) -> None:
        transformations = {
            row["name"]: row for row in self.bundle["transformations"]
        }
        self.assertIsNotNone(
            transformations["net_premium_fusion"][
                "mutation_counterexample"
            ]
        )
        self.assertIsNotNone(
            transformations["boundary_net_quantity_product"][
                "mutation_counterexample"
            ]
        )
        for name in (
            "trading_fee_rate_quantity_fusion",
            "stake_discount_curve_fusion",
            "stake_rebate_curve_fusion",
        ):
            self.assertIsNotNone(
                transformations[name]["mutation_counterexample"]
            )
        self.assertEqual(
            transformations["linear_minus_correction_plain_sub"]["status"],
            "candidate_rejected_underflow_witness",
        )
        self.assertEqual(
            transformations["linear_minus_correction_plain_sub"]["witness"],
            {
                "two_order_linear": "872",
                "two_order_knocked_out_correction": "873",
                "plain_sub": "underflow",
                "saturating_sub": "0",
            },
        )

    def test_equivalent_rewrites_do_not_claim_false_operation_savings(
        self,
    ) -> None:
        transformations = {
            row["name"]: row for row in self.bundle["transformations"]
        }
        builder = transformations["builder_min_before_floor"]
        self.assertIsNone(builder["mutation_counterexample"])
        self.assertGreater(
            builder["candidate_operations"],
            builder["current_operations"],
        )
        discount = transformations["discount_as_ceil_complement"]
        self.assertIsNone(discount["mutation_counterexample"])

    def test_cross_module_conclusions_are_folded_in(self) -> None:
        conclusions = self.bundle["cross_module_conclusions"]
        self.assertEqual(
            conclusions["partial_close_floor_complement"]["verdict"],
            "locally_minimal_and_atom_conserving",
        )
        live = conclusions["live_close_saturating_sub"]
        self.assertEqual(
            live["verdict"], "semantically_required_under_present_invariants"
        )
        self.assertFalse(live["removable"])
        split = conclusions["split_close_discounted_proceeds"]
        self.assertEqual(split["verdict"], "reachable_open_policy_issue")
        self.assertTrue(split["policy_decision_pending"])
        funding = conclusions["available_expiry_funding_outer_saturation"]
        self.assertEqual(funding["verdict"], "proven_reduction")
        self.assertTrue(funding["proven"])


if __name__ == "__main__":
    unittest.main()
