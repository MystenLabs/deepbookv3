from __future__ import annotations

import copy
import sys
import unittest
from pathlib import Path


SIMULATIONS_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SIMULATIONS_DIR))

import compare_parity as compare


def current_payload() -> dict[str, object]:
    return {
        "schema_version": compare.ECONOMIC_SCHEMA_VERSION,
        "scenario": {
            "required_actions": list(compare.REQUIRED_ACTIONS),
            "observed_actions": list(compare.REQUIRED_ACTIONS),
        },
        "records": [],
    }


class ParityArtifactValidationTests(unittest.TestCase):
    def test_accepts_exact_current_schema_and_action_coverage(self) -> None:
        compare.validate_action_coverage(current_payload(), "local")

    def test_rejects_stale_economic_schema(self) -> None:
        payload = current_payload()
        payload["schema_version"] = "predict_economic_v3"

        with self.assertRaisesRegex(SystemExit, "unsupported economic schema"):
            compare.validate_action_coverage(payload, "local")

    def test_rejects_self_declared_weakened_action_coverage(self) -> None:
        payload = copy.deepcopy(current_payload())
        payload["scenario"]["required_actions"] = ["mint"]
        payload["scenario"]["observed_actions"] = ["mint"]

        with self.assertRaisesRegex(SystemExit, "do not match the current schema"):
            compare.validate_action_coverage(payload, "python")


if __name__ == "__main__":
    unittest.main()
