import unittest

from predict_sdk import ACCUMULATOR_ROOT_ID, CLOCK_ID, POS_INF_TICK, load_testnet_config
from predict_sdk.config import DeploymentConfig


class ConfigTests(unittest.TestCase):
    def test_loads_self_contained_testnet_deployment(self) -> None:
        config = load_testnet_config()

        self.assertEqual(config.network, "testnet")
        self.assertEqual(config.chain_id, "4c78adac")
        self.assertEqual(
            config.package_id("predict"),
            "0xdb3ef5a5129920e59c9b2ae25a77eddb48acd0e1c6307b97073f0e076016446e",
        )
        self.assertEqual(
            config.shared_object_id("predict", "registry::Registry"),
            "0x54afbf245caf42466cedb5756ed7816f34f544afdfa13579a862eccf3afa21ca",
        )

    def test_exposes_wired_asset_and_cadences(self) -> None:
        config = load_testnet_config()

        asset = config.asset("BTC_USD")
        self.assertEqual(asset.propbook_underlying_id, 1)
        self.assertEqual(
            asset.pyth_feed_id,
            "0xc78d7de16217d46d21b92ae475da799448be30b71a758dc6d7bb3ac2f1c35afb",
        )
        self.assertEqual(asset.feed_ids.bs_svi, "0xdc2f8270676bd05fb28491e8d4a41a495722fda7a454926dd66dbba256a21c69")

        one_minute = config.cadence("1m")
        self.assertEqual(one_minute.id, 0)
        self.assertEqual(one_minute.period_ms, 60_000)

        five_minute = config.cadence("5m")
        self.assertEqual(five_minute.id, 1)
        self.assertEqual(five_minute.tick_size, 1_000_000_000)
        self.assertEqual(five_minute.admission_tick_size, 10_000_000_000)
        self.assertEqual(five_minute.period_ms, 300_000)

    def test_constants_match_predict_runtime_singletons(self) -> None:
        self.assertEqual(CLOCK_ID, "0x6")
        self.assertEqual(
            ACCUMULATOR_ROOT_ID,
            "0x0000000000000000000000000000000000000000000000000000000000000acc",
        )
        self.assertEqual(POS_INF_TICK, (1 << 30) - 1)

    def test_exposes_server_urls(self) -> None:
        config = load_testnet_config()
        self.assertEqual(
            config.server_url("predict"),
            "https://predict-server-beta.testnet.mystenlabs.com",
        )
        self.assertIsNone(config.server_url("missing"))

    def test_can_build_config_from_copied_dictionary(self) -> None:
        config = load_testnet_config()
        copied = DeploymentConfig.from_dict(config.to_dict())

        self.assertEqual(copied.asset("BTC_USD").feed_ids.bs_forward, config.asset("BTC_USD").feed_ids.bs_forward)
        self.assertEqual(copied.cadence(2).name, "1h")
        self.assertEqual(copied.server_url("propbook"), config.server_url("propbook"))


if __name__ == "__main__":
    unittest.main()
