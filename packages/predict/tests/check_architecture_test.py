#!/usr/bin/env python3
"""Regression tests for deterministic Predict test-architecture checks."""

import re
import unittest

import check_architecture as architecture


class SourceBoundaryTests(unittest.TestCase):
    def test_comments_do_not_create_executable_tests(self) -> None:
        errors = architecture.source_boundary_errors(
            "packages/predict/sources/example.move",
            "// #[test]\n/* #[random_test] */\npublic fun production() {}",
        )
        self.assertEqual(errors, [])

    def test_executable_test_is_rejected_in_any_attribute_position(self) -> None:
        for attribute in (
            "#[test]",
            "#[expected_failure(abort_code = 1), test]",
            "#[test_only, random_test]",
        ):
            with self.subTest(attribute=attribute):
                errors = architecture.source_boundary_errors(
                    "packages/predict/sources/example.move",
                    f"{attribute}\nfun source_test() {{}}",
                )
                self.assertTrue(any("executable unit tests" in error for error in errors))

    def test_public_entry_test_is_rejected_in_production_source(self) -> None:
        errors = architecture.source_boundary_errors(
            "packages/predict/sources/example.move",
            "#[test]\npublic entry fun source_test() {}",
        )
        self.assertTrue(any("executable unit tests" in error for error in errors))

    def test_approved_test_only_seam_is_accepted(self) -> None:
        errors = architecture.source_boundary_errors(
            "packages/account/sources/account_registry.move",
            "#[test_only]\npublic fun init_for_testing(ctx: &mut TxContext) {}",
        )
        self.assertEqual(errors, [])

    def test_new_test_only_or_named_seam_is_rejected(self) -> None:
        for source in (
            "#[test_only]\npublic(package) fun new_seam() {}",
            "public(package) fun shortcut_for_testing() {}",
        ):
            with self.subTest(source=source):
                errors = architecture.source_boundary_errors(
                    "packages/predict/sources/example.move",
                    source,
                )
                self.assertTrue(any("requires explicit approval" in error for error in errors))

    def test_stale_approved_seam_is_rejected(self) -> None:
        errors = architecture.source_boundary_errors(
            "packages/predict/sources/strike_exposure/range_codec.move",
            "public fun strike_from_tick() {}",
        )
        self.assertTrue(any("approved source test seam" in error for error in errors))

    def test_deleted_approved_seam_file_is_rejected(self) -> None:
        source_paths = set(architecture.APPROVED_SOURCE_TEST_SEAMS)
        deleted = "packages/predict/sources/strike_exposure/range_codec.move"
        source_paths.remove(deleted)
        self.assertEqual(architecture.missing_approved_source_paths(source_paths), [deleted])


class ScenarioBoundaryTests(unittest.TestCase):
    def test_supported_scenario_constructor_forms_are_counted(self) -> None:
        cases = (
            "use sui::test_scenario; fun f() { test_scenario::begin(@0xA); }",
            "use sui::test_scenario as scenario; fun f() { scenario::begin(@0xA); }",
            "use sui::test_scenario::begin; fun f() { begin(@0xA); }",
            "use sui::test_scenario::begin as start; fun f() { start(@0xA); }",
            "use sui::test_scenario::{begin}; fun f() { begin(@0xA); }",
            "use sui::test_scenario::{begin as start}; fun f() { start(@0xA); }",
            "use sui::test_scenario::{Self as scenario}; fun f() { scenario::begin(@0xA); }",
        )
        for source in cases:
            with self.subTest(source=source):
                self.assertTrue(architecture.accesses_scenario_api(source))
                self.assertEqual(architecture.scenario_constructor_count(source), 1)

    def test_second_constructor_is_counted(self) -> None:
        source = "fun f() { test_scenario::begin(@0xA); test_scenario::begin(@0xB); }"
        self.assertEqual(architecture.scenario_constructor_count(source), 2)

    def test_benign_scenario_inventory_helpers_are_allowed(self) -> None:
        source = "use sui::test_scenario::{return_shared, take_shared_by_id};"
        self.assertFalse(architecture.accesses_scenario_api(source))

    def test_scenario_field_name_does_not_affect_ownership_detection(self) -> None:
        self.assertEqual(
            architecture.scenario_field_count("public struct Owner { renamed: Scenario }"),
            1,
        )

    def test_every_grouped_import_is_checked_for_scenario_access(self) -> None:
        source = """
            use sui::test_scenario::{return_shared};
            use sui::test_scenario::{Self as scenario};
            fun hidden() { scenario::begin(@0xA); }
        """
        self.assertTrue(architecture.accesses_scenario_api(source))

    def test_comments_do_not_create_hidden_scenario_or_transaction_access(self) -> None:
        source = architecture.source_without_comments(
            "// test_scenario::begin(@0xA);\n/* helper.next_tx(@0xB); */\nfun helper() {}"
        )
        self.assertFalse(architecture.accesses_scenario_api(source))
        self.assertIsNone(re.search(r"(?:\.|::)next_tx\s*\(", source))

    def test_world_constructor_aliases_are_counted_per_test(self) -> None:
        source = """
            use deepbook_predict::test_world::{Self as world, new as create_world};
            #[test]
            fun duplicate() {
                let first = world::new(@0x0, @0xA, 1);
                let second = create_world(@0x0, @0xA, 2);
            }
        """
        stripped = architecture.source_without_comments(source)
        aliases = architecture.world_constructor_aliases(stripped)
        functions = architecture.attributed_test_bodies(stripped)
        self.assertEqual(len(functions), 1)
        self.assertEqual(architecture.world_constructor_count(functions[0][1], aliases), 2)

    def test_transaction_progression_in_helper_body_remains_visible(self) -> None:
        source = architecture.source_without_comments(
            """
            #[test]
            fun visible() { world.next_tx(@0xB); }
            fun hidden(world: &mut World) { world.next_tx(@0xC); }
            """
        )
        outside = architecture.source_outside_test_bodies(source)
        self.assertIsNotNone(re.search(r"(?:\.|::)next_tx\s*\(", outside))

    def test_transaction_progression_in_test_body_is_removed(self) -> None:
        source = architecture.source_without_comments(
            "#[test]\nfun visible() { world.next_tx(@0xB); }"
        )
        outside = architecture.source_outside_test_bodies(source)
        self.assertIsNone(re.search(r"(?:\.|::)next_tx\s*\(", outside))

    def test_commented_module_cannot_steer_taxonomy_input(self) -> None:
        source = architecture.source_without_comments(
            "// module deepbook_predict::flow_fake_behavior_tests;\n"
            "module deepbook_predict::mechanics_real_behavior_tests;"
        )
        module = re.search(r"module\s+deepbook_predict::([a-z0-9_]+)\s*;", source)
        self.assertIsNotNone(module)
        assert module is not None
        self.assertEqual(module.group(1), "mechanics_real_behavior_tests")


class TaxonomyTests(unittest.TestCase):
    def test_exact_scope_and_intent_are_accepted(self) -> None:
        self.assertEqual(
            architecture.taxonomy_errors(
                "packages/predict/tests/mechanics/example.move",
                "mechanics",
                "scope_mechanics__intent_boundary__order_tests",
            ),
            [],
        )

    def test_ambiguous_or_legacy_taxonomy_is_rejected(self) -> None:
        for module in (
            "mechanics_order_boundary_tests",
            "scope_mechanics__intent_boundary__intent_rounding__order_tests",
            "scope_mechanics__intent_boundary__scope_flow__tests",
            "scope_mechanics__intent_boundary__intent_rounding__tests",
        ):
            with self.subTest(module=module):
                self.assertTrue(
                    architecture.taxonomy_errors(
                        "packages/predict/tests/mechanics/example.move",
                        "mechanics",
                        module,
                    )
                )

    def test_declared_scope_must_match_path(self) -> None:
        self.assertTrue(
            architecture.taxonomy_errors(
                "packages/predict/tests/flow/example.move",
                "flow",
                "scope_structure__intent_behavior__market_tests",
            )
        )

    def test_reserved_markers_are_rejected_outside_module_segment(self) -> None:
        source = (
            "module deepbook_predict::scope_mechanics__intent_rounding__stake_config_tests;\n"
            "#[test] fun scope_flow__collision() { assert!(true); }"
        )
        module_match = re.search(
            r"module\s+deepbook_predict::([a-z0-9_]+)\s*;",
            source,
        )
        self.assertIsNotNone(module_match)
        assert module_match is not None
        self.assertTrue(
            architecture.reserved_taxonomy_marker_errors(
                "packages/predict/tests/mechanics/example.move",
                source,
                module_match,
            )
        )

    def test_selector_markers_ignore_subject_words_in_test_names(self) -> None:
        executable_tests = [
            (
                "mechanics",
                "rounding",
                "scope_mechanics__intent_rounding__stake_config_tests",
                ("rebate_first_positive_boundary_is_exact",),
            ),
            (
                "mechanics",
                "boundary",
                "scope_mechanics__intent_boundary__range_codec_tests",
                ("prefix_limit_rounds_strict_settlement_boundary_up",),
            ),
            (
                "structure",
                "guard",
                "scope_structure__intent_guard__oracle_tests",
                ("set_reference_tick_missing_exact_history_aborts",),
            ),
            (
                "mechanics",
                "reference",
                "scope_mechanics__intent_reference__pricing_tests",
                ("synthetic_profiles_stay_within_independent_precision_contract",),
            ),
        ]
        self.assertEqual(
            architecture.selected_modules(executable_tests, "intent_boundary__"),
            {"scope_mechanics__intent_boundary__range_codec_tests"},
        )
        self.assertEqual(
            architecture.selected_modules(executable_tests, "intent_reference__"),
            {"scope_mechanics__intent_reference__pricing_tests"},
        )
        self.assertEqual(architecture.selection_errors(executable_tests), [])


class AssertionPresenceTests(unittest.TestCase):
    def test_successful_test_requires_direct_assertion(self) -> None:
        source = architecture.source_without_comments(
            "#[test] fun delegated() { assert_result(); }\n"
            "fun assert_result() { assert!(true); }"
        )
        self.assertTrue(
            architecture.successful_test_assertion_errors("example.move", source)
        )

    def test_public_entry_test_requires_direct_assertion(self) -> None:
        source = architecture.source_without_comments(
            "#[test] public entry fun delegated() { support(); }"
        )
        self.assertTrue(
            architecture.successful_test_assertion_errors("example.move", source)
        )

    def test_assertion_text_inside_byte_string_does_not_satisfy_test(self) -> None:
        source = architecture.source_without_comments(
            '#[test] fun delegated() { let message = b"assert!(false)"; support(); }'
        )
        self.assertTrue(
            architecture.successful_test_assertion_errors("example.move", source)
        )

    def test_brace_inside_byte_string_does_not_truncate_test_body(self) -> None:
        source = architecture.source_without_comments(
            '#[test] fun observed() { let message = b"}"; assert!(true); }'
        )
        self.assertEqual(
            architecture.successful_test_assertion_errors("example.move", source),
            [],
        )

    def test_direct_assertion_and_expected_failure_are_accepted(self) -> None:
        source = architecture.source_without_comments(
            "#[test] fun observed() { assert_eq!(value(), 1); }\n"
            "#[test, expected_failure(abort_code = 7)] fun aborts() { fail(); }"
        )
        self.assertEqual(
            architecture.successful_test_assertion_errors("example.move", source),
            [],
        )


if __name__ == "__main__":
    unittest.main()
