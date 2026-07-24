#!/usr/bin/env python3

from __future__ import annotations

import unittest

import saturation_proofs


class SaturationProofTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.bundle = saturation_proofs.build_saturation_bundle()

    def test_every_source_saturation_has_a_disposition(self) -> None:
        self.assertTrue(self.bundle["all_sites_classified"])
        self.assertEqual(self.bundle["missing_source_functions"], [])
        self.assertEqual(self.bundle["stale_dispositions"], [])

    def test_net_funding_never_exceeds_its_allocation_cap(self) -> None:
        proof = self.bundle["funding_transition_proof"]
        self.assertEqual(proof["violations"], [])
        self.assertTrue(proof["outer_subtraction_never_underflows"])

    def test_fee_cap_subtraction_requires_a_stable_cap_identity(self) -> None:
        proof = self.bundle["fixed_fee_cap_proof"]
        self.assertEqual(proof["violations"], [])
        self.assertTrue(proof["plain_subtraction_safe_for_fixed_cap"])
        self.assertEqual(
            proof["varying_cap_counterexample"]["plain_sub"],
            "underflow",
        )

    def test_proven_outer_saturation_reduction_is_landed(self) -> None:
        self.assertEqual(
            self.bundle["proved_landed_reductions"],
            [
                "packages/predict/sources/plp/pool_accounting.move::available_expiry_funding"
            ],
        )
        self.assertEqual(self.bundle["proved_immediate_reductions"], [])

    def test_available_expiry_funding_reduction_rests_on_an_induction(
        self,
    ) -> None:
        # The reduction is proven ONLY by the source-complete induction; the
        # bounded BFS is supporting illustration, and the two must agree.
        induction = self.bundle["available_expiry_funding_induction"]
        self.assertTrue(induction["induction_holds"])
        self.assertTrue(induction["writer_inventory_source_complete"])
        self.assertTrue(induction["cap_has_no_writer"])
        self.assertTrue(induction["guard_present"])
        self.assertTrue(induction["net_funding_is_saturating_sub"])
        self.assertIsNone(induction["sent_step_lemma_counterexample"])
        self.assertIsNone(induction["received_step_lemma_counterexample"])
        self.assertTrue(self.bundle["bfs_agrees_with_induction"])

    def test_writer_scan_is_fail_closed(self) -> None:
        # Exactly one guarded writer for sent, one monotonic writer for
        # received, and no writer for the cap. A new writer breaks the proof.
        induction = self.bundle["available_expiry_funding_induction"]
        lines = induction["field_assignment_lines"]
        self.assertEqual(len(lines["sent_to_expiry"]), 1)
        self.assertEqual(len(lines["received_from_expiry"]), 1)
        self.assertEqual(lines["max_expiry_allocation"], [])


if __name__ == "__main__":
    unittest.main()
