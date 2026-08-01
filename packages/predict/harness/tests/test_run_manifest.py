from __future__ import annotations

import json
import tempfile
import unittest
from contextlib import nullcontext
from pathlib import Path
from unittest import mock

from harness import parity, run_manifest


class RunManifestTests(unittest.TestCase):
    def test_benchmark_runs_and_compares_independent_python_replay(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            source = root / "source.csv"
            source.write_text("source\n")
            instance = root / "benchmark-test"
            artifacts = instance / "artifacts"
            artifacts.mkdir(parents=True)
            delivered = root / "delivered-results.json"
            context = {
                "run_id": "benchmark-test",
                "instance_dir": instance,
                "deployment": {
                    "meta": {"chain_id": "local-chain", "rpc_port": 9007},
                    "packages": {},
                    "objects": {},
                },
            }

            def generate(_source, scenario, _seed):
                scenario.write_text("scenario\n")

            def run_command(command, **_kwargs):
                if command[1] == "simulations/write_benchmark_results.py":
                    Path(command[3]).write_text('{"gas":"ok"}\n')

            with (
                mock.patch.object(
                    parity,
                    "initialized_localnet",
                    return_value=nullcontext(context),
                ),
                mock.patch.object(parity, "_generate_scenario", side_effect=generate),
                mock.patch.object(parity, "new_manifest", return_value={}),
                mock.patch.object(parity, "write_manifest"),
                mock.patch.object(parity, "complete_manifest"),
                mock.patch.object(
                    parity.subprocess,
                    "run",
                    side_effect=run_command,
                ) as run,
            ):
                result = parity.run(
                    source=str(source),
                    max_rows=5,
                    benchmark=True,
                    results_output=str(delivered),
                )

            self.assertEqual(result, 0)
            commands = [call.args[0] for call in run.call_args_list]
            self.assertEqual(
                commands[0],
                ["npx", "tsx", "simulations/src/sim.ts", "--max-rows", "5"],
            )
            self.assertEqual(commands[1][1], "simulations/compare_parity.py")
            self.assertEqual(commands[2][1], "simulations/write_benchmark_results.py")
            self.assertEqual(delivered.read_text(), '{"gas":"ok"}\n')

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
                    arguments={"seed": 17, "max_rows": 5},
                )
            manifest["inputs"] = {
                "source": run_manifest.file_input(source),
                "scenario": run_manifest.file_input(scenario),
                "config": run_manifest.file_input(config, include_value=True),
            }
            manifest_path = root / "run-manifest.json"
            manifest["localnets"] = [
                run_manifest.localnet_record(
                    role="parity",
                    run_id="parity-test",
                    instance_dir=root / "instance",
                    manifest_path=manifest_path,
                    deployment=deployment,
                    setup_duration_s=None,
                    actors=["simulation"],
                )
            ]

            self.assertEqual(
                manifest["inputs"]["source"]["sha256"],
                "b8bb034f9b63bd0254fbc7c157cae746c75853f4643d6cea844dc48ddb57f522",
            )
            self.assertEqual(
                manifest["inputs"]["scenario"]["sha256"],
                "e39327dbc69e749b1eb6704c079c529ab27eca8ef4d502c7f3d665cf8af57251",
            )
            self.assertEqual(manifest["arguments"]["seed"], 17)
            self.assertEqual(manifest["arguments"]["max_rows"], 5)
            self.assertEqual(
                manifest["inputs"]["config"]["value"],
                {"protocol": {"base_fee": "20000000"}},
            )
            self.assertEqual(manifest["source_revision"]["commit"], "abc123")
            self.assertEqual(
                manifest["localnets"][0]["deployment"]["chain_id"],
                "local-chain",
            )
            self.assertEqual(
                manifest["localnets"][0]["deployment"]["package_ids"]["predict"],
                "0x123",
            )
            self.assertEqual(manifest["localnets"][0]["instance_dir"], "instance")

    def test_parity_manifest_records_scenario_generation_failure(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            source = root / "source.csv"
            source.write_text("source\n")
            instance = root / "parity-test"
            (instance / "artifacts").mkdir(parents=True)
            context = {
                "run_id": "parity-test",
                "instance_dir": instance,
                "deployment": {
                    "meta": {"chain_id": "local-chain", "rpc_port": 9007},
                    "packages": {"predict": "0x123"},
                    "objects": {},
                },
            }

            with (
                mock.patch.object(
                    parity,
                    "initialized_localnet",
                    return_value=nullcontext(context),
                ),
                mock.patch.object(
                    parity,
                    "_generate_scenario",
                    side_effect=RuntimeError("generation failed"),
                ),
                mock.patch.object(
                    run_manifest,
                    "source_revision",
                    return_value={"commit": "abc123", "dirty": False},
                ),
            ):
                with self.assertRaisesRegex(RuntimeError, "generation failed"):
                    parity.run(source=str(source))

            manifest = json.loads(
                (instance / "artifacts" / "run-manifest.json").read_text()
            )
            self.assertEqual(manifest["status"], "failed")
            self.assertEqual(
                manifest["termination"],
                {
                    "reason": "execution_failure",
                    "error": "RuntimeError: generation failed",
                    "exit_code": 1,
                },
            )
            self.assertEqual(set(manifest["inputs"]), {"source", "config"})
            self.assertEqual(
                manifest["artifacts"],
                {
                    "scenario": "scenario.csv",
                    "local_data": "local_data.json",
                    "python_data": "python_data.json",
                    "local_trace": "local_trace.json",
                    "state": "state.json",
                },
            )

    def test_write_manifest_replaces_valid_json_and_removes_pending_file(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            path = root / "run-manifest.json"
            with mock.patch.object(
                run_manifest,
                "source_revision",
                return_value={"commit": "abc123", "dirty": False},
            ):
                manifest = run_manifest.new_manifest(
                    engine="campaign",
                    run_id="campaign-test",
                    repo=root,
                    arguments={"strategies": ["fuzz"]},
                )
            run_manifest.write_manifest(path, manifest)
            run_manifest.complete_manifest(
                manifest,
                status="complete",
                reason="completed",
                exit_code=0,
            )
            run_manifest.write_manifest(path, manifest)

            self.assertEqual(json.loads(path.read_text())["status"], "complete")
            self.assertFalse(path.with_suffix(".json.tmp").exists())

    def test_load_manifest_rejects_incomplete_and_unknown_schemas(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            with mock.patch.object(
                run_manifest,
                "source_revision",
                return_value={"commit": "abc123", "dirty": False},
            ):
                manifest = run_manifest.new_manifest(
                    engine="campaign",
                    run_id="campaign-test",
                    repo=root,
                    arguments={"strategies": ["fuzz"]},
                )
            path = root / "manifest.json"
            run_manifest.write_manifest(path, manifest)

            with self.assertRaisesRegex(ValueError, "incomplete"):
                run_manifest.load_manifest(path, require_terminal=True)

            manifest["unexpected"] = True
            path.write_text(json.dumps(manifest))
            with self.assertRaisesRegex(ValueError, "unknown=unexpected"):
                run_manifest.load_manifest(path)

    def test_complete_manifest_records_terminal_reason_and_exit_code(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            with mock.patch.object(
                run_manifest,
                "source_revision",
                return_value={"commit": "abc123", "dirty": False},
            ):
                manifest = run_manifest.new_manifest(
                    engine="campaign",
                    run_id="campaign-test",
                    repo=root,
                    arguments={"strategies": ["fuzz"]},
                )
            run_manifest.complete_manifest(
                manifest,
                status="failed",
                reason="analysis_failure",
                exit_code=1,
                error="trace missing",
            )

            validated = run_manifest.validate_manifest(
                manifest,
                require_terminal=True,
            )
            self.assertEqual(validated["status"], "failed")
            self.assertEqual(
                validated["termination"],
                {
                    "reason": "analysis_failure",
                    "error": "trace missing",
                    "exit_code": 1,
                },
            )


if __name__ == "__main__":
    unittest.main()
