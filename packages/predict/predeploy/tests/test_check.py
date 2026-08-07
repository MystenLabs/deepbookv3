from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest import mock


CHECK_PATH = Path(__file__).resolve().parents[1] / "check.py"
SPEC = importlib.util.spec_from_file_location("predict_predeploy_check", CHECK_PATH)
assert SPEC and SPEC.loader
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)


class PredeployCheckTests(unittest.TestCase):
    def test_dead_path_check_excludes_immutable_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            predeploy = root / "packages" / "predict" / "predeploy"
            evidence = predeploy / "evidence"
            evidence.mkdir(parents=True)
            (predeploy / "open-items.md").write_text(
                "Current `ts/strategies/missing-live.ts`.\n"
            )
            (evidence / "run.md").write_text(
                "Historical `ts/strategies/missing-at-audited-sha.ts`.\n"
            )
            errors: list[str] = []
            warnings: list[str] = []

            with (
                mock.patch.object(check, "HERE", str(predeploy)),
                mock.patch.object(check, "PREDICT", str(predeploy.parent)),
                mock.patch.object(check, "PROPBOOK", str(root / "packages" / "propbook")),
                mock.patch.object(check, "ROOT", str(root)),
            ):
                check.check_paths(errors, warnings)

            self.assertEqual(
                errors,
                [
                    "open-items.md: names path "
                    "`ts/strategies/missing-live.ts` which does not exist"
                ],
            )
            self.assertEqual(warnings, [])

    def test_propbook_path_check_is_confined_to_the_fixture_root(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            predict = root / "packages" / "predict"
            propbook = root / "packages" / "propbook"
            predeploy = predict / "predeploy"
            predeploy.mkdir(parents=True)
            (predeploy / "open-items.md").write_text("Current `registry_tests.move`.\n")
            errors: list[str] = []
            warnings: list[str] = []

            with (
                mock.patch.object(check, "HERE", str(predeploy)),
                mock.patch.object(check, "PREDICT", str(predict)),
                mock.patch.object(check, "PROPBOOK", str(propbook)),
                mock.patch.object(check, "ROOT", str(root)),
            ):
                check.check_paths(errors, warnings)

            self.assertEqual(errors, [])
            self.assertEqual(
                warnings,
                [
                    "open-items.md: names file `registry_tests.move` not found under "
                    "packages/predict/, packages/propbook/, or .claude/"
                ],
            )

    def test_propbook_pinning_tests_are_discovered_inside_the_fixture_root(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            predict = root / "packages" / "predict"
            propbook = root / "packages" / "propbook"
            predeploy = predict / "predeploy"
            propbook_tests = propbook / "tests"
            predeploy.mkdir(parents=True)
            propbook_tests.mkdir(parents=True)
            (predeploy / "response-policies.md").write_text(
                "## RP-1: Fixture\n\n"
                "- **Pinning tests:** `creating_a_second_store_pair_for_an_underlying_aborts`.\n"
            )
            patches = (
                mock.patch.object(check, "HERE", str(predeploy)),
                mock.patch.object(check, "PREDICT", str(predict)),
                mock.patch.object(check, "PROPBOOK", str(propbook)),
                mock.patch.object(check, "ROOT", str(root)),
            )

            errors: list[str] = []
            with patches[0], patches[1], patches[2], patches[3]:
                check.check_pinning_tests(errors)
            self.assertEqual(
                errors,
                [
                    "response-policies.md entry 'RP-1: Fixture' pins test "
                    "`creating_a_second_store_pair_for_an_underlying_aborts` but no "
                    "`fun creating_a_second_store_pair_for_an_underlying_aborts` exists under "
                    "packages/predict/tests/ or packages/propbook/tests/"
                ],
            )

            (propbook_tests / "registry_tests.move").write_text(
                "fun creating_a_second_store_pair_for_an_underlying_aborts() {}\n"
            )
            errors = []
            with (
                mock.patch.object(check, "HERE", str(predeploy)),
                mock.patch.object(check, "PREDICT", str(predict)),
                mock.patch.object(check, "PROPBOOK", str(propbook)),
                mock.patch.object(check, "ROOT", str(root)),
            ):
                check.check_pinning_tests(errors)
            self.assertEqual(errors, [])


if __name__ == "__main__":
    unittest.main()
