#!/usr/bin/env python3
"""Require the clean-room rebuild's exact transitional predeploy debt set."""

from __future__ import annotations

import importlib.util
import re
import sys
from pathlib import Path
from types import ModuleType

TESTS = Path(__file__).resolve().parent
PREDICT = TESTS.parent
PREDEPLOY = PREDICT / "predeploy"

EXPECTED_MISSING_PINS = {
    ("RP-1", "finish_flush_with_zero_pool_nav_and_empty_queues_succeeds"),
    ("RP-1", "finish_flush_with_low_plp_price_and_empty_queues_succeeds"),
    ("RP-1", "finish_flush_with_high_plp_price_and_empty_queues_succeeds"),
    ("RP-2", "priced_supply_with_zero_pool_value_refunds"),
    ("RP-2", "priced_supply_that_rounds_to_zero_shares_refunds"),
    ("RP-2", "priced_withdraw_that_rounds_to_zero_payout_refunds"),
    ("RP-2", "supply_at_min_executable_plp_price_fills"),
    ("RP-2", "supply_below_min_executable_plp_price_refunds"),
    ("RP-2", "supply_at_max_executable_plp_price_fills"),
    ("RP-2", "supply_above_max_executable_plp_price_refunds"),
    ("RP-2", "oversized_supply_that_exceeds_u64_shares_refunds"),
    ("RP-2", "non_executable_supply_refunds_spend_supply_budget"),
    ("RP-2", "non_executable_withdraw_refunds_spend_withdraw_budget"),
    ("RP-2", "withdrawals_stop_when_idle_is_dry_and_carry"),
    ("RP-3", "finish_flush_with_zero_pool_nav_and_empty_queues_succeeds"),
    ("RP-4", "try_settle_without_exact_expiry_spot_returns_false_without_mutation"),
    ("RP-4", "expired_unsettled_standalone_rebalance_moves_no_cash"),
    ("RP-4", "explicit_settlement_unblocks_pool_valuation_sweep"),
    ("RP-9", "extreme_first_observation_suppresses_penalty_for_later_trades"),
    ("RP-9", "ewma_penalty_included_in_quote_and_mint_debits_exactly"),
    ("RP-9", "quote_matches_independent_costs_and_mint_debits_exactly_all_in_cost"),
    ("RP-11", "rebate_claim_requires_settled_market"),
    ("RP-11", "rebate_claim_with_open_position_aborts"),
    ("RP-11", "deauthorized_predict_app_blocks_permissionless_rebate_claim"),
    ("RP-11", "owner_auth_rebate_claim_survives_predict_app_deauth"),
    ("RP-11", "prepare_settled_loss_with_inactive_rebate_stake"),
    ("RP-12", "supply_limit_miss_carries_then_fills_when_mark_improves"),
    ("RP-12", "supply_limit_expires_after_three_misses"),
    ("RP-12", "withdraw_limit_miss_carries_then_fills_when_mark_improves"),
    ("RP-12", "withdraw_limit_expires_after_three_misses"),
    ("RP-13", "oversized_budget_saturates_at_the_lot_cap_without_aborting"),
    ("RP-13", "budget_mints_largest_fitting_quantity_and_debits_its_exact_cost"),
    ("RP-13", "budget_at_next_lot_premium_mints_the_next_lot"),
    ("RP-13", "budget_fill_below_min_quantity_aborts"),
    ("RP-13", "mint_exact_amount_below_min_quantity_aborts"),
    ("RP-14", "set_reference_tick_floors_spot_and_is_idempotent"),
    ("RP-14", "set_reference_tick_missing_exact_history_aborts"),
    ("RP-14", "set_reference_tick_wrong_pyth_feed_aborts"),
    ("RP-15", "price_memo_rejects_non_monotone_surface_over_active_ticks"),
    ("RP-15", "current_nav_rejects_non_monotone_active_book_surface"),
}

EXPECTED_WARNINGS = {
    "response-policies.md: names file `pool_valuation_flow_tests.move` not found under packages/predict/ or .claude/",
    "response-policies.md: names file `lp_book_tests.move` not found under packages/predict/ or .claude/",
    "response-policies.md: names file `settlement_flow_tests.move` not found under packages/predict/ or .claude/",
    "response-policies.md: names file `mint_exact_amount_tests.move` not found under packages/predict/ or .claude/",
    "response-policies.md: names file `reference_tick_tests.move` not found under packages/predict/ or .claude/",
    "response-policies.md: names file `pricing_guard_tests.move` not found under packages/predict/ or .claude/",
    "response-policies.md: names file `current_nav_flow_tests.move` not found under packages/predict/ or .claude/",
}
EXPECTED_UNCATALOGUED_POLICIES = {"RP-5", "RP-6", "RP-7", "RP-8", "RP-13"}
EXPECTED_NON_UNIT_POLICIES = {"RP-10"}


def load_predeploy_check() -> ModuleType:
    path = PREDEPLOY / "check.py"
    spec = importlib.util.spec_from_file_location("predict_predeploy_check", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def registered_policy_debt(
    register: str,
) -> tuple[set[tuple[str, str]], set[str], set[str]]:
    check = load_predeploy_check()
    pins = set()
    uncatalogued = set()
    non_unit = set()
    for entry in re.split(r"^## ", register, flags=re.MULTILINE)[1:]:
        title = entry.splitlines()[0]
        policy = re.match(r"(RP-\d+):", title)
        if not policy:
            continue
        block = re.search(
            r"\*\*Pinning tests[^*]*\*\*(.*?)(?=\n- \*\*|\n## |\Z)",
            entry,
            re.DOTALL,
        )
        if not block:
            continue
        body = block.group(1)
        normalized_body = " ".join(body.lower().split())
        if "not yet catalogued" in normalized_body:
            if "not pinnable in move unit tests by nature" in normalized_body:
                non_unit.add(policy.group(1))
            else:
                uncatalogued.add(policy.group(1))
            continue
        tokens = check.pinning_test_functions_from_block(body)
        if "untested" in normalized_body:
            uncatalogued.add(policy.group(1))
        for token in tokens:
            pins.add((policy.group(1), token))
    return pins, uncatalogued, non_unit


def registered_pins(register: str) -> set[tuple[str, str]]:
    return registered_policy_debt(register)[0]


def current_policy_debt() -> tuple[set[tuple[str, str]], set[str], set[str]]:
    register = (PREDEPLOY / "response-policies.md").read_text()
    pins, uncatalogued, non_unit = registered_policy_debt(register)
    check = load_predeploy_check()
    functions = set()
    for path in TESTS.rglob("*.move"):
        functions.update(check.executable_test_functions_from_source(path.read_text()))
    missing = {(policy, function) for policy, function in pins if function not in functions}
    return missing, uncatalogued, non_unit


def current_missing_pins() -> set[tuple[str, str]]:
    return current_policy_debt()[0]


def classify_pin_checker_findings(
    findings: list[str],
    missing_pins: set[tuple[str, str]],
) -> list[str]:
    errors = []
    reported_missing = set()
    for finding in findings:
        match = re.search(
            r"entry '(RP-\d+):.*' pins test `([^`]+)` but no executable",
            finding,
        )
        if match:
            reported_missing.add((match.group(1), match.group(2)))
        else:
            errors.append(finding)
    if reported_missing != missing_pins:
        errors.append(
            "predeploy pin parser disagrees with executable debt: "
            f"checker_only={sorted(reported_missing - missing_pins)} "
            f"debt_only={sorted(missing_pins - reported_missing)}"
        )
    return errors


def current_non_pin_findings(
    missing_pins: set[tuple[str, str]],
) -> tuple[list[str], list[str]]:
    check = load_predeploy_check()
    errors, warnings = check.run_checks()
    return classify_pin_checker_findings(errors, missing_pins), warnings


def debt_errors(
    missing_pins: set[tuple[str, str]],
    uncatalogued_policies: set[str],
    non_unit_policies: set[str],
    non_pin_errors: list[str],
    warnings: set[str],
) -> list[str]:
    errors = [f"unexpected predeploy fatal: {error}" for error in non_pin_errors]
    for policy, function in sorted(missing_pins - EXPECTED_MISSING_PINS):
        errors.append(f"unexpected missing pin: {policy}::{function}")
    for policy, function in sorted(EXPECTED_MISSING_PINS - missing_pins):
        errors.append(f"resolved pin remains in expected debt: {policy}::{function}")
    for policy in sorted(uncatalogued_policies - EXPECTED_UNCATALOGUED_POLICIES):
        errors.append(f"unexpected uncatalogued policy: {policy}")
    for policy in sorted(EXPECTED_UNCATALOGUED_POLICIES - uncatalogued_policies):
        errors.append(f"resolved policy remains in expected uncatalogued debt: {policy}")
    for policy in sorted(non_unit_policies - EXPECTED_NON_UNIT_POLICIES):
        errors.append(f"unexpected non-unit policy exemption: {policy}")
    for policy in sorted(EXPECTED_NON_UNIT_POLICIES - non_unit_policies):
        errors.append(f"expected non-unit policy exemption changed or disappeared: {policy}")
    for warning in sorted(warnings - EXPECTED_WARNINGS):
        errors.append(f"unexpected predeploy warning: {warning}")
    for warning in sorted(EXPECTED_WARNINGS - warnings):
        errors.append(f"resolved warning remains in expected debt: {warning}")
    return errors


def main() -> int:
    missing_pins, uncatalogued_policies, non_unit_policies = current_policy_debt()
    non_pin_errors, warnings = current_non_pin_findings(missing_pins)
    errors = debt_errors(
        missing_pins,
        uncatalogued_policies,
        non_unit_policies,
        non_pin_errors,
        set(warnings),
    )
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        print(f"Predict predeploy debt: {len(errors)} error(s)")
        return 1
    print(
        "Predict predeploy debt: ok "
        f"({len(missing_pins)} missing registered pin obligations, "
        f"{len(uncatalogued_policies)} uncatalogued policies, "
        f"{len(non_unit_policies)} non-unit policy exemption, {len(warnings)} warnings)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
