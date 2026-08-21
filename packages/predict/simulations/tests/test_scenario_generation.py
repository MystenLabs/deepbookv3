from __future__ import annotations

import json
import csv
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SIM_DIR = Path(__file__).resolve().parents[1]
GENERATOR = SIM_DIR / "generate_scenario.py"
CONFIG = SIM_DIR / "data" / "scenario_config.json"
SOURCE_HEADER = (
    "spot,forward,a,b,rho,rho_negative,m,m_negative,sigma,"
    "svi_checkpoint_timestamp_ms,price_checkpoint_timestamp_ms\n"
)
SOURCE_ROWS = (
    "75852009440344,75799394374445,171736,7449196,243059022,true,1133202,false,15731214,1779868817525,1779868817525\n"
    "75850295501350,75799394983317,171736,7449196,243059022,true,1133202,false,15731214,1779868818472,1779868818472\n"
    "75848584749562,75797682842049,171736,7449196,243059022,true,1133202,false,15731214,1779868819584,1779868819584\n"
)


class ScenarioGenerationTests(unittest.TestCase):
    def _generate(
        self,
        source: Path,
        out: Path,
        seed: int,
        config: Path = CONFIG,
        check: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(GENERATOR),
                "--source",
                str(source),
                "--config",
                str(config),
                "--out",
                str(out),
                "--seed",
                str(seed),
            ],
            check=check,
            capture_output=True,
            text=True,
        )

    def test_same_seed_source_and_config_are_byte_identical(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            tmp = Path(raw_tmp)
            source = tmp / "source.csv"
            source.write_text(SOURCE_HEADER + "".join(SOURCE_ROWS))
            first = tmp / "first.csv"
            second = tmp / "second.csv"
            other = tmp / "other.csv"

            self._generate(source, first, 42)
            self._generate(source, second, 42)
            self._generate(source, other, 43)

            self.assertEqual(first.read_bytes(), second.read_bytes())
            self.assertNotEqual(first.read_bytes(), other.read_bytes())

    def test_config_rejects_missing_and_unknown_fields(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            tmp = Path(raw_tmp)
            source = tmp / "source.csv"
            source.write_text(SOURCE_HEADER + "".join(SOURCE_ROWS))
            base = json.loads(CONFIG.read_text())

            missing = json.loads(json.dumps(base))
            del missing["protocol"]["base_fee"]
            missing_path = tmp / "missing.json"
            missing_path.write_text(json.dumps(missing))
            missing_run = self._generate(
                source,
                tmp / "missing.csv",
                0,
                missing_path,
                False,
            )

            unknown = json.loads(json.dumps(base))
            unknown["protocol"]["base_fees"] = unknown["protocol"]["base_fee"]
            unknown_path = tmp / "unknown.json"
            unknown_path.write_text(json.dumps(unknown))
            unknown_run = self._generate(
                source,
                tmp / "unknown.csv",
                0,
                unknown_path,
                False,
            )

            self.assertNotEqual(missing_run.returncode, 0)
            self.assertIn("missing=base_fee", missing_run.stderr)
            self.assertNotEqual(unknown_run.returncode, 0)
            self.assertIn("unknown=base_fees", unknown_run.stderr)

    def test_generated_scenario_covers_every_current_contract_action(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            tmp = Path(raw_tmp)
            source = tmp / "source.csv"
            source.write_text(SOURCE_HEADER + "".join(SOURCE_ROWS))
            output = tmp / "scenario.csv"
            self._generate(source, output, 0)

            with output.open(newline="") as file:
                rows = list(csv.DictReader(file))
            self.assertEqual(len(rows), 20)
            self.assertEqual(
                {row["action"] for row in rows},
                {
                    "mint",
                    "redeem_live",
                    "request_supply",
                    "request_withdraw",
                    "flush",
                    "rebalance_expiry_cash",
                    "settle",
                    "redeem_settled",
                },
            )
            self.assertEqual(
                [row["permissionless"] for row in rows if row["action"] == "redeem_settled"],
                ["false", "true", "false", "true"],
            )
            self.assertLessEqual(
                max(int(row["quantity"]) for row in rows if row["action"] == "mint"),
                6_250_000_000,
            )


if __name__ == "__main__":
    unittest.main()
