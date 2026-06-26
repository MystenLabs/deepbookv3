import contextlib
import io
import json
import unittest

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
