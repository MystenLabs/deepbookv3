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


if __name__ == "__main__":
    unittest.main()
