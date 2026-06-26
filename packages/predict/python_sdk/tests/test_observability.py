import unittest

from predict_sdk import load_testnet_config
from predict_sdk.observability import ObservabilityClient

# Offline: a fake transport serves canned indexer JSON (predict-server + oracle
# service), dispatched by URL suffix. now is aligned so the fixture market lands in
# the 1m live slot. Expected values are hand-derived, not read back from the impl.

NOW_MS = 1_800_000_000_000
MARKET_ID = "0x1111111111111111111111111111111111111111111111111111111111111111"
ORACLE_ID = "0xoracle"


def _responses(config, *, paused=False, oracle_age_ms=10_000, settled=False, binding=True):
    vault_id = config.shared_object_id("predict", "plp::PoolVault")
    underlying = config.asset("BTC_USD").propbook_underlying_id
    expiry = NOW_MS + 60_000  # the 1m live slot for NOW_MS
    ts = str(NOW_MS - oracle_age_ms)
    settlement = {"settlement_price": "65000000000000"} if settled else None
    responses = {
        "/config": {
            "trading_paused": {"paused": paused},
            "pricing": {"pyth_spot_freshness_ms": 30000, "block_scholes_surface_freshness_ms": 30000},
        },
        "/markets": [{
            "expiry_market_id": MARKET_ID, "expiry": expiry,
            "propbook_underlying_id": underlying, "tick_size": "1000000000",
        }],
        f"/markets/{MARKET_ID}/state": {
            "market": {"expiry": expiry, "tick_size": "1000000000", "propbook_underlying_id": underlying},
            "mint_paused": {"paused": False},
            "settlement": settlement,
        },
        f"/vaults/{vault_id}/state": {"current": {
            "idle_balance_after": "1000000000",
            "protocol_reserve_balance_after": "0",
            "total_supply": "1000000000",
        }},
        f"/oracles/{ORACLE_ID}/pyth/latest": {"source_timestamp_ms": ts},
        f"/oracles/{ORACLE_ID}/block-scholes": [{"source_timestamp_ms": ts}],
    }
    if binding:
        responses[f"/underlyings/{underlying}/binding"] = {"propbook_oracle_id": ORACLE_ID}
    return responses


def _transport(responses):
    def transport(url, timeout):
        base = url.split("?", 1)[0]
        for path, value in responses.items():
            if base.endswith(path):
                return value
        return {}
    return transport


def _client(config, **kwargs):
    return ObservabilityClient(config, transport=_transport(_responses(config, **kwargs)))


class ObservabilityTests(unittest.TestCase):
    def test_status_reports_mintable_live_market(self) -> None:
        config = load_testnet_config()
        report = _client(config).status("BTC_USD", now_ms=NOW_MS)

        self.assertTrue(report.is_live)
        self.assertTrue(report.is_mintable)
        self.assertEqual(report.blockers, [])
        self.assertEqual(report.mintable_market_ids, [MARKET_ID])
        self.assertEqual(report.pool.active_market_count, 1)
        self.assertEqual(report.markets[0].time_to_expiry_ms, 60_000)
        self.assertEqual(report.markets[0].blockers, [])
        self.assertTrue(report.oracle.fresh)
        self.assertEqual(report.pool.idle_balance, 1_000_000_000)
        self.assertEqual(report.pool.plp_total_supply, 1_000_000_000)

    def test_status_reports_blockers_when_paused_and_oracle_stale(self) -> None:
        config = load_testnet_config()
        report = _client(config, paused=True, oracle_age_ms=120_000).status("BTC_USD", now_ms=NOW_MS)

        self.assertFalse(report.is_live)
        self.assertFalse(report.is_mintable)
        self.assertIn("protocol trading is paused", report.blockers)
        # freshness 30s, age 120s -> stale by 90s; the oracle blocker flows into the market
        self.assertIn("pyth oracle stale by 90000ms", report.markets[0].blockers)

    def test_status_reports_config_unavailable_when_indexer_down(self) -> None:
        config = load_testnet_config()
        report = ObservabilityClient(config, transport=lambda url, t: {}).status("BTC_USD", now_ms=NOW_MS)

        self.assertFalse(report.is_live)
        self.assertIn("protocol config unavailable", report.blockers)
        self.assertEqual(report.markets, [])

    def test_settled_market_is_not_mintable(self) -> None:
        config = load_testnet_config()
        report = _client(config, settled=True).status("BTC_USD", now_ms=NOW_MS)

        self.assertFalse(report.markets[0].mintable)
        self.assertIn("market is settled", report.markets[0].blockers)
        self.assertEqual(report.markets[0].settlement_price, 65_000_000_000_000)

    def test_missing_oracle_binding_is_not_fresh(self) -> None:
        config = load_testnet_config()
        report = _client(config, binding=False).status("BTC_USD", now_ms=NOW_MS)

        self.assertFalse(report.oracle.fresh)
        self.assertIn("oracle binding unavailable", report.markets[0].blockers)


if __name__ == "__main__":
    unittest.main()
