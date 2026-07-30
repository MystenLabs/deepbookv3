from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from harness import analyze, verdict


class VerdictTests(unittest.TestCase):
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
            (trace / "keeper.jsonl").write_text('{"type":"heartbeat","ts":1}\n')
            (trace / "trader.jsonl").write_text(
                '{"type":"expect","terminal":["dynamic_field:0"],"ts":2}\n'
                '{"type":"fail","tag":"dynamic_field:0","ts":3}\n'
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
            (trace / "keeper.jsonl").write_text('{"type":"heartbeat","ts":1}\n')
            (trace / "trader.jsonl").write_text(
                '{"type":"expect","terminal":["cached objects limit"],"ts":2}\n'
                '{"type":"fail","tag":"dynamic_field:0","ts":3}\n'
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
            (trace / "keeper.jsonl").write_text('{"type":"heartbeat","ts":1}\n')
            (trace / "trader.jsonl").write_text(
                '{"type":"expect","terminal":["cached objects limit"],"ts":2}\n'
                '{"type":"fail","tag":"dynamic_field:0","ts":3}\n'
                '{"type":"fail","tag":"coin:1","ts":4}\n'
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
            (trace / "keeper.jsonl").write_text('{"type":"heartbeat","ts":1}\n')

            self.assertEqual(analyze.analyze([str(instance)], expect=["fuzz"]), 1)


if __name__ == "__main__":
    unittest.main()
