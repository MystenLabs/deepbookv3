import json
import tempfile
import unittest
from pathlib import Path

from predict_sdk.actions import PredictActions
from predict_sdk.config import load_testnet_config
from predict_sdk.signer import Signer


class FakeClient:
    def __init__(self, coin_type: str):
        self.coin_type = coin_type
        self.calls = []

    def _rpc(self, method, params):
        self.calls.append((method, params))
        if method == "sui_getObject":
            return {
                "data": {
                    "content": {
                        "fields": {
                            "account": {
                                "fields": {
                                    "balances": {
                                        "fields": {"id": {"id": "0xbalances"}}
                                    }
                                }
                            }
                        }
                    }
                }
            }
        if method == "suix_getDynamicFields":
            return {
                "data": [
                    {
                        "name": {
                            "type": f"0xaccount::account::CoinKey<{self.coin_type}>",
                            "value": {"dummy_field": False},
                        },
                        "objectType": f"0x2::balance::Balance<{self.coin_type}>",
                    }
                ]
            }
        if method == "suix_getDynamicFieldObject":
            return {"data": {"content": {"fields": {"value": "9897999049"}}}}
        raise AssertionError(f"unexpected RPC method {method}")


class ActionsTests(unittest.TestCase):
    def test_custody_balance_reads_account_wrapper_balance_bag(self) -> None:
        signer = Signer(private_key=b"\x00" * 32, public_key=b"\x00" * 32, address="0xabc")
        config = load_testnet_config()
        with tempfile.TemporaryDirectory() as tmp:
            state_path = Path(tmp) / "state.json"
            state_path.write_text(json.dumps({signer.address: "0xaccount"}))
            actions = PredictActions(signer, config=config, state_path=str(state_path))
            actions.client = FakeClient(actions.m.dusdc_type)

            self.assertEqual(actions.custody_balance(), 9_897_999_049)


if __name__ == "__main__":
    unittest.main()
