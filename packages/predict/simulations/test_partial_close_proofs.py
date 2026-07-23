#!/usr/bin/env python3

import unittest

import partial_close_proofs as proofs


class PartialCloseProofTests(unittest.TestCase):
    def test_structural_invariants_and_path_counterexample(self) -> None:
        result = proofs.bounded_structural_proof()
        self.assertTrue(result["structural_invariants_hold"])
        self.assertFalse(result["redeem_is_path_independent"])
        self.assertIsNotNone(result["first_redeem_path_counterexample"])

    def test_current_config_production_witness(self) -> None:
        witness = proofs.production_fragmentation_witness()
        self.assertTrue(witness["valid"])
        self.assertEqual(witness["entry"]["floor_shares"], 1)
        self.assertEqual(witness["direct"]["total_net_proceeds"], 0)
        self.assertEqual(witness["split"]["total_net_proceeds"], 1)
        self.assertEqual(witness["trader_advantage"], 1)

    def test_shortfall_bound_is_below_default_minimum_fee(self) -> None:
        bound = proofs.shortfall_bound()
        self.assertEqual(bound["maximum_shortfall_slice_gross"], 5)
        self.assertEqual(bound["minimum_default_raw_fee_per_lot"], 50)
        self.assertTrue(bound["default_raw_fee_covers_shortfall_slice"])


class PartialCloseGeneralizationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.bundle = proofs.build_partial_close_bundle()

    def test_end_to_end_aggregate_stays_red_with_a_reachable_witness(
        self,
    ) -> None:
        # The aggregate must be RED while any reachable trader-favored split
        # remains, and no universal maximum may be claimed.
        self.assertFalse(
            self.bundle["end_to_end_net_proceeds_path_independent"]
        )
        self.assertGreaterEqual(
            self.bundle["maximum_known_split_close_advantage"], 1
        )
        self.assertFalse(self.bundle["global_maximum_advantage_is_established"])

    def test_fractional_close_search_bounds_advantage_and_fee_directions(
        self,
    ) -> None:
        search = self.bundle["reachable_advantage_search"]
        self.assertEqual(search["result_strength"], proofs.EXHAUSTIVE)
        self.assertGreaterEqual(search["max_trader_advantage_over_domain"], 1)
        # Up-rounded EWMA penalty can only offset the advantage; an active
        # builder code does not raise it on a fractional close.
        self.assertTrue(search["penalty_can_reduce_advantage"])
        self.assertFalse(search["builder_can_increase_advantage"])

    def test_full_exit_generalizes_across_floors_and_needs_a_builder_code(
        self,
    ) -> None:
        full = self.bundle["full_liquidation_split_analysis"]
        self.assertEqual(full["result_strength"], proofs.EXHAUSTIVE)
        # The effect generalizes to every floor 1..6 on a full exit.
        self.assertEqual(
            sorted(full["max_advantage_by_floor"]), [1, 2, 3, 4, 5, 6]
        )
        self.assertGreaterEqual(full["max_trader_advantage_over_domain"], 2)
        # The domain maximum needs an active builder code (its down-rounded
        # single fee on the direct close exceeds the split's summed fees).
        self.assertTrue(full["active_builder_code_needed_for_domain_max"])

    def test_over_splitting_a_full_exit_turns_trader_negative(self) -> None:
        full = self.bundle["full_liquidation_split_analysis"]
        # Advantage does not grow without bound: many equal slices are negative.
        self.assertTrue(full["large_split_count_is_trader_negative"])

    def test_changing_price_is_reported_separately_as_descriptive(self) -> None:
        changing = self.bundle["changing_price_analysis"]
        self.assertTrue(changing["rows"])
        self.assertIn("descriptive", changing["note"])

    def test_every_top_level_result_carries_a_strength_tag(self) -> None:
        legend = self.bundle["result_strength_legend"]
        for key in (
            "structural_proof",
            "shortfall_bound",
            "production_fragmentation_witness",
            "reachable_advantage_search",
            "full_liquidation_split_analysis",
            "changing_price_analysis",
        ):
            self.assertIn(self.bundle[key]["result_strength"], legend)


if __name__ == "__main__":
    unittest.main()
