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
                        "schema_version": "predict_local_trace_v5",
                        "steps": [
                            {
                                "step": 1,
                                "action": "mint",
                                "digest": "priced-digest",
                                "pricingTimestampMs": 125,
                                "wallMs": 1.5,
                                "gas": {
                                    "computationCost": 1,
                                    "storageCost": 2,
                                    "storageRebate": 0,
                                    "nonRefundableStorageFee": 0,
                                    "gasTotal": 3,
                                },
                                "events": [
                                    {
                                        "type": "SVIParams>>",
                                        "full_type": (
                                            "0x1::events::BlockScholesObservationRecorded"
                                            "<0x1::types::SVIParams>"
                                        ),
                                        "parsedJson": {
                                            "observation": {
                                                "source_timestamp_ms": "90",
                                                "onchain_timestamp_ms": "100",
                                            },
                                            "series_kind": 2,
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
                    (1, "mint"): {
                        "pricing_timestamp_ms": 125,
                        "svi_source_timestamp_ms": 90,
                    }
                },
            )

    def test_pricing_trace_rejects_missing_schema_and_coerced_fields(self) -> None:
        invalid_traces = (
            {"steps": []},
            {
                "schema_version": "predict_local_trace_v5",
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
                "schema_version": "predict_local_trace_v5",
                "steps": [
                    {
                        "step": 1,
                        "action": "mint",
                        "pricingTimestampMs": 125,
                        "events": [
                            {
                                "full_type": (
                                    "0x1::events::BlockScholesObservationRecorded"
                                    "<0x1::types::SVIParams>"
                                ),
                                "parsedJson": {
                                    "observation": {"source_timestamp_ms": False}
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
