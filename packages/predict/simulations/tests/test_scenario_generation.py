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
sys.path.insert(0, str(SIM_DIR))

import generate_scenario as scenario_generator
SOURCE_HEADER = (
    "spot,forward,a,b,rho,rho_negative,m,m_negative,sigma,"
    "svi_checkpoint_timestamp_ms,price_checkpoint_timestamp_ms\n"
)
SOURCE_ROWS = (
    "75852009440344,75799394374445,171736,7449196,243059022,true,1133202,false,15731214,1779868817525,1779868817525\n"
    "75850295501350,75799394983317,171736,7449196,243059022,true,1133202,false,15731214,1779868818472,1779868818472\n"
    "75848584749562,75797682842049,171736,7449196,243059022,true,1133202,false,15731214,1779868819584,1779868819584\n"
)
HIGH_FORWARD_SOURCE_ROWS = (
    "110000000000000,110000000000000,171736,7449196,243059022,true,1133202,false,15731214,1779868817525,1779868817525\n"
    "110000000000000,110000000000000,171736,7449196,243059022,true,1133202,false,15731214,1779868818472,1779868818472\n"
    "110000000000000,110000000000000,171736,7449196,243059022,true,1133202,false,15731214,1779868819584,1779868819584\n"
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
            partial = next(row for row in rows if row["tx"] == "3")
            self.assertEqual(partial["replacement_order_ref"], "")
            self.assertEqual(
                next(row for row in rows if row["tx"] == "14")["order_ref"],
                partial["order_ref"],
            )
            self.assertLessEqual(
                max(int(row["quantity"]) for row in rows if row["action"] == "mint"),
                6_250_000_000,
            )

    def test_settlement_positions_remain_admissible_when_forward_moves(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            tmp = Path(raw_tmp)
            source = tmp / "source.csv"
            source.write_text(SOURCE_HEADER + "".join(HIGH_FORWARD_SOURCE_ROWS))
            output = tmp / "scenario.csv"
            self._generate(source, output, 0)

            with output.open(newline="") as file:
                rows = list(csv.DictReader(file))
            settlement_price = int(
                next(row["settlement_price"] for row in rows if row["action"] == "settle")
            )
            positions = {
                row["order_ref"]: row
                for row in rows
                if row["action"] == "mint"
                and row["order_ref"] in {"o_settle_winner", "o_settle_loser"}
            }

            def wins(row: dict[str, str]) -> bool:
                settlement_above_strike = settlement_price > int(row["strike"])
                return (row["is_up"] == "true") == settlement_above_strike

            self.assertTrue(wins(positions["o_settle_winner"]))
            self.assertFalse(wins(positions["o_settle_loser"]))

    def test_settlement_at_strike_makes_down_the_winner(self) -> None:
        settlement_price = 75_000_000_000_000
        snapshot = {
            "spot": settlement_price,
            "forward": settlement_price,
            "a": 171736,
            "a_negative": False,
            "b": 7449196,
            "rho": 243059022,
            "rho_negative": True,
            "m": 1133202,
            "m_negative": False,
            "sigma": 15731214,
            "svi_checkpoint_timestamp_ms": 1,
            "price_checkpoint_timestamp_ms": 1,
        }

        class AtTheMoneyRng:
            def randint(self, lower: int, _upper: int) -> int:
                return 0 if lower < 0 else lower

        generator = scenario_generator.Generator(
            [snapshot],
            json.loads(CONFIG.read_text()),
            0,
        )
        generator.rng = AtTheMoneyRng()
        winner = generator.settlement_mint_row(
            11,
            "winner",
            winner=True,
            settlement_price=settlement_price,
        )
        loser = generator.settlement_mint_row(
            12,
            "loser",
            winner=False,
            settlement_price=settlement_price,
        )

        self.assertEqual(winner["strike"], str(settlement_price))
        self.assertEqual(winner["is_up"], "false")
        self.assertEqual(loser["strike"], str(settlement_price))
        self.assertEqual(loser["is_up"], "true")

    def test_source_schema_accepts_superset_and_rejects_missing_or_malformed(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            tmp = Path(raw_tmp)
            superset = tmp / "superset.csv"
            first_source_row = SOURCE_ROWS.splitlines()[0]
            superset.write_text(
                SOURCE_HEADER.removesuffix("\n") + ",unused_feature\n" + first_source_row + ",1\n"
            )
            superset_run = self._generate(
                superset,
                tmp / "superset-out.csv",
                0,
                check=False,
            )

            missing = tmp / "missing.csv"
            missing.write_text(
                SOURCE_HEADER.replace("spot,", "", 1)
                + first_source_row.split(",", 1)[1]
                + "\n"
            )
            missing_run = self._generate(
                missing,
                tmp / "missing-out.csv",
                0,
                check=False,
            )

            malformed = tmp / "malformed.csv"
            malformed.write_text(
                SOURCE_HEADER + first_source_row.replace("true", "treu", 1) + "\n"
            )
            malformed_run = self._generate(
                malformed,
                tmp / "malformed-out.csv",
                0,
                check=False,
            )

            short_superset_row = tmp / "short-superset-row.csv"
            short_superset_row.write_text(
                SOURCE_HEADER.removesuffix("\n")
                + ",unused_feature\n"
                + first_source_row
                + "\n"
            )
            short_superset_row_run = self._generate(
                short_superset_row,
                tmp / "short-superset-row-out.csv",
                0,
                check=False,
            )

            self.assertEqual(superset_run.returncode, 0)
            self.assertNotEqual(missing_run.returncode, 0)
            self.assertIn("missing required columns: spot", missing_run.stderr)
            self.assertNotEqual(malformed_run.returncode, 0)
            self.assertIn("invalid rho_negative", malformed_run.stderr)
            self.assertNotEqual(short_superset_row_run.returncode, 0)
            self.assertIn(
                "does not match the source schema", short_superset_row_run.stderr
            )

    def test_source_a_sign_is_preserved_when_present_and_defaults_positive(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            tmp = Path(raw_tmp)
            unsigned = tmp / "unsigned.csv"
            unsigned.write_text(SOURCE_HEADER + SOURCE_ROWS.splitlines()[0] + "\n")
            signed = tmp / "signed.csv"
            signed.write_text(
                SOURCE_HEADER.removesuffix("\n").replace("a,b", "a,a_negative,b")
                + "\n"
                + SOURCE_ROWS.splitlines()[0].replace("171736,7449196", "171736,true,7449196")
                + "\n"
            )
            malformed = tmp / "malformed-sign.csv"
            malformed.write_text(signed.read_text().replace("171736,true", "171736,treu"))

            positive = scenario_generator.read_snapshots(unsigned)[0]
            negative = scenario_generator.read_snapshots(signed)[0]

            self.assertFalse(positive["a_negative"])
            self.assertTrue(negative["a_negative"])
            self.assertTrue(scenario_generator.oracle_fields(negative)["a_negative"])
            self.assertTrue(scenario_generator.svi_for_replay(negative)["aNegative"])
            with self.assertRaisesRegex(
                scenario_generator.GenerationError,
                "invalid a_negative",
            ):
                scenario_generator.read_snapshots(malformed)


if __name__ == "__main__":
    unittest.main()
