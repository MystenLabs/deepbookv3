#!/usr/bin/env python3
"""Regression tests for the committed Predict pricing-reference generator."""

from dataclasses import replace
import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import patch


GENERATOR_PATH = Path(__file__).parent / "reference" / "generate_pricing_reference.py"
SPEC = importlib.util.spec_from_file_location("generate_pricing_reference", GENERATOR_PATH)
assert SPEC is not None and SPEC.loader is not None
generator = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = generator
SPEC.loader.exec_module(generator)


class ProfileValidationTests(unittest.TestCase):
    def test_non_identity_reanchor_has_independently_checked_forward(self) -> None:
        profile = generator.PROFILES[1]
        self.assertEqual(profile.pyth_spot, 102_000_000_000)
        self.assertEqual(profile.bs_spot, 100_000_000_000)
        self.assertEqual(profile.bs_forward, 101_000_000_000)
        # 102 * (101 / 100) = 103.02, scaled by 1e9.
        self.assertEqual(generator.live_forward(profile), 103_020_000_000)

    def test_profile_names_must_be_unique(self) -> None:
        duplicate = replace(generator.PROFILES[1], name=generator.PROFILES[0].name)
        with patch.object(generator, "PROFILES", (generator.PROFILES[0], duplicate)):
            with self.assertRaisesRegex(ValueError, "duplicate profile name"):
                generator.validate_profile_sequence()

    def test_strikes_must_be_aligned_unique_and_ordered(self) -> None:
        invalid_strikes = (
            (80_000_000_001,),
            (90_000_000_000, 90_000_000_000),
            (100_000_000_000, 90_000_000_000),
        )
        for strikes in invalid_strikes:
            with self.subTest(strikes=strikes):
                profile = replace(generator.PROFILES[1], strikes=strikes)
                with patch.object(generator, "PROFILES", (profile,)):
                    with self.assertRaises(ValueError):
                        generator.validate_profile_sequence()


if __name__ == "__main__":
    unittest.main()
