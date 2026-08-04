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


if __name__ == "__main__":
    unittest.main()
