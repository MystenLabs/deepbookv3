import unittest
from unittest.mock import patch

from predict_sdk.actions import PredictActions
from predict_sdk.config import load_testnet_config
from predict_sdk.signer import Signer

SIGNER = Signer(private_key=b"\x00" * 32, public_key=b"\x00" * 32, address="0xabc")


def _actions():
    return PredictActions(SIGNER, config=load_testnet_config())


class FakeIndexer:
    """Stands in for PredictIndexerClient.managers(owner=...) — newest first."""

    def __init__(self, rows):
        self._rows = rows

    def __call__(self, *args, **kwargs):  # constructed as PredictIndexerClient(server)
        return self

    def managers(self, *, owner=None, limit=50):
        return list(self._rows)


class FakeTxClient:
    def __init__(self, coin_type: str):
        self.coin_type = coin_type

    def _rpc(self, method, params):
        if method == "sui_getObject":
            return {"data": {"content": {"fields": {"account": {"fields": {
                "balances": {"fields": {"id": {"id": "0xbalances"}}}
            }}}}}}
        if method == "suix_getDynamicFields":
            return {"data": [{
                "name": {"type": f"0xaccount::account::CoinKey<{self.coin_type}>",
                         "value": {"dummy_field": False}},
                "objectType": f"0x2::balance::Balance<{self.coin_type}>",
            }]}
        if method == "suix_getDynamicFieldObject":
            return {"data": {"content": {"fields": {"value": "9897999049"}}}}
        raise AssertionError(f"unexpected RPC method {method}")


class AccountResolutionTests(unittest.TestCase):
    def test_resolves_wrapper_from_indexer_newest_first(self) -> None:
        actions = _actions()
        rows = [{"predict_manager_id": "0xnewest"}, {"predict_manager_id": "0xolder"}]
        with patch("predict_sdk.actions.PredictIndexerClient", FakeIndexer(rows)):
            self.assertEqual(actions.account_wrapper_id(), "0xnewest")

    def test_no_managers_yields_none(self) -> None:
        actions = _actions()
        with patch("predict_sdk.actions.PredictIndexerClient", FakeIndexer([])):
            self.assertIsNone(actions.account_wrapper_id())

    def test_cached_wrapper_skips_the_indexer(self) -> None:
        actions = _actions()
        actions._wrapper = "0xcached"
        # FakeIndexer would return something else; the cache must win (no lookup).
        with patch("predict_sdk.actions.PredictIndexerClient", FakeIndexer([{"predict_manager_id": "0xother"}])):
            self.assertEqual(actions.account_wrapper_id(), "0xcached")


class CustodyBalanceTests(unittest.TestCase):
    def test_custody_balance_reads_account_wrapper_balance_bag(self) -> None:
        actions = _actions()
        actions._wrapper = "0xaccount"  # seed the resolved wrapper (skip the indexer)
        actions.client = FakeTxClient(actions.m.dusdc_type)
        self.assertEqual(actions.custody_balance(), 9_897_999_049)


class _RefTickClient:
    def __init__(self, reference_tick):
        self._ref = reference_tick

    def _rpc(self, method, params):
        assert method == "sui_getObject"
        return {"data": {"content": {"fields": {
            "strike_exposure": {"fields": {"reference_tick": {"fields": {"vec": self._ref}}}}
        }}}}


class MarketReferenceTickTests(unittest.TestCase):
    def test_parses_option_wrapped_reference_tick(self) -> None:
        actions = _actions()
        actions.client = _RefTickClient(["64250"])  # Move Option<u64> with a value
        self.assertEqual(actions.market_reference_tick("0xmkt"), 64_250)

    def test_empty_option_reference_tick_is_none(self) -> None:
        actions = _actions()
        actions.client = _RefTickClient([])  # empty Option == none
        self.assertIsNone(actions.market_reference_tick("0xmkt"))


if __name__ == "__main__":
    unittest.main()
