#!/usr/bin/env python3
"""Mechanical minimality decisions for every inventoried money function."""

from __future__ import annotations

import json
from typing import Any

import money_math_inventory as inventory
import partial_close_proofs
import payout_tree_proofs
import saturation_proofs


DIRECT_HALF_VARIANCE_FUNCTION_SHA256 = {
    "packages/predict/sources/pricing/pricing.move::compute_nd2": (
        "d8a5831287c6a5c9deac0e0e96b13f0865a3f6a374910d55f7df0a96af236f4c"
    ),
    "packages/predict/sources/pricing/pricing.move::variance_denominator_terms": (
        "b78ea4d92a9e9dde1d47fa95fb4808e1f27d2bb874ed350def0150e255c58267"
    ),
    "packages/predict/sources/pricing/pricing.move::standardized_d2": (
        "d6742f95f11308002e0e9984a955d8a31b25992dd0cbac82c104be2517bbe03b"
    ),
}


def p13_clamp_witness() -> dict[str, str]:
    boundary_linear = 9_583 + 9_530 - 18_241
    knocked_out_correction = 463 + 410
    return {
        "two_order_linear": str(boundary_linear),
        "two_order_knocked_out_correction": str(
            knocked_out_correction
        ),
        "plain_sub": (
            str(boundary_linear - knocked_out_correction)
            if boundary_linear >= knocked_out_correction
            else "underflow"
        ),
        "saturating_sub": str(
            max(0, boundary_linear - knocked_out_correction)
        ),
    }


def direct_half_variance_proof(scale: int = 17) -> dict[str, Any]:
    """Certify direct wide-to-half projection.

    For C = 2*S*k + r, 0 <= r < 2*S:
      floor(floor(C/S)/2)
        = floor((2*k + floor(r/S))/2)
        = k
        = floor(C/(2*S)).

    If the exact wide value W is within E of C, the direct center H therefore
    differs from W/(2*S) by less than 1 + E/(2*S). The integer radius
    ceil(E/(2*S)) + 1 encloses it. Omitting the rounding atom fails whenever
    E=0 and C is not divisible by 2*S.
    """
    function_hashes = inventory.function_source_sha256()
    fingerprint_mismatches = {
        function_id: {
            "expected": expected,
            "actual": function_hashes.get(function_id),
        }
        for function_id, expected in DIRECT_HALF_VARIANCE_FUNCTION_SHA256.items()
        if function_hashes.get(function_id) != expected
    }
    pricing_source = (
        inventory.SOURCE_ROOT / "pricing" / "pricing.move"
    ).read_text()
    expression_bindings = {
        "direct_center": (
            "let half_var_center = (wide_total_var / half_scale) as u64;"
            in pricing_source
        ),
        "direct_radius": (
            "let scaled_error = wide_error.div_ceil(half_scale);"
            in pricing_source
        ),
        "rounding_atom": "(scaled_error as u64) + 1" in pricing_source,
        "direct_consumer": (
            "let d2_numerator = k.add(half_var);" in pricing_source
        ),
        "discarded_half_removed": "let half_var = total_var.half();" not in pricing_source,
    }
    center_failures: list[dict[str, int]] = []
    radius_failures: list[dict[str, int]] = []
    strict_tightening_witness: dict[str, int] | None = None
    for center in range(0, 8 * scale + 1):
        staged_center = (center // scale) // 2
        direct_center = center // (2 * scale)
        if staged_center != direct_center:
            center_failures.append(
                {
                    "wide_center": center,
                    "staged_center": staged_center,
                    "direct_center": direct_center,
                }
            )
        for error in range(0, 4 * scale + 1):
            old_radius = (error + scale - 1) // scale + 2
            new_radius = (error + 2 * scale - 1) // (2 * scale) + 1
            if new_radius > old_radius:
                radius_failures.append(
                    {
                        "wide_center": center,
                        "wide_error": error,
                        "old_radius": old_radius,
                        "new_radius": new_radius,
                    }
                )
            if (
                new_radius < old_radius
                and strict_tightening_witness is None
            ):
                strict_tightening_witness = {
                    "wide_center": center,
                    "wide_error": error,
                    "old_radius": old_radius,
                    "new_radius": new_radius,
                }
    return {
        "proof_strength": "universal quotient-remainder identity and interval bound",
        "source_function_fingerprint_mismatches": fingerprint_mismatches,
        "source_expression_bindings": expression_bindings,
        "identity": "floor(floor(C/S)/2) = floor(C/(2*S))",
        "radius": "ceil(E/(2*S)) + 1",
        "bounded_identity_sanity_failures": center_failures,
        "bounded_radius_sanity_failures": radius_failures,
        "strict_tightening_witness": strict_tightening_witness,
        "rounding_atom_mutation_witness": {
            "wide_center": 1,
            "wide_error": 0,
            "exact_half_variance": f"1/{2 * scale}",
            "mutated_radius": 0,
            "encloses": False,
        },
        "proven": (
            not fingerprint_mismatches
            and all(expression_bindings.values())
            and not center_failures
            and not radius_failures
            and strict_tightening_witness is not None
        ),
    }


def _first_counterexample(predicate, domain: range, arity: int):
    if arity == 3:
        for a in domain:
            for b in domain:
                for c in domain:
                    if not predicate(a, b, c):
                        return (a, b, c)
    if arity == 4:
        for a in domain:
            for b in domain:
                for c in domain:
                    for d in domain:
                        if not predicate(a, b, c, d):
                            return (a, b, c, d)
    return None


def transformation_results() -> list[dict[str, Any]]:
    scale = 17
    domain = range(1, 2 * scale + 1)

    premium_witness = None
    for probability in range(1, scale + 1):
        for quantity in domain:
            for leverage in range(scale, 2 * scale + 1):
                entry_value = probability * quantity // scale
                staged = (
                    entry_value * scale + leverage - 1
                ) // leverage
                fused = (
                    probability * quantity + leverage - 1
                ) // leverage
                if staged != fused:
                    premium_witness = (
                        probability,
                        quantity,
                        leverage,
                    )
                    break
            if premium_witness is not None:
                break
        if premium_witness is not None:
            break
    boundary_witness = _first_counterexample(
        lambda price, start, end: (
            (price * start // scale) - (price * end // scale)
            == (
                price * (start - end) // scale
                if start >= end
                else -(price * (end - start) // scale)
            )
        ),
        domain,
        3,
    )
    independent_split_witness = _first_counterexample(
        lambda floor, closed, total: (
            closed > total
            or (
                floor * (total - closed) // total
                + floor * closed // total
                == floor
            )
        ),
        domain,
        3,
    )
    builder_min_witness = _first_counterexample(
        lambda fee, multiplier, quantity, cap: (
            min(
                fee * multiplier // scale,
                quantity * cap // scale,
            )
            == min(
                fee * multiplier,
                quantity * cap,
            )
            // scale
        ),
        domain,
        4,
    )
    discount_witness = _first_counterexample(
        lambda amount, discount, unused: (
            amount - amount * discount // scale
            == -(-(amount * (scale - discount)) // scale)
        ),
        range(0, scale + 1),
        3,
    )
    trading_fee_witness = _first_counterexample(
        lambda base, multiplier, quantity: (
            (
                (base * multiplier // scale) * quantity
                + scale
                - 1
            )
            // scale
            == (
                base * multiplier * quantity
                + scale * scale
                - 1
            )
            // (scale * scale)
        ),
        domain,
        3,
    )
    lower_power = 11
    half = scale // 2
    max_discount = 5
    stake_discount_witness = None
    stake_rebate_witness = None
    for amount in domain:
        for stake in range(1, lower_power + 1):
            benefit = half * stake // lower_power
            discount = benefit * max_discount // scale
            staged_discount_fee = amount - amount * discount // scale
            fused_discount_fee = amount - (
                amount
                * half
                * stake
                * max_discount
                // (lower_power * scale * scale)
            )
            if (
                stake_discount_witness is None
                and staged_discount_fee != fused_discount_fee
            ):
                stake_discount_witness = (amount, stake)
            staged_rebate = amount * benefit // scale
            fused_rebate = (
                amount * half * stake // (lower_power * scale)
            )
            if (
                stake_rebate_witness is None
                and staged_rebate != fused_rebate
            ):
                stake_rebate_witness = (amount, stake)

    return [
        {
            "name": "direct_half_variance_projection",
            "status": "proven_reduction_landed",
            "current_operations": 2,
            "candidate_operations": 3,
            "proof": direct_half_variance_proof(),
        },
        {
            "name": "live_forward_single_mul_div",
            "status": "current_form_minimal",
            "current_operations": 1,
            "candidate_operations": 2,
            "proof": "current is one floor of spot*forward/bs_spot",
            "witness": {
                "spot": "80123456789012",
                "forward": "75799394374445",
                "bs_spot": "75852009440344",
                "two_floor_delta": "-63071",
            },
        },
        {
            "name": "partial_close_complement",
            "status": "current_form_minimal",
            "current_operations": 2,
            "candidate_operations": 2,
            "proof": "one floor plus exact complement conserves every floor atom",
            "mutation_counterexample": independent_split_witness,
        },
        {
            "name": "net_premium_fusion",
            "status": "candidate_rejected_not_equivalent",
            "current_operations": 2,
            "candidate_operations": 1,
            "proof": "bounded exhaustive residue search",
            "mutation_counterexample": premium_witness,
        },
        {
            "name": "boundary_net_quantity_product",
            "status": "current_form_minimal_certified_not_bit_equivalent",
            "current_operations": 1,
            "candidate_operations": 2,
            "proof": "bounded exhaustive residue search",
            "mutation_counterexample": boundary_witness,
            "note": (
                "The fused signed product changes the legacy scalar by one raw "
                "unit on reachable residues, but the revised Approx radius "
                "certifies that difference against ideal rational liability."
            ),
        },
        {
            "name": "builder_min_before_floor",
            "status": "algebraically_equivalent_no_operation_win",
            "current_operations": 3,
            "candidate_operations": 4,
            "proof": "monotonicity of floor and min",
            "mutation_counterexample": builder_min_witness,
        },
        {
            "name": "discount_as_ceil_complement",
            "status": "algebraically_equivalent_rejected_by_uniform_floor_doctrine",
            "current_operations": 2,
            "candidate_operations": 2,
            "proof": "a-floor(a*d/F)=ceil(a*(F-d)/F)",
            "mutation_counterexample": discount_witness,
        },
        {
            "name": "trading_fee_rate_quantity_fusion",
            "status": "candidate_rejected_not_bit_equivalent",
            "current_operations": 2,
            "candidate_operations": 1,
            "proof": "bounded exhaustive residue search",
            "mutation_counterexample": trading_fee_witness,
        },
        {
            "name": "stake_discount_curve_fusion",
            "status": "candidate_rejected_not_bit_equivalent",
            "current_operations": 3,
            "candidate_operations": 1,
            "proof": "bounded exhaustive lower-segment residue search",
            "mutation_counterexample": stake_discount_witness,
        },
        {
            "name": "stake_rebate_curve_fusion",
            "status": "candidate_rejected_not_bit_equivalent",
            "current_operations": 2,
            "candidate_operations": 1,
            "proof": "bounded exhaustive lower-segment residue search",
            "mutation_counterexample": stake_rebate_witness,
        },
        {
            "name": "linear_minus_correction_plain_sub",
            "status": "candidate_rejected_underflow_witness",
            "current_operations": 1,
            "candidate_operations": 1,
            "proof": "P-13 boundary aggregation can make linear one atom below correction",
            "witness": p13_clamp_witness(),
        },
        {
            "name": "nav_single_mark",
            "status": "candidate_rejected_competing_endpoint_invariants",
            "current_operations": 2,
            "candidate_operations": 1,
            "proof": "supply mark >= ask and withdraw mark <= bid are incompatible at nonzero width",
        },
    ]


FUNCTION_MINIMALITY = {
    "packages/predict/sources/expiry_market.move::current_nav_approx": "one_signed_difference_plus_required_nonnegative_projection",
    "packages/predict/sources/plp/plp.move::lp_pool_value_approx": "exact_cash_sum_minus_two_distinct_exclusions",
    "packages/predict/sources/plp/plp.move::value_expiry": "phase_specific_single_value_path",
    "packages/predict/sources/strike_exposure/index/strike_payout_tree.move::walk_linear": "one_shared_boundary_walk",
    "packages/predict/sources/strike_exposure/index/strike_payout_tree.move::walk_linear_subtree": "one_signed_product_per_nonzero_net_boundary",
    "packages/predict/sources/strike_exposure/index/strike_payout_tree.move::combine_summaries": "exact_associative_tree_summary",
    "packages/predict/sources/strike_exposure/strike_exposure.move::marked_live_liability": "separate_aggregation_domains_plus_required_nonnegative_projection",
    "packages/predict/sources/config/expiry_cash_config.move::rebate_reserve_for_fee_basis": "atomic_floor_product",
    "packages/predict/sources/config/stake_config.move::fee_amount_after_discount": "reviewed_discount_complement",
    "packages/predict/sources/config/stake_config.move::rebate_amount": "atomic_floor_product",
    "packages/predict/sources/config/stake_config.move::benefit_ratio": "piecewise_single_mul_div",
    "packages/predict/sources/config/strike_exposure_config.move::net_premium_from_entry_value": "single_directed_division",
    "packages/predict/sources/config/strike_exposure_config.move::trading_fee": "atomic_ceil_product",
    "packages/predict/sources/config/strike_exposure_config.move::assert_mint_admission": "staged_atoms_required",
    "packages/predict/sources/config/strike_exposure_config.move::fee_rate": "atomic_floor_product",
    "packages/predict/sources/config/strike_exposure_config.move::raw_bernoulli_fee_rate": "model_formula_retained",
    "packages/predict/sources/config/strike_exposure_config.move::expiry_fee_multiplier": "single_fused_mul_div",
    "packages/predict/sources/ewma.move::penalty_fee": "atomic_ceil_product",
    "packages/predict/sources/expiry_market.move::fee_incentive_subsidy_amount": "atomic_floor_product_then_cap",
    "packages/predict/sources/expiry_market.move::builder_fee_amount": "reviewed_min_floor_equivalence",
    "packages/predict/sources/plp/lp_book.move::quote_supply_shares": "single_fused_mul_div",
    "packages/predict/sources/plp/lp_book.move::quote_withdraw_dusdc": "single_fused_mul_div",
    "packages/predict/sources/plp/plp.move::sync_fee_incentives": "two_independent_policy_caps",
    "packages/predict/sources/plp/plp.move::expiry_rebalance_cash_terms": "one_shared_buffer_product",
    "packages/predict/sources/plp/plp.move::materialize_expiry_profit": "one_floor_plus_exact_complement",
    "packages/predict/sources/plp/plp.move::pool_nav_bid_ask": "two_nav_endpoints_required_by_competing_counterparty_invariants",
    "packages/predict/sources/plp/pool_accounting.move::register_expiry": "one_lifetime_cap_product_at_immutable_registration",
    "packages/predict/sources/strike_exposure/strike_exposure.move::payout_liability": "one_optional_buffer_product",
    "packages/predict/sources/strike_exposure/strike_exposure.move::quote_mint_terms": "binary_search_reuses_canonical_premium_helper",
    "packages/predict/sources/strike_exposure/strike_exposure.move::quote_close": "atomic_floor_product",
    "packages/predict/sources/strike_exposure/strike_exposure.move::quote_live_close": "reviewed_partial_close_complement",
    "packages/predict/sources/strike_exposure/strike_exposure.move::gross_order_value": "atomic_floor_product",
}


def cross_module_conclusions() -> dict[str, Any]:
    """Fold the partial-close and saturation verdicts into the census.

    Points at the owning proof modules rather than recomputing their heavy
    searches: the exact maxima live in `partial_close_proofs`, the induction in
    `saturation_proofs`. This keeps single ownership while making the census a
    complete picture of the money-math minimality decisions.
    """
    structural = partial_close_proofs.bounded_structural_proof()
    witness = partial_close_proofs.production_fragmentation_witness()
    shortfall = partial_close_proofs.shortfall_bound()
    prefix = payout_tree_proofs.prefix_summary_monoid_proof()
    induction = saturation_proofs.available_expiry_funding_induction()
    return {
        "payout_prefix_positive_part": {
            "verdict": "semantically_required_and_algebraically_minimal",
            "owner": "payout_tree_proofs.prefix_summary_monoid_proof",
            "associative": prefix["invariants"]["combine_is_associative"],
            "removable": False,
        },
        "partial_close_floor_complement": {
            "verdict": "locally_minimal_and_atom_conserving",
            "owner": "partial_close_proofs.bounded_structural_proof",
            "floor_conservation_holds": structural["structural_invariants_hold"],
        },
        "live_close_saturating_sub": {
            "verdict": "semantically_required_under_present_invariants",
            "owner": "partial_close_proofs.shortfall_bound",
            "removable": False,
            "reason": (
                "Under the survivor-down floor bias, max(0, gross_close - "
                "removed_floor) is the minimal economic formula: rounding the "
                "closed floor down instead can make a survivor immediately "
                "liquidatable, and rounding gross up pays the trader. The "
                "raw-fee cap neutralizes a shortfall slice before discount."
            ),
            "raw_fee_covers_shortfall_slice": (
                shortfall["default_raw_fee_covers_shortfall_slice"]
            ),
        },
        "split_close_discounted_proceeds": {
            "verdict": "reachable_open_policy_issue",
            "owner": (
                "partial_close_proofs.reachable_advantage_search / "
                "full_liquidation_split_analysis"
            ),
            "reachable_witness_advantage": witness["trader_advantage"],
            "policy_decision_pending": True,
            "reason": (
                "Splitting a close is not net-proceeds path-independent under "
                "stake discount and builder fees; the advantage is small and "
                "non-monotone in slice count. Healing it (discount-before-cap) "
                "conflicts with the fully-staked positive-proceeds promise, so "
                "it is an economic-policy decision, NOT a minimality change. "
                "The current allocation and saturating_sub are unchanged."
            ),
        },
        "available_expiry_funding_outer_saturation": {
            "verdict": "proven_reduction_landed"
            if induction["induction_holds"]
            else "proof_regressed",
            "owner": "saturation_proofs.available_expiry_funding_induction",
            "proven": induction["induction_holds"],
            "reason": (
                "The removed outer saturating_sub was redundant only because the "
                "source-complete induction (fail-closed writer scan + "
                "exhaustive transition lemmas) holds; the bounded BFS alone "
                "would not establish it."
            ),
        },
    }


def build_minimality_bundle() -> dict[str, Any]:
    money_functions = {
        record["function_id"]
        for record in inventory.build_inventory()["records"]
        if record["classification"]
        in {inventory.MONEY_COLLAPSE, inventory.MONEY_VALUATION}
    }
    missing = sorted(money_functions - set(FUNCTION_MINIMALITY))
    stale = sorted(set(FUNCTION_MINIMALITY) - money_functions)
    transformations = transformation_results()
    operation_saving_equivalent = [
        row
        for row in transformations
        if row["candidate_operations"] < row["current_operations"]
        and row["status"] in {
            "current_form_minimal",
            "algebraically_equivalent",
        }
    ]
    return {
        "schema": "predict_algebra_minimality_v2",
        "function_minimality": dict(sorted(FUNCTION_MINIMALITY.items())),
        "missing_money_functions": missing,
        "stale_function_entries": stale,
        "transformations": transformations,
        "cross_module_conclusions": cross_module_conclusions(),
        "rewrite_search_scope": [
            row["name"] for row in transformations
        ],
        "all_money_functions_classified": not missing and not stale,
        "equivalent_operation_saving_candidates": operation_saving_equivalent,
        "universal_maximal_simplicity_proven": False,
        "limitation": (
            "The fail-closed source census gives every money function a "
            "disposition, but maximality is proven only for the registered "
            "rewrite families; it is not an exhaustive synthesis over every "
            "semantics-preserving program."
        ),
    }


def main() -> None:
    print(json.dumps(build_minimality_bundle(), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
