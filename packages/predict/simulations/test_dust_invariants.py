#!/usr/bin/env python3
"""Deterministic checks for the Predict dust and NAV policy analyzer."""

from __future__ import annotations

import json
from copy import deepcopy
from fractions import Fraction
import unittest

import algebra_trace
import dust_invariants as dust
import python_replay as replay


class NavBandTests(unittest.TestCase):
    def test_bid_ask_and_true_relative_gate_match_target_semantics(self) -> None:
        band = dust.NavBand(1_000, 10)
        self.assertEqual((band.bid, band.ask), (990, 1_010))
        self.assertTrue(band.contains(990))
        self.assertTrue(band.contains(1_010))
        self.assertTrue(band.true_relative_deviation_within(11_000_000))
        self.assertFalse(band.true_relative_deviation_within(10_000_000))

    def test_nonzero_width_has_no_universal_single_mark(self) -> None:
        proof = dust.nav_spread_proof(dust.NavBand(1_000, 1))
        self.assertEqual(proof["supply_mark_must_be_at_least"], "1001")
        self.assertEqual(proof["withdraw_mark_must_be_at_most"], "999")
        self.assertFalse(proof["universal_single_mark_exists"])
        self.assertTrue(proof["split_mark_satisfies_both"])

    def test_zero_width_allows_one_exact_mark(self) -> None:
        self.assertTrue(
            dust.nav_spread_proof(dust.NavBand(1_000, 0))[
                "universal_single_mark_exists"
            ]
        )

    def test_zero_center_flush_collapses_both_marks_even_with_error(self) -> None:
        band = dust.NavBand(0, 7)
        self.assertEqual((band.bid, band.ask), (0, 7))
        self.assertEqual(band.flush_marks, (0, 0))
        result = dust.evaluate_lp_policy(
            band,
            amount=10,
            total_supply=100,
            withdraw_shares=10,
            policy=dust.LANDED_LP_POLICY,
        )
        self.assertIsNone(result["supplied_shares"])
        self.assertIsNone(result["withdraw_payout"])
        self.assertTrue(result["all_invariants_hold"])

    def test_imprecise_nonzero_nav_is_rejected_before_queue_pricing(self) -> None:
        result = dust.evaluate_lp_policy(
            dust.NavBand(10, 5),
            amount=2,
            total_supply=10,
            withdraw_shares=3,
            policy=dust.LANDED_LP_POLICY,
        )
        self.assertEqual(result["flush_status"], "valuation_rejected")
        self.assertIsNone(result["supplied_shares"])
        self.assertFalse(result["roundtrip_executable"])
        self.assertTrue(result["roundtrip_no_extraction"])
        self.assertTrue(result["all_invariants_hold"])

    def test_boundary_suite_accepts_every_executable_spread_case(self) -> None:
        result = dust.run_boundary_suite()
        self.assertEqual(result["checked"], 100)
        self.assertEqual(result["failures"], [])
        self.assertTrue(result["all_executable_cases_hold"])


class DustInvariantBundleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.algebra = algebra_trace.build_trace_bundle()
        cls.bundle = dust.build_dust_invariant_bundle(cls.algebra)

    def test_bundle_is_pinned_to_requested_contract_sha(self) -> None:
        self.assertEqual(
            self.bundle["contract_baseline"],
            "1a9489f6cb1a6f398307bd8576e20b5df5467126",
        )
        self.assertEqual(
            self.bundle["pricing_profile"],
            "canonical_premium_protocol_fees_retained_1e18_sqrt_nav_bid_ask",
        )

    def test_current_profile_records_premium_and_nav_bid_ask_changes(
        self,
    ) -> None:
        comparison = self.bundle["pricing_profile_comparison"]
        self.assertFalse(comparison["representative_pool_value_centers_unchanged"])
        self.assertFalse(comparison["representative_lp_quote_centers_unchanged"])
        self.assertIsNone(comparison["external_availability_evidence"])
        leveraged = next(
            row
            for row in comparison["scenarios"]
            if row["scenario"] == "leveraged_boundary"
        )
        self.assertEqual(
            leveraged["changes"]["withdraw_dusdc"]["center_delta"],
            "-1",
        )
        precision = next(
            row
            for row in comparison["scenarios"]
            if row["scenario"] == "precision_sensitive"
        )
        self.assertEqual(
            precision["changes"]["mint_range_price"]["center_delta"],
            "-970",
        )
        self.assertEqual(
            precision["changes"]["pool_value"]["error_delta"],
            "-154",
        )
        self.assertEqual(
            precision["changes"]["pool_value"]["center_delta"],
            "1",
        )

    def test_every_traced_money_site_is_registered_and_tagged(self) -> None:
        collapse = self.bundle["collapse_sites"]
        self.assertTrue(collapse["complete"])
        self.assertEqual(collapse["unknown_money_sites"], [])
        self.assertEqual(collapse["untagged_money_sites"], [])
        self.assertEqual(collapse["unobserved_registry_sites"], [])
        self.assertTrue(
            all(record["declared_owner_matches"] for record in collapse["records"])
        )

    def test_dust_ledger_is_double_entry_by_asset(self) -> None:
        ledger = self.bundle["collapse_sites"]["ledger"]
        self.assertTrue(ledger["all_assets_conserved"])
        self.assertTrue(all(ledger["conserved_by_asset"].values()))

    def test_balance_reconciliation_rejects_a_missing_transfer_leg(self) -> None:
        before = dust.BalanceSheet(
            {"dusdc_1e6": {"trader": 100, "lp_pool": 50}}
        )
        after = dust.BalanceSheet(
            {"dusdc_1e6": {"trader": 90, "lp_pool": 59}}
        )
        result = dust.reconcile_transfer(
            before=before,
            after=after,
            asset="dusdc_1e6",
            sender="trader",
            recipient="lp_pool",
            exact_amount=Fraction(21, 2),
            pool_party="lp_pool",
        )
        self.assertFalse(result["account_legs_match"])
        self.assertFalse(result["asset_conserved"])
        self.assertFalse(result["valid"])

    def test_observed_mint_inflows_follow_protocol_bias(self) -> None:
        mismatches = self.bundle["collapse_sites"]["doctrine_mismatches"]
        self.assertEqual(mismatches, [])

    def test_protocol_premium_dust_is_contingent_across_the_stored_floor(
        self,
    ) -> None:
        outcomes = {
            row["scenario"]: row
            for row in self.bundle["net_premium_lifecycle_dust"]
        }
        leveraged = outcomes["leveraged_boundary"]
        self.assertEqual(leveraged["protocol_upfront_advantage"], "3/5")
        self.assertEqual(leveraged["trader_winner_payout_advantage"], "3/5")
        self.assertEqual(
            leveraged["mint_to_winner_net_protocol_advantage"],
            "0/1",
        )
        self.assertEqual(
            leveraged["mint_to_loser_net_protocol_advantage"],
            "3/5",
        )
        self.assertEqual(
            leveraged["full_live_close_at_entry_net_protocol_advantage"],
            "0/1",
        )

    def test_current_rounding_biases_protocol_by_at_most_one_raw_unit(self) -> None:
        flips = self.bundle["knot_flips"]["money_rounding_flips"]
        changed = [
            row for row in flips if row["protocol_bias_delta"] != "0"
        ]
        self.assertEqual(len(changed), 5)
        self.assertTrue(
            all(row["protocol_bias_delta"] == "1" for row in changed)
        )
        self.assertTrue(all(row["current_matches_r2"] for row in flips))
        self.assertTrue(
            all(
                not row["counterfactual_matches_r2"]
                for row in changed
            )
        )

    def test_knot_witnesses_distinguish_proven_and_refuted_simplifications(
        self,
    ) -> None:
        knots = {
            knot["name"]: knot for knot in self.bundle["knot_flips"]["knots"]
        }
        self.assertEqual(
            knots["live_forward_fusion"]["status"],
            "keep_current_proven_simplification",
        )
        self.assertEqual(
            knots["partial_close_floor_split"]["mutation_unassigned_floor"],
            "1",
        )
        self.assertEqual(
            knots["net_premium_stacked_rounding"]["witness"]["delta"],
            "1",
        )
        self.assertEqual(
            knots["range_product_reuse"]["status"],
            "refuted_by_non_distributive_rounding",
        )
        self.assertEqual(
            knots["linear_minus_correction_clamp"]["status"],
            "keep_semantic_clamp_p13_underflow_witness",
        )

    def test_leveraged_case_exposes_center_mark_competition(self) -> None:
        scenario = next(
            row
            for row in self.bundle["scenarios"]
            if row["scenario"] == "leveraged_boundary"
        )
        self.assertFalse(
            scenario["prior_center_policy"]["withdraw_no_overpay"]
        )
        self.assertTrue(scenario["landed_policy"]["all_invariants_hold"])
        self.assertFalse(
            scenario["endpoint_proof"]["universal_single_mark_exists"]
        )

    def test_every_stateful_flow_conserves_cash_floor_and_roundtrip_value(
        self,
    ) -> None:
        for scenario in self.bundle["scenarios"]:
            self.assertTrue(
                scenario["lifecycle"]["all_invariants_hold"],
                scenario["scenario"],
            )
            lifecycle = scenario["lifecycle"]
            self.assertEqual(
                lifecycle["winner_liability_states"]["after_settlement"],
                "0",
            )
            self.assertTrue(
                all(
                    row["valid"]
                    for row in lifecycle[
                        "cash_transition_reconciliations"
                    ].values()
                )
            )

    def test_lifecycle_rejects_oversized_redeem_that_drives_pool_negative(
        self,
    ) -> None:
        scenario = deepcopy(self.algebra["scenarios"][0])
        redeem = next(
            node for node in scenario["nodes"] if node["name"] == "redeem_amount"
        )
        redeem["center"] = str(10**30)
        result = dust.run_lifecycle_invariants(scenario)
        self.assertFalse(result["invariants"]["pool_cash_nonnegative"])
        self.assertFalse(result["all_invariants_hold"])

    def test_lifecycle_rejects_a_drifted_stored_winner_liability(self) -> None:
        scenario = deepcopy(self.algebra["scenarios"][1])
        payout = next(
            node
            for node in scenario["nodes"]
            if node["name"] == "settlement_winner_payout"
        )
        payout["center"] = str(int(payout["center"]) + 1)
        result = dust.run_lifecycle_invariants(scenario)
        self.assertFalse(
            result["invariants"][
                "original_winner_liability_matches_stored_order"
            ]
        )
        self.assertFalse(result["all_invariants_hold"])

    def test_zero_bid_surfaces_distinguish_precision_rejection_from_refund(
        self,
    ) -> None:
        comparisons = self.bundle["zero_bid_queue_comparison"]
        self.assertTrue(all(row["bid"] == "0" for row in comparisons))
        imprecise_nonzero = [
            row for row in comparisons if row["center"] != "0"
        ]
        self.assertTrue(
            all(
                row["current_non_executable_action"]
                == "valuation_rejected"
                for row in imprecise_nonzero
            )
        )
        zero_center_with_error = next(
            row
            for row in comparisons
            if row["center"] == "0" and row["error"] == "7"
        )
        self.assertEqual(zero_center_with_error["ask"], "7")
        self.assertEqual(
            (
                zero_center_with_error["flush_bid"],
                zero_center_with_error["flush_ask"],
            ),
            ("0", "0"),
        )
        self.assertEqual(
            zero_center_with_error["current_non_executable_action"],
            "refund",
        )
        self.assertTrue(
            self.bundle["aggregate"][
                "accepted_non_executable_flush_marks_refund"
            ]
        )
        self.assertTrue(
            all(
                row["alternative_non_executable_action"] == "carry"
                for row in comparisons
            )
        )

    def test_protocol_profit_dust_stays_in_lp_bucket(self) -> None:
        split = self.bundle["protocol_profit_split"]
        self.assertEqual(split["actual_protocol_cut"], "24691357")
        self.assertEqual(split["reserve_advantage"], "-4/5")
        self.assertTrue(split["ledger"]["all_assets_conserved"])
        self.assertEqual(
            split["ledger"]["balances"]["dusdc_1e6"]["lp_pool"],
            "4/5",
        )

    def test_aggregate_verdict_preserves_findings_instead_of_greenwashing(
        self,
    ) -> None:
        aggregate = self.bundle["aggregate"]
        self.assertTrue(aggregate["collapse_registry_complete"])
        self.assertTrue(aggregate["dust_double_entry_conserved"])
        self.assertTrue(aggregate["observed_cash_transitions_reconcile"])
        self.assertTrue(
            aggregate["all_money_functions_have_minimality_disposition"]
        )
        self.assertFalse(
            aggregate[
                "registered_equivalent_operation_saving_candidates_remaining"
            ]
        )
        self.assertFalse(aggregate["universal_maximal_simplicity_proven"])
        self.assertTrue(aggregate["lifecycle_invariants_hold"])
        self.assertTrue(aggregate["landed_policy_holds"])
        self.assertTrue(aggregate["boundary_suite_holds"])
        self.assertFalse(aggregate["single_mark_resolves_competing_invariants"])
        self.assertTrue(aggregate["r2_doctrine_holds_at_all_observed_sites"])
        self.assertTrue(aggregate["full_contract_money_surface_complete"])
        self.assertEqual(self.bundle["flow_coverage"]["not_yet_modeled"], [])
        self.assertTrue(
            self.bundle["fee_lifecycle_proofs"]["all_invariants_hold"]
        )
        self.assertTrue(self.bundle["payout_tree_proofs"]["all_invariants_hold"])
        self.assertTrue(aggregate["all_saturating_sites_classified"])
        self.assertEqual(
            aggregate["proved_redundant_saturations"],
            [
                "packages/predict/sources/plp/pool_accounting.move::available_expiry_funding"
            ],
        )
        self.assertTrue(aggregate["partial_close_sequence_surface_classified"])
        self.assertFalse(
            aggregate["partial_close_net_proceeds_are_path_independent"]
        )
        # Generalized max over the stated finite domain (full exit + builder
        # code); the effect stays reachable so the aggregate is RED.
        self.assertEqual(
            aggregate["unresolved_trader_favored_partial_close_atoms"],
            2,
        )
        self.assertFalse(aggregate["end_to_end_dust_bias_holds"])
        self.assertTrue(
            self.bundle["partial_close_proofs"][
                "production_fragmentation_witness"
            ]["valid"]
        )

    def test_bundle_is_deterministic(self) -> None:
        rebuilt = dust.build_dust_invariant_bundle()
        self.assertEqual(
            json.dumps(self.bundle, sort_keys=True),
            json.dumps(rebuilt, sort_keys=True),
        )

    def test_external_availability_evidence_is_attached_not_fabricated(
        self,
    ) -> None:
        evidence = {
            "schema": "external_availability_v1",
            "corpus_sha256": "a" * 64,
            "runner_sha256": "b" * 64,
            "surface_count": "10",
            "zero_to_one_minute_quotes": "98.00%",
        }
        bundle = dust.build_dust_invariant_bundle(
            self.algebra,
            availability_evidence=evidence,
        )
        self.assertEqual(
            bundle["pricing_profile_comparison"][
                "external_availability_evidence"
            ],
            evidence,
        )

    def test_landed_bid_ask_quotes_match_independent_integer_formulas(
        self,
    ) -> None:
        ordinary = next(
            row
            for row in self.algebra["scenarios"]
            if row["scenario"] == "ordinary_1x"
        )
        self.assertEqual(
            ordinary["key_outputs"]["supply_shares"]["center"],
            str(
                replay.mul_div_round_down(
                    5_000_000,
                    replay.INITIAL_TOTAL_PLP_SUPPLY,
                    int(
                        ordinary["key_outputs"]["supply_pool_value"][
                            "center"
                        ]
                    ),
                )
            ),
        )
        leveraged = next(
            row
            for row in self.algebra["scenarios"]
            if row["scenario"] == "leveraged_boundary"
        )
        self.assertEqual(
            leveraged["key_outputs"]["withdraw_dusdc"]["center"],
            str(
                replay.mul_div_round_down(
                    int(
                        leveraged["key_outputs"]["supply_shares"][
                            "center"
                        ]
                    ),
                    int(
                        leveraged["key_outputs"]["withdraw_pool_value"][
                            "center"
                        ]
                    ),
                    replay.INITIAL_TOTAL_PLP_SUPPLY,
                )
            ),
        )


if __name__ == "__main__":
    unittest.main()
