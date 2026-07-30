from __future__ import annotations

import contextlib
import json
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

from harness import cli, config, live, publish, run as run_mod, staging


class StagingTests(unittest.TestCase):
    def test_external_specs_come_from_matching_canonical_manifests(self) -> None:
        specs = staging.external_dependency_specs()

        self.assertEqual(set(specs), set(config.GIT_DEP_NAMES))
        for spec in specs.values():
            self.assertEqual(len(spec.rev), 40)
            self.assertRegex(spec.rev, r"^[0-9a-f]{40}$")
            self.assertTrue(spec.repo.startswith("https://"))
            self.assertTrue(spec.subdir)

    def test_checkout_fingerprint_includes_publication_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            packages = Path(tmp)
            package = packages / "a"
            package.mkdir()
            (package / "Move.toml").write_text('[package]\nname = "a"\n')
            (package / "Move.lock").write_text("[move]\nversion = 4\n")
            before = staging.checkout_fingerprint(packages, ["a"])

            (package / "Published.toml").write_text(
                '[published.testnet]\nchain-id = "4c78adac"\n'
            )

            self.assertNotEqual(before, staging.checkout_fingerprint(packages, ["a"]))

    def test_workspace_validation_rejects_paths_outside_stage(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            workspace = Path(tmp) / "workspace"
            outside = Path(tmp) / "outside"
            workspace.mkdir()
            outside.mkdir()

            with self.assertRaisesRegex(ValueError, "escapes disposable workspace"):
                staging.require_staged_path(workspace, outside)

    def test_workspace_validation_rejects_ephemeral_manifest_environment(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            workspace = Path(tmp)
            for name in config.LOCAL_CLOSURE:
                package = workspace / "packages" / name
                package.mkdir(parents=True)
                (package / "Move.toml").write_text(
                    f'[package]\nname = "{name}"\n\n[dependencies]\n'
                )
            for name in config.GIT_DEP_NAMES:
                package = workspace / "deps" / name
                package.mkdir(parents=True)
                (package / "Move.toml").write_text(
                    f'[package]\nname = "{name}"\n\n[dependencies]\n'
                )
            (workspace / "packages" / "predict" / "Move.toml").write_text(
                '[package]\nname = "deepbook_predict"\n\n'
                "[dependencies]\n"
                'token = { local = "../token" }\n\n'
                "[environments]\n"
                'sim = "local-chain"\n'
            )

            with self.assertRaisesRegex(ValueError, "ephemeral environments"):
                staging.validate_workspace(workspace)

    def test_workspace_validation_rejects_ephemeral_replacement_environment(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            workspace = Path(tmp)
            for name in config.LOCAL_CLOSURE:
                package = workspace / "packages" / name
                package.mkdir(parents=True)
                (package / "Move.toml").write_text(
                    f'[package]\nname = "{name}"\n\n[dependencies]\n'
                )
            for name in config.GIT_DEP_NAMES:
                package = workspace / "deps" / name
                package.mkdir(parents=True)
                (package / "Move.toml").write_text(
                    f'[package]\nname = "{name}"\n\n[dependencies]\n'
                )
            (workspace / "packages" / "predict" / "Move.toml").write_text(
                '[package]\nname = "deepbook_predict"\n\n'
                "[dependencies]\n\n"
                "[dep-replacements.localnet]\n"
                'token = { local = "../token" }\n'
            )

            with self.assertRaisesRegex(ValueError, "ephemeral environments"):
                staging.validate_workspace(workspace)

    def test_git_stage_exports_commit_not_dirty_cache(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repository = root / "cache"
            package = repository / "move" / "package"
            package.mkdir(parents=True)
            subprocess.run(["git", "init", "-q", str(repository)], check=True)
            (package / "Move.toml").write_text('[package]\nname = "upstream"\n')
            subprocess.run(
                ["git", "-C", str(repository), "add", "move/package/Move.toml"],
                check=True,
            )
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(repository),
                    "-c",
                    "user.name=Test",
                    "-c",
                    "user.email=test@example.com",
                    "commit",
                    "-q",
                    "-m",
                    "fixture",
                ],
                check=True,
            )
            revision = subprocess.run(
                ["git", "-C", str(repository), "rev-parse", "HEAD"],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
            (package / "Move.toml").write_text('[package]\nname = "dirty"\n')
            (package / "Published.toml").write_text("[published.testnet]\n")
            destination = root / "destination"
            spec = staging.GitDependency(
                name="upstream",
                repo="https://example.com/upstream.git",
                rev=revision,
                subdir="move/package",
            )

            with mock.patch.object(
                staging.GitDependency,
                "cache_root",
                return_value=repository,
            ):
                staging._stage_git_dep(spec, destination)

            self.assertEqual(
                (destination / "Move.toml").read_text(),
                '[package]\nname = "upstream"\n',
            )
            self.assertFalse((destination / "Published.toml").exists())


class PublicationPlanTests(unittest.TestCase):
    def test_publication_order_is_topological(self) -> None:
        order = publish.publication_order()
        positions = {name: index for index, name in enumerate(order)}

        self.assertEqual(set(order), set(publish.PUBLISH_GRAPH))
        for package, dependencies in publish.PUBLISH_GRAPH.items():
            for dependency in dependencies:
                self.assertLess(positions[dependency], positions[package])

    def test_publication_order_rejects_cycle(self) -> None:
        with self.assertRaisesRegex(ValueError, "cycle"):
            publish.publication_order({"a": ("b",), "b": ("a",)})

    def test_publication_order_rejects_missing_node(self) -> None:
        with self.assertRaisesRegex(ValueError, "missing package"):
            publish.publication_order({"a": ("missing",)})

    def test_consumer_rewrite_is_confined_to_staged_manifest(self) -> None:
        canonical = (
            '[package]\nname = "consumer"\n\n'
            "[dependencies]\n"
            'pyth_lazer = { git = "https://example/pyth.git", subdir = "sui", '
            'rev = "1111111111111111111111111111111111111111" }\n'
            'bs_oracle = { git = "https://example/bs.git", subdir = "move", '
            'rev = "2222222222222222222222222222222222222222" }\n\n'
            "[dep-replacements.testnet]\n"
            'pyth_lazer = { git = "https://example/pyth.git", subdir = "sui", '
            'rev = "1111111111111111111111111111111111111111", '
            'published-at = "0x1", original-id = "0x1" }\n'
            'wormhole = { git = "https://example/wormhole.git", subdir = "sui", '
            'rev = "3333333333333333333333333333333333333333", '
            'published-at = "0x2", original-id = "0x2" }\n'
        )
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            canonical_manifest = root / "canonical" / "Move.toml"
            canonical_manifest.parent.mkdir()
            canonical_manifest.write_text(canonical)
            manifest = root / "workspace" / "Move.toml"
            manifest.parent.mkdir()
            manifest.write_text(canonical)
            pyth = root / "workspace" / "deps" / "pyth"
            wormhole = root / "workspace" / "deps" / "wormhole"
            bs_oracle = root / "workspace" / "deps" / "bs"

            publish.rewrite_consumer(
                manifest,
                pyth,
                "0x11",
                wormhole,
                "0x22",
                bs_oracle,
                "0x33",
            )
            rewritten = manifest.read_text()

            self.assertIn(f'pyth_lazer = {{ local = "{pyth}" }}', rewritten)
            self.assertIn(f'bs_oracle = {{ local = "{bs_oracle}" }}', rewritten)
            self.assertIn("[dep-replacements.testnet]", rewritten)
            self.assertIn('published-at = "0x22"', rewritten)
            self.assertNotIn("dep-replacements.sim", rewritten)
            self.assertEqual(canonical_manifest.read_text(), canonical)

    def test_bs_oracle_rewrite_aligns_only_staged_framework_dependencies(self) -> None:
        canonical = (
            '[package]\nname = "bs_oracle"\nedition = "2024"\nversion = "0.0.1"\n\n'
            "# Explicitly pinned rather than left to the implicit Sui floor.\n"
            "# The canonical upstream package owns this compiler choice.\n\n"
            "[dependencies]\n"
            'Sui = { git = "https://github.com/MystenLabs/sui.git", '
            'subdir = "crates/sui-framework/packages/sui-framework", '
            'rev = "1111111111111111111111111111111111111111" }\n'
            'MoveStdlib = { git = "https://github.com/MystenLabs/sui.git", '
            'subdir = "crates/sui-framework/packages/move-stdlib", '
            'rev = "1111111111111111111111111111111111111111" }\n\n'
            "[addresses]\n"
            'bs_oracle = "0x0"\n'
        )
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            canonical_manifest = root / "canonical" / "Move.toml"
            canonical_manifest.parent.mkdir()
            canonical_manifest.write_text(canonical)
            staged_manifest = root / "workspace" / "Move.toml"
            staged_manifest.parent.mkdir()
            staged_manifest.write_text(canonical)

            publish.rewrite_bs_oracle(staged_manifest)
            rewritten = staged_manifest.read_text()

            self.assertIn("[dependencies]\n", rewritten)
            self.assertNotIn("Sui = {", rewritten)
            self.assertNotIn("MoveStdlib = {", rewritten)
            self.assertNotIn("# Explicitly pinned", rewritten)
            self.assertEqual(canonical_manifest.read_text(), canonical)

    def test_external_lock_reset_is_confined_to_staged_package(self) -> None:
        lock = '[pinned.testnet.Sui]\nsource = { rev = "old-framework" }\n'
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            canonical = root / "canonical"
            canonical.mkdir()
            (canonical / "Move.lock").write_text(lock)
            staged = root / "workspace"
            staged.mkdir()
            (staged / "Move.lock").write_text(lock)

            publish.reset_staged_lock(staged)

            self.assertFalse((staged / "Move.lock").exists())
            self.assertEqual((canonical / "Move.lock").read_text(), lock)

    def test_test_publish_uses_real_build_environment_and_no_bundle_flag(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workspace = root / "workspace"
            package = workspace / "packages" / "token"
            package.mkdir(parents=True)
            client_config = root / "client.yaml"
            pubfile = root / "Pub.sim.toml"
            response = subprocess.CompletedProcess(
                args=[],
                returncode=0,
                stdout=json.dumps(
                    {"objectChanges": [{"type": "published", "packageId": "0x1"}]}
                ),
                stderr="",
            )

            with mock.patch.object(publish.suicli, "run", return_value=response) as run:
                publish._test_publish(
                    client_config,
                    workspace,
                    package,
                    pubfile,
                    config.GAS_BUDGET,
                )

            args = run.call_args.args[0]
            self.assertEqual(args[args.index("--build-env") + 1], "testnet")
            self.assertEqual(args[args.index("--pubfile-path") + 1], str(pubfile))
            self.assertNotIn("--allow-dirty", args)
            self.assertNotIn("--skip-dependency-verification", args)
            self.assertNotIn("--with-unpublished-dependencies", args)
            self.assertNotIn("--publish-unpublished-deps", args)

    def test_stage_and_publish_checks_checkout_after_failure(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            workspace = Path(tmp) / "workspace"
            failure = RuntimeError("publish stopped")
            with (
                mock.patch.object(staging, "stage_closure") as stage,
                mock.patch.object(publish, "publish_closure", side_effect=failure),
                mock.patch.object(
                    staging, "checkout_fingerprint", return_value="unchanged"
                ) as fingerprint,
            ):
                with self.assertRaisesRegex(RuntimeError, "publish stopped"):
                    publish.stage_and_publish(
                        Path(tmp) / "client.yaml",
                        workspace,
                        Path(tmp) / "Pub.sim.toml",
                    )

            stage.assert_called_once_with(workspace)
            self.assertEqual(fingerprint.call_count, 2)

    def test_stage_and_publish_rejects_checkout_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            with (
                mock.patch.object(staging, "stage_closure"),
                mock.patch.object(publish, "publish_closure", return_value={}),
                mock.patch.object(
                    staging,
                    "checkout_fingerprint",
                    side_effect=["before", "after"],
                ),
            ):
                with self.assertRaisesRegex(RuntimeError, "mutated canonical"):
                    publish.stage_and_publish(
                        Path(tmp) / "client.yaml",
                        Path(tmp) / "workspace",
                        Path(tmp) / "Pub.sim.toml",
                    )


class LifecycleTests(unittest.TestCase):
    def test_campaign_requires_timeout_for_unbounded_strategy(self) -> None:
        error = live._campaign_validation_error(
            ["fuzz", "mint-only"],
            timeout=0,
            strat_meta={
                "fuzz": {"maxOps": 0, "requiresTimeout": True},
                "mint-only": {"maxOps": 10, "requiresTimeout": False},
            },
            capacity=2,
        )

        self.assertEqual(error, "--timeout is required for unbounded strategies: fuzz")
        self.assertIsNone(
            live._campaign_validation_error(
                ["claim-marginal"],
                timeout=0,
                strat_meta={
                    "claim-marginal": {
                        "maxOps": 0,
                        "requiresTimeout": False,
                    }
                },
                capacity=1,
            )
        )

    def test_campaign_rejects_more_localnets_than_capacity(self) -> None:
        error = live._campaign_validation_error(
            ["a", "b"],
            timeout=10,
            strat_meta={"a": {"maxOps": 1}, "b": {"maxOps": 1}},
            capacity=1,
        )

        self.assertIn("above the configured capacity 1", error)

    def test_campaign_interrupt_closes_worker_entered_localnets(self) -> None:
        exits: list[str] = []

        class Manager:
            def __init__(self, name: str):
                self.name = name

            def __enter__(self):
                return {
                    "run_id": self.name,
                    "instance_dir": Path(self.name),
                    "rpc_port": 9000,
                    "deployment": {
                        "meta": {"chain_id": self.name},
                        "packages": {},
                    },
                }

            def __exit__(self, *_args):
                exits.append(self.name)

        def interrupt_after_workers(futures):
            for future in futures:
                future.result(timeout=5)
            raise KeyboardInterrupt
            yield  # pragma: no cover - makes this a generator for the for-loop

        with (
            contextlib.ExitStack() as stack,
            mock.patch.object(
                live,
                "oracle_ready_localnet",
                side_effect=lambda name, keep: Manager(name),
            ),
            mock.patch.object(live, "as_completed", side_effect=interrupt_after_workers),
        ):
            with self.assertRaises(KeyboardInterrupt):
                live._setup_campaign_localnets(["a", "b"], stack, 2)

        self.assertCountEqual(exits, ["a", "b"])

    def test_campaign_keyboard_interrupt_from_future_propagates(self) -> None:
        class InterruptedManager:
            def __enter__(self):
                raise KeyboardInterrupt

            def __exit__(self, *_args):
                raise AssertionError("a context that never entered must not be closed")

        with (
            contextlib.ExitStack() as stack,
            mock.patch.object(
                live,
                "oracle_ready_localnet",
                return_value=InterruptedManager(),
            ),
        ):
            with self.assertRaises(KeyboardInterrupt):
                live._setup_campaign_localnets(["interrupted"], stack, 1)

    def test_publish_localnet_finishes_staging_before_genesis(self) -> None:
        failure = RuntimeError("staging failed")
        with tempfile.TemporaryDirectory() as tmp:
            with (
                mock.patch.object(publish, "staged_closure", side_effect=failure),
                mock.patch.object(run_mod.localnet, "genesis") as genesis,
                mock.patch.object(run_mod.localnet, "stop") as stop,
            ):
                with self.assertRaisesRegex(RuntimeError, "staging failed"):
                    run_mod._publish_localnet(
                        "test-run",
                        {"rpc_port": 9000, "faucet_port": 9123, "offset": 0},
                        Path(tmp),
                    )

            genesis.assert_not_called()
            stop.assert_called_once_with(None)

    def test_publish_localnet_stops_started_process_on_interrupt(self) -> None:
        process = mock.Mock(pid=1234)
        stage = mock.MagicMock()
        stage.return_value.__enter__.return_value = {}
        with tempfile.TemporaryDirectory() as tmp:
            with (
                mock.patch.object(publish, "staged_closure", stage),
                mock.patch.object(
                    run_mod.localnet,
                    "genesis",
                    return_value=Path(tmp) / "client.yaml",
                ),
                mock.patch.object(run_mod.localnet, "start", return_value=process),
                mock.patch.object(
                    run_mod.localnet,
                    "wait_for_rpc",
                    side_effect=KeyboardInterrupt,
                ),
                mock.patch.object(run_mod.localnet, "stop") as stop,
                mock.patch.object(run_mod.state, "update"),
                mock.patch.object(run_mod.os, "getpgid", return_value=1234),
            ):
                with self.assertRaises(KeyboardInterrupt):
                    run_mod._publish_localnet(
                        "test-run",
                        {"rpc_port": 9000, "faucet_port": 9123, "offset": 0},
                        Path(tmp),
                    )

            stop.assert_called_once_with(process)

    def test_publish_localnet_stops_process_started_during_cancellation(self) -> None:
        process = mock.Mock(pid=1234)
        cancel_event = threading.Event()
        stage = mock.MagicMock()
        stage.return_value.__enter__.return_value = {}

        def start(*_args):
            cancel_event.set()
            return process

        with tempfile.TemporaryDirectory() as tmp:
            with (
                mock.patch.object(publish, "staged_closure", stage),
                mock.patch.object(
                    run_mod.localnet,
                    "genesis",
                    return_value=Path(tmp) / "client.yaml",
                ),
                mock.patch.object(run_mod.localnet, "start", side_effect=start),
                mock.patch.object(run_mod.localnet, "stop") as stop,
                mock.patch.object(run_mod.state, "update"),
                mock.patch.object(run_mod.os, "getpgid", return_value=1234),
            ):
                with self.assertRaisesRegex(run_mod.RunCancelled, "run cancelled"):
                    run_mod._publish_localnet(
                        "test-run",
                        {"rpc_port": 9000, "faucet_port": 9123, "offset": 0},
                        Path(tmp),
                        cancel_event,
                    )

            stop.assert_called_once_with(process)

    def test_run_stops_returned_process_when_cancellation_wins_the_return_race(self) -> None:
        process = mock.Mock(pid=1234)
        cancel_event = threading.Event()

        def publish_localnet(run_id, slot, inst, event):
            run_mod._register_localnet(run_id, process)
            event.set()
            return {"proc": process, "deployment": {"packages": {}}}

        with (
            mock.patch.object(run_mod, "_make_run_id", return_value="test-run"),
            mock.patch.object(
                run_mod.staging,
                "checkout_fingerprint",
                return_value="unchanged",
            ),
            mock.patch.object(
                run_mod.state,
                "reserve",
                return_value={"rpc_port": 9000, "faucet_port": 9123, "offset": 0},
            ),
            mock.patch.object(run_mod, "_publish_localnet", side_effect=publish_localnet),
            mock.patch.object(run_mod.localnet, "stop") as stop,
            mock.patch.object(run_mod.state, "release") as release,
        ):
            result = run_mod.run(cancel_event=cancel_event)

        self.assertEqual(result.error, "RunCancelled: run cancelled")
        stop.assert_called_once_with(process)
        release.assert_called_once_with("test-run")
        self.assertNotIn("test-run", run_mod._ACTIVE_LOCALNETS)

    def test_sigterm_runs_command_cleanup_and_returns_130(self) -> None:
        script = (
            "import signal\n"
            "import sys\n"
            "from pathlib import Path\n"
            "from harness import cli\n"
            "cleanup = Path(sys.argv[1])\n"
            "def command():\n"
            "    try:\n"
            "        print('ready', flush=True)\n"
            "        signal.pause()\n"
            "    finally:\n"
            "        cleanup.write_text('cleaned\\n')\n"
            "raise SystemExit(cli._run_with_sigterm_handler(command))\n"
        )
        with tempfile.TemporaryDirectory() as tmp:
            cleanup = Path(tmp) / "cleanup"
            environment = {**os.environ, "PYTHONPATH": str(config.PREDICT_DIR)}
            with subprocess.Popen(
                [sys.executable, "-c", script, str(cleanup)],
                cwd=config.PREDICT_DIR,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            ) as proc:
                try:
                    self.assertEqual(proc.stdout.readline().strip(), "ready")
                    proc.terminate()
                    _stdout, stderr = proc.communicate(timeout=5)

                    self.assertEqual(proc.returncode, 130, stderr)
                    self.assertEqual(cleanup.read_text(), "cleaned\n")
                finally:
                    if proc.poll() is None:
                        proc.kill()
                        proc.wait(timeout=5)

    def test_keyboard_interrupt_stops_any_registered_localnet(self) -> None:
        def interrupt() -> int:
            raise KeyboardInterrupt

        with mock.patch.object(cli.run_mod, "stop_active_localnets") as stop:
            result = cli._run_with_sigterm_handler(interrupt)

        self.assertEqual(result, 130)
        stop.assert_called_once_with()

    def test_run_many_drains_every_run_through_the_bounded_pool(self) -> None:
        started = []

        def fake_run(name, keep, cancel_event):
            started.append(name)
            return mock.Mock(
                ok=True,
                checkout_clean=True,
                offset=0,
                elapsed_s=0,
                error=None,
            )

        args = mock.Mock(count=4, concurrency=2, keep=False)
        with mock.patch.object(cli.run_mod, "run", side_effect=fake_run):
            result = cli._cmd_run_many(args)

        self.assertEqual(result, 0)
        self.assertCountEqual(started, ["p0", "p1", "p2", "p3"])

    def test_run_many_sigterm_cancels_pending_and_stops_active_process(self) -> None:
        script = (
            "import argparse\n"
            "import subprocess\n"
            "import sys\n"
            "from pathlib import Path\n"
            "from types import SimpleNamespace\n"
            "from harness import cli, run as run_mod\n"
            "started = Path(sys.argv[1])\n"
            "def fake_run(name, keep, cancel_event):\n"
            "    child = subprocess.Popen(\n"
            "        [sys.executable, '-c', 'import signal; signal.pause()'],\n"
            "        start_new_session=True,\n"
            "    )\n"
            "    run_mod._register_localnet(name, child)\n"
            "    try:\n"
            "        with started.open('a') as output:\n"
            "            output.write(f'{name} {child.pid}\\n')\n"
            "        child.wait()\n"
            "    finally:\n"
            "        run_mod._unregister_localnet(name, child)\n"
            "    return SimpleNamespace(\n"
            "        ok=True, checkout_clean=True, offset=0, elapsed_s=0, error=None\n"
            "    )\n"
            "cli.run_mod.run = fake_run\n"
            "args = argparse.Namespace(count=4, concurrency=1, keep=False)\n"
            "raise SystemExit(cli._run_with_sigterm_handler(\n"
            "    lambda: cli._cmd_run_many(args)\n"
            "))\n"
        )
        child_pid = None
        with tempfile.TemporaryDirectory() as tmp:
            started = Path(tmp) / "started"
            environment = {**os.environ, "PYTHONPATH": str(config.PREDICT_DIR)}
            with subprocess.Popen(
                [sys.executable, "-c", script, str(started)],
                cwd=config.PREDICT_DIR,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            ) as proc:
                try:
                    deadline = time.monotonic() + 5
                    while (
                        not started.exists()
                        and proc.poll() is None
                        and time.monotonic() < deadline
                    ):
                        time.sleep(0.01)
                    self.assertTrue(started.exists(), "run-many worker did not become ready")

                    started_name, pid = started.read_text().split()
                    child_pid = int(pid)
                    proc.terminate()
                    _stdout, stderr = proc.communicate(timeout=5)

                    self.assertEqual(proc.returncode, 130, stderr)
                    self.assertEqual(started_name, "p0")
                    self.assertEqual(len(started.read_text().splitlines()), 1)
                    with self.assertRaises(ProcessLookupError):
                        os.kill(child_pid, 0)
                finally:
                    if proc.poll() is None:
                        proc.kill()
                        proc.wait(timeout=5)
                    if child_pid is not None:
                        try:
                            os.killpg(child_pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass


if __name__ == "__main__":
    unittest.main()
