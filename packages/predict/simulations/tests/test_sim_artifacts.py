from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SIMULATIONS_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SIMULATIONS_DIR))

from sim_artifacts import load_local_trace
from write_benchmark_results import build_results, main as write_benchmark_results


class LocalTraceTests(unittest.TestCase):
    def test_consumers_reject_incomplete_or_coerced_v6_steps(self) -> None:
        invalid_steps = (
            {
                "step": 1,
                "action": "mint",
                "pricingTimestampMs": 125,
                "events": [],
            },
            {
                "step": 1,
                "action": 7,
                "digest": "digest",
                "pricingTimestampMs": 125,
                "wallMs": 1.5,
                "gas": {
                    "computationCost": 1,
                    "storageCost": 2,
                    "storageRebate": 0,
                    "nonRefundableStorageFee": 0,
                    "gasTotal": 3,
                },
                "events": [],
            },
        )
        for step in invalid_steps:
            with self.subTest(step=step), tempfile.TemporaryDirectory() as directory:
                trace_path = Path(directory) / "trace.json"
                results_path = Path(directory) / "results.json"
                trace_path.write_text(
                    json.dumps(
                        {
                            "schema_version": "predict_local_trace_v6",
                            "steps": [step],
                        }
                    )
                )
                with self.assertRaises(ValueError):
                    load_local_trace(trace_path)
                with (
                    mock.patch.object(
                        sys,
                        "argv",
                        ["write_benchmark_results.py", str(trace_path), str(results_path)],
                    ),
                    self.assertRaises(ValueError),
                ):
                    write_benchmark_results()
                self.assertFalse(results_path.exists())

        with tempfile.TemporaryDirectory() as directory:
            trace_path = Path(directory) / "trace.json"
            trace_path.write_text(
                json.dumps(
                    {
                        "schema_version": "predict_local_trace_v6",
                        "steps": [],
                        "unexpected": True,
                    }
                )
            )
            with self.assertRaisesRegex(ValueError, "unknown=unexpected"):
                load_local_trace(trace_path)


class BenchmarkResultsTests(unittest.TestCase):
    def test_only_filled_mints_count_as_successful(self) -> None:
        def step(number: int, action: str, events: list[str]) -> dict[str, object]:
            return {
                "step": number,
                "action": action,
                "digest": "digest",
                "pricingTimestampMs": 1,
                "wallMs": 2.0,
                "gas": {
                    "computationCost": 1,
                    "storageCost": 2,
                    "storageRebate": 0,
                    "nonRefundableStorageFee": 0,
                    "gasTotal": 3,
                },
                "events": [
                    {"type": name, "full_type": f"0x1::order_events::{name}", "parsedJson": {}}
                    for name in events
                ],
            }

        results = build_results(
            {
                "schema_version": "predict_local_trace_v6",
                "steps": [
                    step(1, "mint", ["OrderEnqueued", "OrderMinted", "QueuedOrderFilled"]),
                    step(2, "mint", ["OrderEnqueued", "QueuedOrderRefunded"]),
                    step(3, "mint", ["OrderEnqueued"]),
                    step(4, "redeem_open", ["OrderEnqueued", "QueuedOrderFilled"]),
                ],
            }
        )

        summary = results["summary"]
        self.assertEqual(
            (summary["attemptedMints"], summary["successfulMints"], summary["rejectedMints"]),
            (3, 1, 2),
        )
        self.assertEqual((len(results["mints"]), len(results["rejectedMints"])), (1, 2))
        self.assertEqual(summary["byAction"]["mint"]["count"], 3)


if __name__ == "__main__":
    unittest.main()
