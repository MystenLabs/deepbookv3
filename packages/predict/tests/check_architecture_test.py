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
                "mechanics_order_boundary_tests",
            ),
            [],
        )

    def test_extra_scope_or_intent_is_rejected(self) -> None:
        for module in (
            "mechanics_flow_order_boundary_tests",
            "mechanics_order_boundary_rounding_tests",
        ):
            with self.subTest(module=module):
                self.assertTrue(
                    architecture.taxonomy_errors(
                        "packages/predict/tests/mechanics/example.move",
                        "mechanics",
                        module,
                    )
                )


if __name__ == "__main__":
    unittest.main()
