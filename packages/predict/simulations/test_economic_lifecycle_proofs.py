#!/usr/bin/env python3
"""Mechanical checks for fee-bearing Predict lifecycle proofs."""

from __future__ import annotations

import unittest

import economic_lifecycle_proofs as lifecycle


class EconomicLifecycleProofTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.bundle = lifecycle.build_lifecycle_bundle()

    def test_all_stateful_flows_conserve_custody(self) -> None:
        self.assertTrue(self.bundle["all_invariants_hold"])
        for flow in self.bundle["flows"]:
            self.assertTrue(flow["all_invariants_hold"], flow["flow"])

    def test_dust_is_observed_and_every_residual_has_an_owner(self) -> None:
        self.assertGreater(self.bundle["dust_witness_count"], 0)
        self.assertEqual(self.bundle["ownerless_dust"], [])

    def test_mint_routes_subsidy_builder_fee_and_penalty_exactly(self) -> None:
        flow = lifecycle.run_mint_payment_lifecycle()
        self.assertTrue(flow["invariants"]["cash_conserved"])
        self.assertTrue(flow["invariants"]["subsidy_restores_full_trading_fee"])
        self.assertTrue(
            flow["invariants"]["rebate_basis_tracks_only_trader_paid_fee"]
        )

    def test_redeem_clamps_make_every_subtraction_total(self) -> None:
        flow = lifecycle.run_live_redeem_lifecycle()
        self.assertTrue(flow["invariants"]["all_clamps_are_total"])
        self.assertTrue(flow["invariants"]["penalty_never_leaves_expiry_cash"])

    def test_redeem_penalty_rounds_up_for_expiry_cash(self) -> None:
        flow = lifecycle.run_live_redeem_lifecycle()
        penalty = int(flow["terms"]["penalty"])
        exact_floor = 21_000_007 * 31_000_009 // lifecycle.F
        residual = next(
            row
            for row in flow["residuals"]
            if row["name"] == "redeem_ewma_penalty"
        )

        self.assertEqual(
            penalty,
            lifecycle.replay.deepbook_mul_up(
                21_000_007,
                31_000_009,
            ),
        )
        self.assertEqual(penalty, exact_floor + 1)
        self.assertEqual(residual["owner"], "expiry_cash")

    def test_rebate_pays_claimant_and_returns_exact_residual(self) -> None:
        flow = lifecycle.run_rebate_lifecycle()
        self.assertTrue(flow["invariants"]["reserve_decomposition_exact"])
        self.assertTrue(flow["invariants"]["claimant_never_overpaid"])
        self.assertTrue(flow["invariants"]["fee_basis_fully_resolved"])

    def test_exact_amount_search_uses_canonical_premium_and_is_maximal(
        self,
    ) -> None:
        proof = lifecycle.exact_amount_search_proof()
        self.assertEqual(proof["failures"], [])
        witness = proof["production_maximality_witness"]
        self.assertLessEqual(
            int(witness["premium_at_search_quantity"]),
            int(witness["budget"]),
        )
        self.assertGreater(
            int(witness["premium_at_next_lot"]),
            int(witness["budget"]),
        )
        self.assertTrue(proof["all_invariants_hold"])


if __name__ == "__main__":
    unittest.main()
