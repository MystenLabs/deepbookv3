import contextlib
import io
import json
import unittest
from dataclasses import dataclass

import predict_sdk.cli as cli
from predict_sdk.cli import main


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


if __name__ == "__main__":
    unittest.main()
