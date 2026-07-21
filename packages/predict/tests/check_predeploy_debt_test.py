#!/usr/bin/env python3
"""Regression tests for the transitional Predict predeploy debt check."""

import unittest

import check_predeploy_debt as debt


class RegisteredPinTests(unittest.TestCase):
    def test_shared_function_pins_remain_distinct_policy_obligations(self) -> None:
        register = """
## RP-1: First
- **Pinning tests:** `shared_function_name`
## RP-3: Third
- **Pinning tests:** `shared_function_name`
"""
        self.assertEqual(
            debt.registered_pins(register),
            {
                ("RP-1", "shared_function_name"),
                ("RP-3", "shared_function_name"),
            },
        )

    def test_support_helpers_and_comments_cannot_satisfy_policy_pins(self) -> None:
        check = debt.load_predeploy_check()
        source = """
module deepbook_predict::masking_tests;
// #[test] fun commented_pin() {}
fun support_pin() {}
#[test] fun positive_pin() { assert!(true); }
#[test, expected_failure(abort_code = 7)] fun abort_pin() { abort 7 }
"""
        self.assertEqual(
            check.executable_test_selectors_from_source(source),
            {"masking_tests::positive_pin", "masking_tests::abort_pin"},
        )

    def test_public_entry_test_can_satisfy_policy_pin(self) -> None:
        check = debt.load_predeploy_check()
        source = (
            "module deepbook_predict::entry_tests;\n"
            "#[test] public entry fun public_entry_pin() { assert!(true); }"
        )
        self.assertEqual(
            check.executable_test_selectors_from_source(source),
            {"entry_tests::public_entry_pin"},
        )

    def test_qualified_test_pin_is_extracted_but_source_function_reference_is_not(self) -> None:
        check = debt.load_predeploy_check()
        block = (
            "`mint_redeem_guard_tests::mint_exact_amount_below_min_quantity_aborts`; "
            "`expiry_market::claim_trading_loss_rebate`"
        )
        self.assertEqual(
            check.pinning_test_selectors_from_block(block),
            ["mint_redeem_guard_tests::mint_exact_amount_below_min_quantity_aborts"],
        )

    def test_string_literal_cannot_fake_executable_policy_pin(self) -> None:
        check = debt.load_predeploy_check()
        source = 'fun helper() { let fake = b"#[test] fun fake_pin() {}"; }'
        self.assertEqual(check.executable_test_selectors_from_source(source), set())

    def test_policy_gap_kinds_are_classified_separately(self) -> None:
        register = """
## RP-5: Missing policy evidence
- **Pinning tests:** not yet catalogued — fill in when touched.
## RP-10: Platform behavior
- **Pinning tests:** not yet catalogued — platform behavior, not pinnable in Move unit tests by nature.
## RP-13: Partial policy evidence
- **Pinning tests:** `existing_policy_pin`; untested — gap: another boundary.
"""
        self.assertEqual(
            debt.registered_policy_debt(register),
            ({("RP-13", "existing_policy_pin")}, {"RP-5", "RP-13"}, {"RP-10"}),
        )

    def test_untested_only_marker_is_uncatalogued_debt(self) -> None:
        register = """
## RP-99: New gap
- **Pinning tests:** untested — gap.
"""
        self.assertEqual(
            debt.registered_policy_debt(register),
            (set(), {"RP-99"}, set()),
        )


class ExactDebtTests(unittest.TestCase):
    def test_unreachable_pin_branch_manifest_requires_registered_executable_boundaries(self) -> None:
        pins = set(debt.EXPECTED_UNREACHABLE_PIN_BRANCHES)
        functions = {function for _, function in pins}
        self.assertEqual(debt.pin_gap_manifest_errors("unreachable", pins, pins, functions), [])
        policy, function = next(iter(pins))
        self.assertTrue(
            debt.pin_gap_manifest_errors(
                "unreachable",
                pins,
                pins - {(policy, function)},
                functions - {function},
            )
        )

    def test_accumulator_delivery_gap_manifest_requires_registered_executable_pins(self) -> None:
        pins = set(debt.EXPECTED_ACCUMULATOR_DELIVERY_GAPS)
        functions = {function for _, function in pins}
        self.assertEqual(debt.pin_gap_manifest_errors("delivery", pins, pins, functions), [])

    def test_register_schema_error_is_not_treated_as_expected_missing_debt(self) -> None:
        findings = [
            "response-policies.md entry 'RP-99: New policy' has no 'Pinning tests' field"
        ]
        self.assertEqual(
            debt.classify_pin_checker_findings(findings, set()),
            findings,
        )

    def test_strict_checker_and_debt_parser_must_agree(self) -> None:
        findings = [
            "response-policies.md entry 'RP-1: Propbook's policy' pins test `missing_pin_name` "
            "but no executable `fun missing_pin_name` exists under packages/predict/tests/"
        ]
        self.assertEqual(
            debt.classify_pin_checker_findings(
                findings,
                {("RP-1", "missing_pin_name")},
            ),
            [],
        )

    def test_unexpected_missing_pin_is_rejected(self) -> None:
        missing = set(debt.EXPECTED_MISSING_PINS)
        missing.add(("RP-99", "new_unimplemented_pin"))
        self.assertTrue(
            any(
                "unexpected missing pin" in error
                for error in debt.debt_errors(
                    missing,
                    set(debt.EXPECTED_UNCATALOGUED_POLICIES),
                    set(debt.EXPECTED_NON_UNIT_POLICIES),
                    [],
                    set(debt.EXPECTED_WARNINGS),
                )
            )
        )

    def test_resolved_pin_requires_manifest_to_shrink(self) -> None:
        # The live manifest is empty, so prove the shrink guard against a
        # synthetic expected pin whose obligation no longer exists.
        original = debt.EXPECTED_MISSING_PINS
        debt.EXPECTED_MISSING_PINS = {("RP-99", "already_landed_pin")}
        try:
            self.assertTrue(
                any(
                    "resolved pin remains" in error
                    for error in debt.debt_errors(
                        set(),
                        set(debt.EXPECTED_UNCATALOGUED_POLICIES),
                        set(debt.EXPECTED_NON_UNIT_POLICIES),
                        [],
                        set(debt.EXPECTED_WARNINGS),
                    )
                )
            )
        finally:
            debt.EXPECTED_MISSING_PINS = original

    def test_new_uncatalogued_policy_is_rejected(self) -> None:
        uncatalogued = set(debt.EXPECTED_UNCATALOGUED_POLICIES) | {"RP-99"}
        errors = debt.debt_errors(
            set(debt.EXPECTED_MISSING_PINS),
            uncatalogued,
            set(debt.EXPECTED_NON_UNIT_POLICIES),
            [],
            set(debt.EXPECTED_WARNINGS),
        )
        self.assertTrue(any("unexpected uncatalogued policy" in error for error in errors))

    def test_exact_debt_is_accepted(self) -> None:
        self.assertEqual(
            debt.debt_errors(
                set(debt.EXPECTED_MISSING_PINS),
                set(debt.EXPECTED_UNCATALOGUED_POLICIES),
                set(debt.EXPECTED_NON_UNIT_POLICIES),
                [],
                set(debt.EXPECTED_WARNINGS),
            ),
            [],
        )


class KnownRedTests(unittest.TestCase):
    TEST = "deepbook_predict::scope_flow__intent_accounting__pool_tests::finding_is_live"

    def row(self) -> debt.KnownRed:
        return debt.KnownRed(self.TEST, "P-8", "Phase 7", "Order-dependent split")

    def test_plain_test_catalog_excludes_expected_failures_and_random_tests(self) -> None:
        source = f"""
module deepbook_predict::scope_flow__intent_accounting__pool_tests;
#[test] fun finding_is_live() {{ assert!(false); }}
#[test, expected_failure] fun normalized_red() {{ abort 1 }}
#[random_test] fun randomized_red() {{ abort 1 }}
"""
        self.assertEqual(debt.plain_tests_from_source(source), {self.TEST})

    def test_manifest_open_item_and_plain_test_form_exact_bijection(self) -> None:
        self.assertEqual(
            debt.known_red_bijection_errors(
                (self.row(),),
                {"P-8": self.TEST},
                {self.TEST},
            ),
            [],
        )

    def test_bijection_rejects_orphans_in_each_direction(self) -> None:
        errors = debt.known_red_bijection_errors(
            (self.row(),),
            {"P-13": self.TEST},
            set(),
        )
        self.assertTrue(any("no live plain" in error for error in errors))
        self.assertTrue(any("manifest/open-item mismatch" in error for error in errors))
        self.assertTrue(any("no matching manifest" in error for error in errors))

    def test_open_item_fields_are_owned_by_their_heading(self) -> None:
        text = f"""
### P-8: Finding
**Known RED test:** `{self.TEST}`
### H-7: Coverage
**Deferred test:** `deepbook_predict::scope_flow__intent_guard__pool_tests::later`
"""
        self.assertEqual(
            debt.open_item_test_fields(text),
            (
                {"P-8": self.TEST},
                {"H-7": "deepbook_predict::scope_flow__intent_guard__pool_tests::later"},
            ),
        )

    def test_acceptance_requires_exact_failing_set(self) -> None:
        output = f"[ FAIL    ] {self.TEST}\nTest result: FAILED. Total tests: 1; passed: 0; failed: 1\n"
        self.assertEqual(debt.known_red_acceptance_errors(1, output, {self.TEST}), [])
        self.assertTrue(
            any(
                "unlisted" in error
                for error in debt.known_red_acceptance_errors(1, output, set())
            )
        )
        self.assertTrue(
            any(
                "stale" in error
                for error in debt.known_red_acceptance_errors(
                    0,
                    "Test result: OK. Total tests: 1; passed: 1; failed: 0\n",
                    {self.TEST},
                )
            )
        )

    def test_nonterminal_move_output_cannot_pass_an_empty_manifest(self) -> None:
        self.assertEqual(
            debt.known_red_acceptance_errors(1, "error[E04001]: build failed", set()),
            ["Move test output has no parseable terminal test result"],
        )

    def test_zero_test_run_cannot_pass_an_empty_manifest(self) -> None:
        errors = debt.known_red_acceptance_errors(
            0,
            "Test result: OK. Total tests: 0; passed: 0; failed: 0\n",
            set(),
        )
        self.assertTrue(any("zero tests" in error for error in errors))

    def test_failure_summary_must_match_emitted_failure_rows(self) -> None:
        output = (
            f"[ FAIL    ] {self.TEST}\n"
            "Test result: FAILED. Total tests: 2; passed: 0; failed: 2\n"
        )
        errors = debt.known_red_acceptance_errors(1, output, {self.TEST})
        self.assertTrue(any("emitted 1 failure rows" in error for error in errors))

    def test_registered_known_red_is_clean_but_registered_deferral_is_fatal(self) -> None:
        check = debt.load_predeploy_check()
        register = """
## RP-8: Finding
- **Pinning tests:** `finding_is_live`
"""
        rows = [{"test": self.TEST, "open_item": "P-8"}]
        self.assertEqual(
            check.known_red_policy_errors(
                register,
                rows,
                {"P-8": self.TEST},
                {},
            ),
            [],
        )
        errors = check.known_red_policy_errors(
            register,
            rows,
            {"P-8": self.TEST},
            {"H-7": self.TEST},
        )
        self.assertTrue(any("owner sign-off required" in error for error in errors))

    def test_qualified_registered_pin_cannot_attach_to_same_leaf_in_another_module(self) -> None:
        check = debt.load_predeploy_check()
        register = """
## RP-8: Finding
- **Pinning tests:** `registered_tests::finding_is_live`
"""
        wrong_test = (
            "deepbook_predict::scope_flow__intent_accounting__other_tests::finding_is_live"
        )
        rows = [{"test": wrong_test, "open_item": "P-8"}]
        self.assertEqual(
            check.known_red_policy_errors(
                register,
                rows,
                {"P-8": wrong_test},
                {"H-7": wrong_test},
            ),
            [],
        )

    def test_qualified_registered_pin_matches_only_its_module(self) -> None:
        check = debt.load_predeploy_check()
        register = """
## RP-8: Finding
- **Pinning tests:** `registered_tests::finding_is_live`
"""
        registered_test = "deepbook_predict::registered_tests::finding_is_live"
        errors = check.known_red_policy_errors(
            register,
            [{"test": registered_test, "open_item": "P-8"}],
            {},
            {"H-7": registered_test},
        )
        self.assertTrue(any("open-item disposition" in error for error in errors))
        self.assertTrue(any("owner sign-off required" in error for error in errors))


class QualifiedPinCollisionTests(unittest.TestCase):
    """A same-named test in the wrong module must not satisfy a policy pin, and a
    bare-leaf pin whose leaf exists in two modules is a fatal ambiguity."""

    def test_executable_selectors_are_module_qualified(self) -> None:
        check = debt.load_predeploy_check()
        source = "module deepbook_predict::right_module_tests;\n#[test] fun same_leaf() { assert!(x); }"
        self.assertEqual(
            check.executable_test_selectors_from_source(source),
            {"right_module_tests::same_leaf"},
        )

    def test_qualified_pin_not_satisfied_by_wrong_module_same_leaf(self) -> None:
        check = debt.load_predeploy_check()
        # Only wrong_module defines `same_leaf`; the pin names right_module::same_leaf.
        self.assertIsNotNone(
            check.unresolved_pin(
                "right_module_tests::same_leaf",
                {"wrong_module_tests::same_leaf"},
                {"same_leaf": {"wrong_module_tests"}},
            )
        )
        # The correct module's exact selector resolves.
        self.assertIsNone(
            check.unresolved_pin(
                "right_module_tests::same_leaf",
                {"right_module_tests::same_leaf"},
                {"same_leaf": {"right_module_tests"}},
            )
        )

    def test_bare_leaf_pin_in_two_modules_is_ambiguous(self) -> None:
        check = debt.load_predeploy_check()
        problem = check.unresolved_pin("same_leaf", set(), {"same_leaf": {"a_tests", "b_tests"}})
        self.assertIsNotNone(problem)
        self.assertIn("ambiguous", problem)

    def test_bare_leaf_pin_unique_leaf_resolves(self) -> None:
        check = debt.load_predeploy_check()
        self.assertIsNone(
            check.unresolved_pin("same_leaf", set(), {"same_leaf": {"only_tests"}})
        )

    def test_bare_leaf_pin_missing_leaf_is_unresolved(self) -> None:
        check = debt.load_predeploy_check()
        problem = check.unresolved_pin("missing_leaf", set(), {})
        self.assertIsNotNone(problem)
        self.assertIn("no executable", problem)


if __name__ == "__main__":
    unittest.main()
