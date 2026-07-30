from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from devtools import run_manifest
from harness import analyze, verdict


class VerdictTests(unittest.TestCase):
    def test_trace_loader_rejects_malformed_and_unversioned_records(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            trace = Path(directory)
            path = trace / "keeper.jsonl"
            path.write_text('{"schema":1,"type":"heartbeat","ts":1}\nnot-json\n')
            with self.assertRaisesRegex(ValueError, "malformed trace JSON"):
                analyze._load(trace)

            path.write_text('{"type":"heartbeat","ts":1}\n')
            with self.assertRaisesRegex(ValueError, "unsupported trace schema"):
                analyze._load(trace)

    def test_classification_distinguishes_guards_invariants_and_transients(self) -> None:
        expected, transient, flagged = verdict.classify_failures(
            [
                {"tag": "pricing:9"},
                {"tag": "lp_book:0"},
                {"tag": "math:3"},
                {"tag": "dynamic_field:500"},
                {"tag": "Pyth history HTTP 429"},
                {"tag": "Balance of gas object 10 is lower than the needed amount: 20"},
            ]
        )
        self.assertEqual(expected, {"pricing:9": 1, "lp_book:0": 1})
        self.assertEqual(
            transient,
            {
                "Pyth history HTTP 429": 1,
                "Balance of gas object 10 is lower than t": 1,
            },
        )
        self.assertEqual(flagged, ["math:3", "dynamic_field:500"])

    def test_numeric_move_abort_is_not_misclassified_as_network_transient(self) -> None:
        self.assertFalse(verdict.is_transient("rpc:500"))

    def test_vm_summary_preserves_status_and_human_message(self) -> None:
        source = (
            "ExecutionError status MEMORY_LIMIT_EXCEEDED at module 0xabc "
            "and message Object runtime cached objects limit reached at code offset 42"
        )
        self.assertEqual(
            verdict.vm_summary(source, ""),
            "MEMORY_LIMIT_EXCEEDED — Object runtime cached objects limit reached",
        )

    def test_vm_summary_accepts_structured_grpc_status_error(self) -> None:
        self.assertEqual(
            verdict.vm_summary(
                "",
                {
                    "$kind": "MoveAbort",
                    "message": "MoveAbort in dynamic_field::borrow_child_object",
                },
            ),
            "MoveAbort in dynamic_field::borrow_child_object",
        )

    def test_vm_errors_reads_framework_cause_from_failed_transaction_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            instance = Path(directory)
            artifacts = instance / "artifacts" / "failed_transactions"
            artifacts.mkdir(parents=True)
            (artifacts / "capacity-tree.json").write_text(
                json.dumps(
                    {
                        "status": {
                            "status": "failure",
                            "error": "MovePrimitiveRuntimeError in dynamic_field::borrow_child_object",
                        },
                        "dry_run": {
                            "executionErrorSource": (
                                "ExecutionError status MEMORY_LIMIT_EXCEEDED at module 0xabc "
                                "and message Object runtime cached objects limit reached at code offset 42"
                            ),
                            "effects": {
                                "status": {
                                    "status": "failure",
                                    "error": "MovePrimitiveRuntimeError in dynamic_field::borrow_child_object",
                                }
                            },
                        },
                    }
                )
            )

            self.assertEqual(
                verdict.vm_errors(instance),
                {
                    "MEMORY_LIMIT_EXCEEDED — Object runtime cached objects limit reached": 1
                },
            )

    def test_generic_declared_terminal_requires_matching_vm_cause(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            instance = Path(directory)
            trace = instance / "trace"
            trace.mkdir(parents=True)
            (trace / "keeper.jsonl").write_text(
                '{"schema":1,"type":"heartbeat","ts":1}\n'
            )
            (trace / "trader.jsonl").write_text(
                '{"schema":1,"type":"expect","terminal":["dynamic_field:0"],"ts":2}\n'
                '{"schema":1,"type":"fail","tag":"dynamic_field:0","ts":3}\n'
            )
            artifacts = instance / "artifacts" / "failed_transactions"
            artifacts.mkdir(parents=True)
            (artifacts / "unrelated.json").write_text(
                json.dumps(
                    {
                        "dry_run": {
                            "executionErrorSource": (
                                "ExecutionError status MEMORY_LIMIT_EXCEEDED at module 0xabc "
                                "and message unrelated dynamic-field failure at code offset 42"
                            ),
                            "effects": {
                                "status": {
                                    "status": "failure",
                                    "error": (
                                        "MovePrimitiveRuntimeError in "
                                        "dynamic_field::borrow_child_object"
                                    ),
                                }
                            },
                        }
                    }
                )
            )

            signals = analyze._analyze_one(instance)

            self.assertIn("dynamic_field:0", signals)
            self.assertIn(
                "VACUOUS: declared wall 'dynamic_field:0' never reached",
                signals,
            )

    def test_semantic_declared_terminal_accepts_matching_framework_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            instance = Path(directory)
            trace = instance / "trace"
            trace.mkdir(parents=True)
            (trace / "keeper.jsonl").write_text(
                '{"schema":1,"type":"heartbeat","ts":1}\n'
            )
            (trace / "trader.jsonl").write_text(
                '{"schema":1,"type":"expect","terminal":["cached objects limit"],"ts":2}\n'
                '{"schema":1,"type":"fail","tag":"dynamic_field:0","ts":3}\n'
            )
            artifacts = instance / "artifacts" / "failed_transactions"
            artifacts.mkdir(parents=True)
            (artifacts / "capacity-tree.json").write_text(
                json.dumps(
                    {
                        "dry_run": {
                            "executionErrorSource": (
                                "ExecutionError status MEMORY_LIMIT_EXCEEDED at module 0xabc "
                                "and message Object runtime cached objects limit reached "
                                "at code offset 42"
                            ),
                            "effects": {
                                "status": {
                                    "status": "failure",
                                    "error": (
                                        "MovePrimitiveRuntimeError in "
                                        "dynamic_field::borrow_child_object"
                                    ),
                                }
                            },
                        }
                    }
                )
            )

            self.assertEqual(analyze._analyze_one(instance), [])

    def test_semantic_terminal_does_not_hide_unrelated_abort(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            instance = Path(directory)
            trace = instance / "trace"
            trace.mkdir(parents=True)
            (trace / "keeper.jsonl").write_text(
                '{"schema":1,"type":"heartbeat","ts":1}\n'
            )
            (trace / "trader.jsonl").write_text(
                '{"schema":1,"type":"expect","terminal":["cached objects limit"],"ts":2}\n'
                '{"schema":1,"type":"fail","tag":"dynamic_field:0","ts":3}\n'
                '{"schema":1,"type":"fail","tag":"coin:1","ts":4}\n'
            )
            artifacts = instance / "artifacts" / "failed_transactions"
            artifacts.mkdir(parents=True)
            (artifacts / "capacity-tree.json").write_text(
                json.dumps(
                    {
                        "dry_run": {
                            "executionErrorSource": (
                                "ExecutionError status MEMORY_LIMIT_EXCEEDED at module 0xabc "
                                "and message Object runtime cached objects limit reached "
                                "at code offset 42"
                            ),
                            "effects": {
                                "status": {
                                    "status": "failure",
                                    "error": (
                                        "MovePrimitiveRuntimeError in "
                                        "dynamic_field::borrow_child_object"
                                    ),
                                }
                            },
                        }
                    }
                )
            )

            signals = analyze._analyze_one(instance)

            self.assertEqual(signals, ["coin:1"])

    def test_expected_strategy_requires_trader_progress(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            instance = Path(directory) / "fuzz-test"
            trace = instance / "trace"
            trace.mkdir(parents=True)
            (trace / "keeper.jsonl").write_text(
                '{"schema":1,"type":"heartbeat","ts":1}\n'
            )

            self.assertEqual(analyze.analyze([str(instance)], expect=["fuzz"]), 1)

    def test_campaign_manifest_rejects_incomplete_run(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest_path = root / "manifest.json"
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
            run_manifest.write_manifest(manifest_path, manifest)

            with self.assertRaisesRegex(ValueError, "incomplete"):
                analyze.analyze_manifest(manifest_path)

    def test_campaign_manifest_uses_declared_instance_roles(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            campaign = root / "campaign"
            campaign.mkdir()
            manifest_path = campaign / "manifest.json"
            instance = root / "instance-without-strategy-prefix"
            trace = instance / "trace"
            trace.mkdir(parents=True)
            (trace / "keeper.jsonl").write_text(
                '{"schema":1,"type":"heartbeat","ts":1}\n'
            )
            (trace / "trader.jsonl").write_text(
                '{"schema":1,"type":"mint","strategy":"fuzz","ts":2}\n'
            )
            deployment = {
                "meta": {"chain_id": "local-chain", "rpc_port": 9000},
                "packages": {"predict": "0xpackage"},
                "objects": {},
            }
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
            manifest["localnets"] = [
                run_manifest.localnet_record(
                    role="fuzz",
                    run_id="instance-test",
                    instance_dir=instance,
                    manifest_path=manifest_path,
                    deployment=deployment,
                    setup_duration_s=1.0,
                    actors=["keeper", "updater", "trader:fuzz"],
                )
            ]
            run_manifest.complete_manifest(
                manifest,
                status="complete",
                reason="completed",
                exit_code=0,
            )
            run_manifest.write_manifest(manifest_path, manifest)

            self.assertEqual(analyze.analyze_manifest(manifest_path), 0)


if __name__ == "__main__":
    unittest.main()
