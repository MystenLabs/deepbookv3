from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

SIMULATIONS_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SIMULATIONS_DIR))

from python_replay import load_pricing_timings


class PricingTimingTests(unittest.TestCase):
    def test_pricing_uses_priced_transaction_not_refresh_timestamp(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            trace = Path(directory) / "local_trace.json"
            trace.write_text(
                json.dumps(
                    {
                        "schema_version": "predict_local_trace_v4",
                        "steps": [
                            {
                                "step": 1,
                                "action": "oracle_mint_ptb",
                                "pricingTimestampMs": 125,
                                "events": [
                                    {
                                        "full_type": (
                                            "0x1::events::BlockScholesObservationRecorded"
                                            "<0x1::types::SVIParams>"
                                        ),
                                        "parsedJson": {
                                            "observation": {
                                                "model_timestamp_ms": "90",
                                                "recorded_at_ms": "100",
                                            }
                                        },
                                    }
                                ],
                            }
                        ]
                    }
                )
            )

            self.assertEqual(
                load_pricing_timings(trace),
                {
                    (1, "oracle_mint_ptb"): {
                        "model_timestamp_ms": 90,
                        "pricing_timestamp_ms": 125,
                    }
                },
            )

    def test_pricing_trace_rejects_missing_schema_and_coerced_fields(self) -> None:
        invalid_traces = (
            {"steps": []},
            {
                "schema_version": "predict_local_trace_v4",
                "steps": [
                    {
                        "step": "1",
                        "action": 7,
                        "pricingTimestampMs": True,
                        "events": [],
                    }
                ],
            },
            {
                "schema_version": "predict_local_trace_v4",
                "steps": [
                    {
                        "step": 1,
                        "action": "oracle_mint_ptb",
                        "pricingTimestampMs": 125,
                        "events": [
                            {
                                "full_type": (
                                    "0x1::events::BlockScholesObservationRecorded"
                                    "<0x1::types::SVIParams>"
                                ),
                                "parsedJson": {
                                    "observation": {"model_timestamp_ms": False}
                                },
                            }
                        ],
                    }
                ],
            },
        )
        for trace in invalid_traces:
            with self.subTest(trace=trace), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "local_trace.json"
                path.write_text(json.dumps(trace))
                with self.assertRaises(ValueError):
                    load_pricing_timings(path)


if __name__ == "__main__":
    unittest.main()
