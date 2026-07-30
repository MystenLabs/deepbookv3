from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from devtools import run_manifest


class RunManifestTests(unittest.TestCase):
    def test_manifest_captures_exact_input_hashes_and_localnet_identity(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            source = root / "source.csv"
            scenario = root / "scenario.csv"
            config = root / "config.json"
            source.write_text("source\n")
            scenario.write_text("scenario\n")
            config.write_text('{"protocol": {"base_fee": "20000000"}}\n')
            deployment = {
                "meta": {"chain_id": "local-chain", "rpc_port": 9007},
                "packages": {"predict": "0x123"},
            }

            with mock.patch.object(
                run_manifest,
                "source_revision",
                return_value={"commit": "abc123", "dirty": False},
            ):
                manifest = run_manifest.new_manifest(
                    engine="parity",
                    run_id="parity-test",
                    repo=root,
                    source=source,
                    scenario=scenario,
                    config=config,
                    seed=17,
                    command=["npx", "tsx", "simulations/src/sim.ts"],
                    max_rows=5,
                    deployment=deployment,
                )

            self.assertEqual(
                manifest["inputs"]["source"]["sha256"],
                "b8bb034f9b63bd0254fbc7c157cae746c75853f4643d6cea844dc48ddb57f522",
            )
            self.assertEqual(
                manifest["inputs"]["scenario"]["sha256"],
                "e39327dbc69e749b1eb6704c079c529ab27eca8ef4d502c7f3d665cf8af57251",
            )
            self.assertEqual(manifest["inputs"]["seed"], 17)
            self.assertEqual(manifest["inputs"]["max_rows"], 5)
            self.assertEqual(
                manifest["inputs"]["config"]["value"],
                {"protocol": {"base_fee": "20000000"}},
            )
            self.assertEqual(manifest["source_revision"]["commit"], "abc123")
            self.assertEqual(manifest["localnet"]["chain_id"], "local-chain")
            self.assertEqual(manifest["localnet"]["package_ids"]["predict"], "0x123")

    def test_write_manifest_replaces_valid_json_and_removes_pending_file(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            path = Path(raw_tmp) / "run-manifest.json"
            run_manifest.write_manifest(path, {"status": "running"})
            run_manifest.write_manifest(path, {"status": "complete"})

            self.assertEqual(json.loads(path.read_text()), {"status": "complete"})
            self.assertFalse(path.with_suffix(".json.tmp").exists())


if __name__ == "__main__":
    unittest.main()
