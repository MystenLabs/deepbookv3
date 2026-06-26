import unittest

from predict_sdk.indexer import IndexerHealth, PredictIndexerClient
from predict_sdk.render import _indexer_line, _Paint, render_markets_table

STATUS_PAYLOAD = {
    "status": "OK",
    "latest_onchain_checkpoint": 100,
    "max_lag_pipeline": "settled_order_redeemed",
    "pipelines": [
        {"pipeline": "order_minted", "checkpoint_lag": 2, "time_lag_seconds": 1},
        {"pipeline": "settled_order_redeemed", "checkpoint_lag": 5, "time_lag_seconds": 3},
    ],
}

MARKET_ROW = {
    "expiry_market_id": "0x8b067174086362c618ff1c8a109d019f5fe135e9b33ec1b3d1f085d9b663324f",
    "expiry": 1782441540000,            # divisible by 1m only
    "initial_expiry_cash": "10000000000",  # 10,000.00 at 6 decimals
    "max_admission_leverage": 3000000000,  # 3x in 1e9 scaling
    "checkpoint_timestamp_ms": 1782441366989,
    "kind": "market_created",
}


class IndexerClientTests(unittest.TestCase):
    def test_health_parses_max_lag(self) -> None:
        client = PredictIndexerClient("https://x", transport=lambda url, t: STATUS_PAYLOAD)
        health = client.health()

        self.assertTrue(health.reachable)
        self.assertTrue(health.ok)
        self.assertEqual(health.max_checkpoint_lag, 5)
        self.assertEqual(health.max_time_lag_seconds, 3)
        self.assertEqual(health.max_lag_pipeline, "settled_order_redeemed")

    def test_health_unreachable_is_graceful(self) -> None:
        def boom(url, timeout):
            raise OSError("connection refused")

        health = PredictIndexerClient("https://x", transport=boom).health()
        self.assertFalse(health.reachable)
        self.assertFalse(health.ok)

    def test_health_malformed_payload_is_graceful(self) -> None:
        # A reachable indexer that returns a non-object body (e.g. a proxied error
        # page parsed as a JSON array) must degrade like an outage, not crash the
        # caller — health() has no .get() to call on a list.
        health = PredictIndexerClient("https://x", transport=lambda url, t: []).health()
        self.assertFalse(health.reachable)
        self.assertFalse(health.ok)
        self.assertIsNone(health.max_checkpoint_lag)

    def test_markets_returns_rows(self) -> None:
        calls = []

        def transport(url, timeout):
            calls.append(url)
            return [MARKET_ROW]

        rows = PredictIndexerClient("https://x", transport=transport).markets(limit=5)
        self.assertEqual(rows, [MARKET_ROW])
        self.assertIn("/markets?limit=5", calls[0])

    def test_markets_unreachable_returns_empty(self) -> None:
        def boom(url, timeout):
            raise OSError("down")

        self.assertEqual(PredictIndexerClient("https://x", transport=boom).markets(), [])


class IndexerRenderTests(unittest.TestCase):
    def test_indexer_line_states(self) -> None:
        paint = _Paint(False)
        ok = _indexer_line(IndexerHealth(True, True, 5, 2, "p", 100), paint)
        warn = _indexer_line(IndexerHealth(True, True, 200, 45, "settled_order_redeemed", 100), paint)
        down = _indexer_line(IndexerHealth(False, False, None, None, None, None), paint)

        self.assertIn("indexer ok · lag 2s", ok)
        self.assertIn("indexer lag 45s (settled_order_redeemed)", warn)
        self.assertIn("indexer unreachable", down)

    def test_markets_table_renders_row(self) -> None:
        out = render_markets_table([MARKET_ROW], 1782441400000, color=False)

        self.assertIn("PREDICT markets", out)
        self.assertIn("0x8b0671…3324f", out)  # short id
        self.assertIn("1m", out)               # cadence derived from expiry
        self.assertIn("10,000.00", out)        # initial cash
        self.assertIn("3x", out)               # leverage


if __name__ == "__main__":
    unittest.main()
