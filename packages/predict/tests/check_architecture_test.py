#!/usr/bin/env python3
"""Regression tests for deterministic Predict test-architecture checks."""

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


if __name__ == "__main__":
    unittest.main()
