from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SIM_DIR = Path(__file__).resolve().parents[1]
GENERATOR = SIM_DIR / "data" / "generate_scenario.py"
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
    def _generate(self, source: Path, out: Path, seed: int) -> None:
        subprocess.run(
            [
                sys.executable,
                str(GENERATOR),
                "--source",
                str(source),
                "--config",
                str(CONFIG),
                "--out",
                str(out),
                "--seed",
                str(seed),
            ],
            check=True,
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


if __name__ == "__main__":
    unittest.main()
