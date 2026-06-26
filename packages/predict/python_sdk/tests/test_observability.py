import unittest

from predict_sdk import load_testnet_config
from predict_sdk.observability import ObservabilityClient


NOW_MS = 1_800_000_000_000
MARKET_ID = "0x1111111111111111111111111111111111111111111111111111111111111111"


class FakeObjectReader:
    def __init__(self, objects, dynamic_fields=None):
        self.objects = objects
        self.dynamic_fields = dynamic_fields or {}
        self.requested_ids = []
        self.dynamic_requests = []

    def get_object(self, object_id):
        self.requested_ids.append(object_id)
        return self.objects.get(object_id)

    def get_dynamic_field_object(self, parent_id, name_type, name_value):
        self.dynamic_requests.append((parent_id, name_type, name_value))
        return self.dynamic_fields.get((parent_id, name_type, name_value))


class ObservabilityTests(unittest.TestCase):
    def test_status_reports_mintable_live_market(self) -> None:
        config = load_testnet_config()
        reader = FakeObjectReader(_live_objects(config))

        report = ObservabilityClient(config, reader).status("BTC_USD", now_ms=NOW_MS)

        self.assertTrue(report.is_live)
        self.assertTrue(report.is_mintable)
        self.assertEqual(report.blockers, [])
        self.assertEqual(report.mintable_market_ids, [MARKET_ID])
        self.assertEqual(report.pool.active_market_count, 1)
        self.assertEqual(report.markets[0].time_to_expiry_ms, 60_000)
        self.assertEqual(report.markets[0].blockers, [])
        self.assertTrue(report.oracle.fresh)

    def test_status_reports_blockers_when_paused_and_oracle_stale(self) -> None:
        config = load_testnet_config()
        objects = _live_objects(config)
        protocol_id = config.shared_object_id("predict", "protocol_config::ProtocolConfig")
        pyth_feed_id = config.asset("BTC_USD").feed_ids.pyth
        objects[protocol_id]["data"]["content"]["fields"]["trading_paused"] = True
        objects[pyth_feed_id]["data"]["content"]["fields"]["latest_source_timestamp_ms"] = (
            NOW_MS - 120_000
        )
        reader = FakeObjectReader(objects)

        report = ObservabilityClient(config, reader).status("BTC_USD", now_ms=NOW_MS)

        self.assertFalse(report.is_live)
        self.assertFalse(report.is_mintable)
        self.assertIn("protocol trading is paused", report.blockers)
        self.assertIn("pyth oracle stale by 90000ms", report.markets[0].blockers)

    def test_status_reports_missing_objects_as_blockers(self) -> None:
        config = load_testnet_config()
        reader = FakeObjectReader({})

        report = ObservabilityClient(config, reader).status("BTC_USD", now_ms=NOW_MS)

        self.assertFalse(report.is_live)
        self.assertFalse(report.is_mintable)
        self.assertIn("protocol config object missing", report.blockers)
        self.assertIn("pool vault object missing", report.blockers)
        self.assertEqual(report.markets, [])

    def test_status_reads_expected_deployment_objects(self) -> None:
        config = load_testnet_config()
        reader = FakeObjectReader(_live_objects(config))

        ObservabilityClient(config, reader).status("BTC_USD", now_ms=NOW_MS)

        self.assertIn(
            config.shared_object_id("predict", "protocol_config::ProtocolConfig"),
            reader.requested_ids,
        )
        self.assertIn(config.shared_object_id("predict", "plp::PoolVault"), reader.requested_ids)
        self.assertIn(config.asset("BTC_USD").feed_ids.bs_forward, reader.requested_ids)

    def test_status_understands_nested_sui_object_fields(self) -> None:
        config = load_testnet_config()
        reader = FakeObjectReader(_nested_live_objects(config))

        report = ObservabilityClient(config, reader).status("BTC_USD", now_ms=NOW_MS)

        self.assertTrue(report.is_mintable)
        self.assertEqual(report.pool.idle_balance, 1_000_000_000)
        self.assertEqual(report.pool.active_market_ids, (MARKET_ID,))
        self.assertEqual(report.markets[0].cash_balance, 100_000_000)
        self.assertEqual(report.markets[0].tick_size, 1_000_000_000)

    def test_status_reads_per_expiry_oracle_table_entries(self) -> None:
        config = load_testnet_config()
        expiry_ms = str(NOW_MS + 60_000)
        forward_table_id = "0xforwardtable"
        svi_table_id = "0xsvitable"
        objects = _nested_live_objects(config)
        asset = config.asset("BTC_USD")
        objects[asset.feed_ids.bs_forward] = _object(
            {"expiries": {"fields": {"id": {"id": forward_table_id}, "size": "1"}}}
        )
        objects[asset.feed_ids.bs_svi] = _object(
            {"expiries": {"fields": {"id": {"id": svi_table_id}, "size": "1"}}}
        )
        reader = FakeObjectReader(
            objects,
            {
                (forward_table_id, "u64", expiry_ms): _dynamic_lane_object(expiry_ms, NOW_MS - 10_000),
                (svi_table_id, "u64", expiry_ms): _dynamic_lane_object(expiry_ms, NOW_MS - 10_000),
            },
        )

        report = ObservabilityClient(config, reader).status("BTC_USD", now_ms=NOW_MS)

        self.assertTrue(report.is_mintable)
        self.assertIn((forward_table_id, "u64", expiry_ms), reader.dynamic_requests)
        self.assertIn((svi_table_id, "u64", expiry_ms), reader.dynamic_requests)


def _live_objects(config):
    asset = config.asset("BTC_USD")
    return {
        config.shared_object_id("predict", "protocol_config::ProtocolConfig"): _object(
            {
                "trading_paused": False,
                "valuation_in_progress": False,
                "pricing_config": {
                    "fields": {
                        "pyth_spot_freshness_ms": "30000",
                        "block_scholes_price_freshness_ms": "30000",
                        "block_scholes_svi_freshness_ms": "60000",
                    }
                },
            }
        ),
        config.shared_object_id("predict", "plp::PoolVault"): _object(
            {
                "idle_balance": "1000000000",
                "protocol_reserve_balance": "0",
                "plp_total_supply": "1000000000",
                "supply_requests_pending": "0",
                "withdraw_requests_pending": "0",
                "active_expiry_markets": [MARKET_ID],
            }
        ),
        MARKET_ID: _object(
            {
                "propbook_underlying_id": "1",
                "expiry": str(NOW_MS + 60_000),
                "mint_paused": False,
                "settlement_price": None,
                "cash_balance": "100000000",
                "payout_liability": "0",
                "rebate_reserve": "0",
                "tick_size": "1000000000",
            }
        ),
        asset.feed_ids.pyth: _object({"latest_source_timestamp_ms": str(NOW_MS - 10_000)}),
        asset.feed_ids.bs_spot: _object({"latest_source_timestamp_ms": str(NOW_MS - 10_000)}),
        asset.feed_ids.bs_forward: _object({"latest_source_timestamp_ms": str(NOW_MS - 10_000)}),
        asset.feed_ids.bs_svi: _object({"latest_source_timestamp_ms": str(NOW_MS - 10_000)}),
    }


def _object(fields):
    return {"data": {"content": {"fields": fields}}}


def _nested_live_objects(config):
    objects = _live_objects(config)
    protocol_id = config.shared_object_id("predict", "protocol_config::ProtocolConfig")
    pool_id = config.shared_object_id("predict", "plp::PoolVault")

    objects[protocol_id] = _object(
        {
            "trading_paused": False,
            "valuation_in_progress": False,
            "pricing_config": {
                "fields": {
                    "pyth_spot_freshness_ms": "30000",
                    "block_scholes_price_freshness_ms": "30000",
                    "block_scholes_svi_freshness_ms": "60000",
                }
            },
        }
    )
    objects[pool_id] = _object(
        {
            "protocol_reserve_balance": _balance("0"),
            "lp": {
                "fields": {
                    "treasury_cap": {"fields": {"total_supply": {"fields": {"value": "1000000000"}}}},
                    "supply_queue": {"fields": {"pending": "0"}},
                    "withdraw_queue": {"fields": {"pending": "0"}},
                }
            },
            "expiry_accounting": {
                "fields": {
                    "idle_balance": _balance("1000000000"),
                    "active_expiry_markets": [MARKET_ID],
                }
            },
        }
    )
    objects[MARKET_ID] = _object(
        {
            "propbook_underlying_id": "1",
            "expiry": str(NOW_MS + 60_000),
            "settlement_price": {"fields": {"vec": []}},
            "cash": {"fields": {"cash_balance": _balance("100000000"), "unresolved_trading_fees_paid": "0"}},
            "strike_exposure": {"fields": {"tick_size": "1000000000"}},
            "mint_paused": False,
        }
    )
    asset = config.asset("BTC_USD")
    objects[asset.feed_ids.pyth] = _oracle_lane_object(NOW_MS - 10_000)
    objects[asset.feed_ids.bs_spot] = _oracle_lane_object(NOW_MS - 10_000)
    objects[asset.feed_ids.bs_forward] = _oracle_lane_object(NOW_MS - 10_000)
    objects[asset.feed_ids.bs_svi] = _oracle_lane_object(NOW_MS - 10_000)
    return objects


def _balance(value):
    return {"fields": {"value": value}}


def _oracle_lane_object(source_timestamp_ms):
    return _object(
        {
            "lane": {
                "fields": {
                    "latest": {
                        "fields": {
                            "source_timestamp_ms": str(source_timestamp_ms),
                            "update_timestamp_ms": str(source_timestamp_ms + 1),
                            "value": {"fields": {}},
                        }
                    }
                }
            }
        }
    )


def _dynamic_lane_object(expiry_ms, source_timestamp_ms):
    return _object(
        {
            "name": str(expiry_ms),
            "value": {
                "fields": {
                    "latest": {
                        "fields": {
                            "source_timestamp_ms": str(source_timestamp_ms),
                            "update_timestamp_ms": str(source_timestamp_ms + 1),
                            "value": {"fields": {}},
                        }
                    }
                }
            },
        }
    )


if __name__ == "__main__":
    unittest.main()
