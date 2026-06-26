import contextlib
import io
import json
import unittest
from dataclasses import dataclass

import predict_sdk.cli as cli
from predict_sdk.cli import main
from predict_sdk.rpc import SuiRpcObjectReader


class CliTests(unittest.TestCase):
    def test_status_fixture_prints_report(self) -> None:
        stdout = io.StringIO()

        with contextlib.redirect_stdout(stdout):
            exit_code = main(["status", "--fixture-live"])

        self.assertEqual(exit_code, 0)
        output = stdout.getvalue()
        self.assertIn("PREDICT", output)
        self.assertIn("● LIVE", output)
        self.assertIn("BTC_USD", output)
        # stdout is redirected (not a TTY), so the CLI must emit plain text.
        self.assertNotIn("\x1b[", output)

    def test_status_fixture_can_print_json(self) -> None:
        stdout = io.StringIO()

        with contextlib.redirect_stdout(stdout):
            exit_code = main(["status", "--fixture-live", "--json"])

        self.assertEqual(exit_code, 0)
        payload = json.loads(stdout.getvalue())
        self.assertEqual(payload["asset"], "BTC_USD")
        self.assertTrue(payload["is_mintable"])
        self.assertEqual(payload["blockers"], [])

    def test_account_prints_wallet_custody_and_total_dusdc(self) -> None:
        case = self

        @dataclass
        class FakePortfolio:
            open_count: int = 0
            closed_count: int = 1
            open_premium: int = 0
            realized_pnl: int = -99_000_951

        class FakeClient:
            def _rpc(self, method, params):
                case.assertEqual(method, "suix_getAllBalances")
                return [
                    {"coinType": "0x2::sui::SUI", "totalBalance": "999947945080"},
                    {"coinType": "0xdusdc::dusdc::DUSDC", "totalBalance": "90003000000"},
                ]

        class FakeActions:
            signer = type("Signer", (), {"address": "0xabc"})()
            client = FakeClient()

            def account_wrapper_id(self):
                return "0xaccount"

            def portfolio(self):
                return FakePortfolio()

            def custody_balance(self):
                return 9_897_999_049

        original = cli._build_actions
        cli._build_actions = lambda args: FakeActions()
        stdout = io.StringIO()
        try:
            with contextlib.redirect_stdout(stdout):
                exit_code = main(["account"])
        finally:
            cli._build_actions = original

        self.assertEqual(exit_code, 0)
        output = stdout.getvalue()
        self.assertIn("wallet       999.9479 SUI | 90,003.00 DUSDC", output)
        self.assertIn("custody      9,898.00 DUSDC", output)
        self.assertIn("total        99,901.00 DUSDC", output)
        self.assertIn("realized PnL -99.0010 DUSDC", output)

    def test_rpc_reader_fetches_move_object_content(self) -> None:
        calls = []

        def transport(url, payload, timeout):
            calls.append((url, payload, timeout))
            return {
                "jsonrpc": "2.0",
                "id": 1,
                "result": {
                    "data": {
                        "objectId": payload["params"][0],
                        "content": {"fields": {"value": "7"}},
                    }
                },
            }

        reader = SuiRpcObjectReader("https://example.test", transport=transport, timeout=3)
        result = reader.get_object("0xabc")

        self.assertEqual(result["data"]["content"]["fields"]["value"], "7")
        self.assertEqual(calls[0][0], "https://example.test")
        self.assertEqual(calls[0][1]["method"], "sui_getObject")
        self.assertEqual(calls[0][1]["params"][0], "0xabc")
        self.assertTrue(calls[0][1]["params"][1]["showContent"])
        self.assertEqual(calls[0][2], 3)

    def test_rpc_reader_fetches_dynamic_field_object(self) -> None:
        calls = []

        def transport(url, payload, timeout):
            calls.append((url, payload, timeout))
            return {
                "jsonrpc": "2.0",
                "id": 1,
                "result": {
                    "data": {
                        "objectId": "0xdynamic",
                        "content": {"fields": {"name": "1782421200000"}},
                    }
                },
            }

        reader = SuiRpcObjectReader("https://example.test", transport=transport)
        result = reader.get_dynamic_field_object("0xtable", "u64", "1782421200000")

        self.assertEqual(result["data"]["content"]["fields"]["name"], "1782421200000")
        self.assertEqual(calls[0][1]["method"], "suix_getDynamicFieldObject")
        self.assertEqual(calls[0][1]["params"][0], "0xtable")
        self.assertEqual(calls[0][1]["params"][1], {"type": "u64", "value": "1782421200000"})


if __name__ == "__main__":
    unittest.main()
