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

from harness import (
    analyze,
    cancellation,
    cli,
    config,
    live,
    localnet,
    oracle_setup,
    publish,
    run_manifest,
    session,
    staging,
)


_PINNED_REV = "1111111111111111111111111111111111111111"
_PYTH_REPO = "https://github.com/pyth-network/pyth-crosschain.git"
_WORMHOLE_REPO = "https://github.com/pyth-network/wormhole.git"
_BS_REPO = "https://github.com/blockscholes/sui-signed-oracle.git"


def _git_dep(name: str, repo: str, subdir: str, rev: str = _PINNED_REV) -> str:
    return f'{name} = {{ git = "{repo}", subdir = "{subdir}", rev = "{rev}" }}\n'


def _write_canonical_consumers(
    packages: Path,
    *,
    pyth_repo: str = _PYTH_REPO,
    pyth_subdir: str = "lazer/contracts/sui",
    wormhole_repo: str = _WORMHOLE_REPO,
    wormhole_subdir: str = "sui/wormhole",
    bs_repo: str = _BS_REPO,
    bs_oracle_subdir: str = "move/bs_oracle",
    bs_sid_subdir: str = "move/bs_sid",
) -> None:
    """Write matching Predict/Propbook manifests for coordinate-validation tests."""
    predict = (
        "[package]\nname = \"deepbook_predict\"\n\n[dependencies]\n"
        + _git_dep("pyth_lazer", pyth_repo, pyth_subdir)
        + _git_dep("bs_oracle", bs_repo, bs_oracle_subdir)
        + "\n[dep-replacements.testnet]\n"
        + _git_dep("wormhole", wormhole_repo, wormhole_subdir)
    )
    propbook = (
        "[package]\nname = \"propbook\"\n\n[dependencies]\n"
        + _git_dep("pyth_lazer", pyth_repo, pyth_subdir)
        + _git_dep("bs_oracle", bs_repo, bs_oracle_subdir)
        + _git_dep("bs_sid", bs_repo, bs_sid_subdir)
        + "\n[dep-replacements.testnet]\n"
        + _git_dep("wormhole", wormhole_repo, wormhole_subdir)
    )
    for name, text in (("predict", predict), ("propbook", propbook)):
        package = packages / name
        package.mkdir(parents=True)
        (package / "Move.toml").write_text(text)


class StagingTests(unittest.TestCase):
    def test_external_specs_come_from_matching_canonical_manifests(self) -> None:
        specs = staging.external_dependency_specs()

        self.assertEqual(set(specs), set(config.GIT_DEP_NAMES))
        for spec in specs.values():
            self.assertEqual(len(spec.rev), 40)
            self.assertRegex(spec.rev, r"^[0-9a-f]{40}$")
            self.assertIn(spec.repo, config.ALLOWED_GIT_REPOS)
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
                repo=_BS_REPO,
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

    def test_disallowed_repo_is_rejected_before_git_starts(self) -> None:
        spec = staging.GitDependency(
            name="pyth_lazer",
            repo="--upload-pack=true",
            rev=_PINNED_REV,
            subdir="lazer/contracts/sui",
        )
        with mock.patch.object(staging.cancellation, "run") as run:
            with self.assertRaisesRegex(ValueError, "not allowlisted"):
                staging._stage_git_dep(spec, Path("/unused"))
        run.assert_not_called()

    def test_unlisted_https_repo_is_rejected_before_git_starts(self) -> None:
        spec = staging.GitDependency(
            name="pyth_lazer",
            repo="https://github.com/octocat/Hello-World.git",
            rev=_PINNED_REV,
            subdir="lazer/contracts/sui",
        )
        with mock.patch.object(staging.cancellation, "run") as run:
            with self.assertRaisesRegex(ValueError, "not allowlisted"):
                staging._stage_git_dep(spec, Path("/unused"))
        run.assert_not_called()

    def test_unsafe_subdir_is_rejected_before_git_starts(self) -> None:
        cases = (
            "../secret",
            "/absolute/path",
            "move:evil",
            "-output",
            "move\\oracle",
            "",
        )
        for subdir in cases:
            spec = staging.GitDependency(
                name="bs_oracle",
                repo=_BS_REPO,
                rev=_PINNED_REV,
                subdir=subdir,
            )
            with self.subTest(subdir=subdir), mock.patch.object(
                staging.cancellation, "run"
            ) as run:
                with self.assertRaisesRegex(ValueError, "safe relative path"):
                    staging._stage_git_dep(spec, Path("/unused"))
                run.assert_not_called()

    def test_manifest_coordinate_is_rejected_before_git_starts(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            packages = Path(tmp)
            _write_canonical_consumers(packages, pyth_repo="--upload-pack=true")
            with mock.patch.object(staging.cancellation, "run") as run:
                with self.assertRaisesRegex(ValueError, "not allowlisted"):
                    staging.external_dependency_specs(packages)
            run.assert_not_called()

    def test_git_fetch_uses_end_of_options_and_disables_ext(self) -> None:
        spec = staging.GitDependency(
            name="pyth_lazer",
            repo=_PYTH_REPO,
            rev=_PINNED_REV,
            subdir="lazer/contracts/sui",
        )
        recorded: list[list[str]] = []

        def record(command, **_kwargs):
            recorded.append(list(command))
            if "fetch" in command:
                raise RuntimeError("stop after recording fetch argv")
            return mock.Mock(returncode=0, stdout=b"", stderr=b"")

        with tempfile.TemporaryDirectory() as tmp:
            destination = Path(tmp) / "pyth_lazer"
            with (
                mock.patch.object(staging, "_git_has_commit", return_value=False),
                mock.patch.object(staging.cancellation, "run", side_effect=record),
            ):
                with self.assertRaisesRegex(RuntimeError, "stop after recording"):
                    staging._stage_git_dep(spec, destination)

        self.assertGreaterEqual(len(recorded), 2)
        self.assertEqual(recorded[0][:3], ["git", "init", "-q"])
        fetch = recorded[1]
        self.assertEqual(fetch[:8], [
            "git",
            "-C",
            fetch[2],
            "-c",
            "protocol.ext.allow=never",
            "fetch",
            "-q",
            "--depth",
        ])
        self.assertEqual(fetch[8:], ["1", "--", spec.repo, spec.rev])


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
            'bs_sid = { git = "https://example/bs.git", subdir = "move/sid", '
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
            bs_sid = root / "workspace" / "deps" / "bs_sid"

            publish.rewrite_consumer(
                manifest,
                pyth,
                "0x11",
                wormhole,
                "0x22",
                bs_oracle,
                "0x33",
                bs_sid,
                "0x44",
            )
            rewritten = manifest.read_text()

            self.assertIn(f'pyth_lazer = {{ local = "{pyth}" }}', rewritten)
            self.assertIn(f'bs_oracle = {{ local = "{bs_oracle}" }}', rewritten)
            self.assertIn(f'bs_sid = {{ local = "{bs_sid}" }}', rewritten)
            self.assertIn("[dep-replacements.testnet]", rewritten)
            self.assertIn('published-at = "0x22"', rewritten)
            self.assertNotIn("dep-replacements.sim", rewritten)
            self.assertEqual(canonical_manifest.read_text(), canonical)

    def test_block_scholes_rewrite_aligns_only_staged_framework_dependencies(self) -> None:
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

            publish.rewrite_block_scholes_package(staged_manifest)
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

class LocalnetQueryTests(unittest.TestCase):
    def test_balance_unwraps_the_cli_coin_list(self) -> None:
        # `sui client balance --json` returns [coin_entries, has_more] — the coin list is the FIRST
        # element, not the response. Reading the response as the entry list makes every lookup raise
        # and return -1, which `_refill_gas`'s `0 <= balance` gate reads as "nothing to do", so no
        # address is ever refilled and nothing is logged. Payload recorded from sui 1.76.0.
        payload = [
            [
                {
                    "metadata": {"decimals": 9, "symbol": "SUI"},
                    "balance": {"balance": "2557200000", "addressBalance": "2557200000"},
                    "coins": [],
                }
            ],
            False,
        ]
        with mock.patch.object(localnet, "_client_json", return_value=payload):
            self.assertEqual(localnet.balance(Path("/tmp/cfg"), "0xabc"), 2557200000)

    def test_balance_reports_failure_rather_than_zero(self) -> None:
        # -1 and 0 mean different things to `_refill_gas`: 0 is a genuinely empty address that must
        # be topped up, -1 is "the query failed". An unreadable response must not look empty.
        with mock.patch.object(localnet, "_client_json", return_value={"unexpected": "shape"}):
            self.assertEqual(localnet.balance(Path("/tmp/cfg"), "0xabc"), -1)
        with mock.patch.object(localnet, "_client_json", return_value=[[], False]):
            self.assertEqual(localnet.balance(Path("/tmp/cfg"), "0xabc"), 0)

    def test_chain_id_reads_every_shape_the_cli_emits(self) -> None:
        # The pinned CLI emits a bare string; sui 1.76 emits {"base58", "hex"}. Reading only the
        # older key names raises ValueError, and `wait_for_rpc` did not catch it — so localnet
        # bring-up died on the first successful poll for anyone on a newer CLI.
        for payload, expected in [
            ("4c78adac", "4c78adac"),
            ({"chainIdentifier": "4c78adac"}, "4c78adac"),
            ({"base58": "69WiPg3DAQiwdxfncX6wYQ2siKwAe6L9BZthQea3JNMD", "hex": "4c78adac"}, "4c78adac"),
        ]:
            with mock.patch.object(localnet, "_client_json", return_value=payload):
                self.assertEqual(localnet.chain_id(Path("/tmp/cfg")), expected)

    def test_wait_for_rpc_treats_an_unreadable_identifier_as_not_ready(self) -> None:
        # A shape nobody anticipated must degrade to a bring-up timeout, not an unhandled crash out
        # of the poll loop.
        with mock.patch.object(localnet, "_client_json", return_value={"nothing": "recognisable"}):
            with self.assertRaises(TimeoutError):
                localnet.wait_for_rpc(Path("/tmp/cfg"), 9000, timeout=0.2)


class LifecycleTests(unittest.TestCase):
    @staticmethod
    def _valid_hub_metrics() -> dict:
        return {
            "schema_version": 1,
            "elapsed_ms": 1,
            "snapshots": 1,
            "source": {
                "provider_profile": "test",
                "provider_network": "testnet",
                "provider_pkg_ver": 1,
                "verifier_package_id": "0x1",
                "signer_registry_id": "0x2",
                "authenticated": True,
                "acknowledged_subscriptions": 1,
                "pending_acknowledgements": 0,
                "verified_value_batches": 1,
                "verified_svi_batches": 1,
                "invalid_batches": 0,
                "unknown_sids": 0,
                "retired_sid_updates": 0,
                "pre_ack_updates": 0,
                "fatal": None,
            },
        }

    def _run_campaign_case(
        self,
        root: Path,
        *,
        case_name: str,
        strategy: str,
        strategy_metadata: dict,
        timeout: int = 0,
        trader_exit_code: int | None = None,
        trace_lines: dict[str, str] | None = None,
        retain_metrics: bool,
        support_exit_code: int | None = None,
        support_poll_values: list[int | None] | None = None,
        time_values: list[float | BaseException] | None = None,
        fail_manifest_write_at: int | None = None,
        cleanup_failure: OSError | None = None,
        expect_interrupt: bool = False,
        teardown_interrupt: bool = False,
    ) -> dict:
        instance = root / f"{case_name}-instance"
        instance.mkdir()
        for actor, lines in (trace_lines or {}).items():
            trace = instance / "trace"
            trace.mkdir(exist_ok=True)
            (trace / f"{actor}.jsonl").write_text(lines)
        context = {
            "run_id": f"{strategy}-test",
            "instance_dir": instance,
            "client_config": root / "client.yaml",
            "faucet_port": 9123,
            "rpc_port": 9000,
            "active": "0xactive",
            "updater_address": "0xupdater",
            "deployment": {
                "meta": {"chain_id": "local-chain", "rpc_port": 9000},
                "packages": {"predict": "0xpackage"},
                "objects": {"pool": "0xpool"},
            },
        }
        def setup(_strategies, _stack, _concurrency, on_ready=None):
            if on_ready is not None:
                on_ready(strategy, context, 1.0)
            return {strategy: context}

        processes = []
        for pid, returncode in (
            (1001, support_exit_code),
            (1002, None),
            (1003, None),
            (1004, trader_exit_code),
        ):
            process = mock.Mock(pid=pid, returncode=returncode)
            process.poll.return_value = returncode
            processes.append(process)
        if support_poll_values is not None:
            processes[0].poll.side_effect = support_poll_values
        campaigns = root / f"{case_name}-campaigns"
        campaign_dir = campaigns / "campaign-test"
        stopped = []
        teardown_interrupted = False

        def terminate(process, *_args):
            nonlocal teardown_interrupted
            stopped.append(process)
            if retain_metrics:
                (campaign_dir / "hub-metrics.json").write_text(
                    json.dumps(self._valid_hub_metrics())
                )
            if teardown_interrupt and not teardown_interrupted:
                teardown_interrupted = True
                raise KeyboardInterrupt

        writes = 0

        def write(path, manifest):
            nonlocal writes
            writes += 1
            if writes == fail_manifest_write_at:
                raise OSError("manifest disk full")
            run_manifest.write_manifest(path, manifest)

        metadata = {
            "strategies": {strategy: strategy_metadata},
            "cadences": [],
        }
        with contextlib.ExitStack() as patches:
            patches.enter_context(
                mock.patch.object(live.config, "CAMPAIGNS_DIR", campaigns)
            )
            patches.enter_context(
                mock.patch.object(live, "_read_meta", return_value=metadata)
            )
            patches.enter_context(
                mock.patch.object(
                    live,
                    "make_run_id",
                    return_value="campaign-test",
                )
            )
            patches.enter_context(
                mock.patch.object(
                    live,
                    "_setup_campaign_localnets",
                    side_effect=setup,
                )
            )
            patches.enter_context(
                mock.patch.object(
                    live,
                    "create_funded_address",
                    return_value="0xtrader",
                )
            )
            popen = patches.enter_context(
                mock.patch.object(
                    live.subprocess,
                    "Popen",
                    side_effect=processes,
                )
            )
            patches.enter_context(
                mock.patch.object(
                    live.cancellation,
                    "stop_process_group",
                    side_effect=terminate,
                )
            )
            patches.enter_context(
                mock.patch.object(
                    run_manifest,
                    "source_revision",
                    return_value={"commit": "abc123", "dirty": False},
                )
            )
            if time_values is not None:
                patches.enter_context(
                    mock.patch.object(
                        live.time,
                        "time",
                        side_effect=time_values,
                    )
                )
            if fail_manifest_write_at is not None:
                patches.enter_context(
                    mock.patch.object(
                        live,
                        "write_manifest",
                        side_effect=write,
                    )
                )
            if cleanup_failure is not None:
                patches.enter_context(
                    mock.patch.object(
                        live.shutil,
                        "rmtree",
                        side_effect=cleanup_failure,
                    )
                )
            analyze_campaign = patches.enter_context(
                mock.patch.object(
                    analyze,
                    "analyze_manifest",
                    return_value=0,
                )
            )
            if expect_interrupt:
                with self.assertRaises(KeyboardInterrupt):
                    live.campaign([strategy], timeout=timeout, concurrency=1)
                result = 130
            else:
                result = live.campaign(
                    [strategy],
                    timeout=timeout,
                    concurrency=1,
                )

        return {
            "result": result,
            "manifest": json.loads((campaign_dir / "manifest.json").read_text()),
            "campaign_dir": campaign_dir,
            "processes": processes,
            "stopped": stopped,
            "popen": popen,
            "analyze": analyze_campaign,
        }

    def test_local_signer_bootstrap_is_captured_from_stdout(self) -> None:
        completed = subprocess.CompletedProcess(
            ["npx", "tsx", "devtools/ts/localPythCli.ts"],
            0,
            stdout='{"guardianPrivateKey":"secret"}\n',
            stderr="",
        )
        with mock.patch.object(
            oracle_setup.cancellation,
            "run",
            return_value=completed,
        ) as run:
            generated = oracle_setup.generate_local_pyth()

        self.assertEqual(generated, {"guardianPrivateKey": "secret"})
        self.assertEqual(
            run.call_args.args[0],
            ["npx", "tsx", "devtools/ts/localPythCli.ts"],
        )

    def test_runtime_environment_is_private_and_deployment_stays_public(self) -> None:
        packages = {
            name: f"0x-{name}"
            for name in (
                "predict",
                "account",
                "fixed_math",
                "block_scholes_oracle",
                "propbook",
                "usdc",
                "wormhole",
                "pyth_lazer",
            )
        }
        objects = {
            name: f"0x-{name}"
            for name in (
                "registry",
                "admin_cap",
                "protocol_config",
                "pool_vault",
                "account_registry",
                "account_admin_cap",
                "bs_signer_registry",
                "bs_admin_cap",
                "oracle_registry",
                "oracle_registry_admin_cap",
                "usdc_currency",
                "treasury_cap",
                "wormhole_state",
                "pyth_lazer_state",
            )
        }
        local_signers = {
            "bsSignerPrivateKey": "bs-secret",
            "bsSignerPublicKey": "bs-public",
            "governanceChain": 1,
            "governanceContract": "governance",
            "receiverChain": 2,
            "guardianPrivateKey": "guardian-secret",
            "signerPrivateKey": "pyth-secret",
            "signerPublicKey": "pyth-public",
            "signerExpiresAtSeconds": 3,
        }
        deployment = {"packages": packages, "objects": objects}

        with tempfile.TemporaryDirectory() as raw_tmp:
            instance = Path(raw_tmp)
            (instance / "localnet").mkdir()
            oracle_setup.write_env_localnet(
                instance,
                deployment,
                local_signers,
                9000,
                "0x-active",
            )
            env_path = instance / ".env.localnet"

            self.assertEqual(env_path.stat().st_mode & 0o777, 0o600)
            self.assertIn("LOCAL_BS_SIGNER_PRIVATE_KEY=bs-secret", env_path.read_text())
            self.assertNotIn("local_pyth", deployment)

    def test_cleanup_instances_keeps_active_slot_and_removes_orphan(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            instances = Path(raw_tmp)
            active = instances / "active-run"
            orphan = instances / "orphan-run"
            active.mkdir()
            orphan.mkdir()

            with (
                mock.patch.object(cli.config, "INSTANCES_DIR", instances),
                mock.patch.object(cli.state, "reap_stale", return_value=[]),
                mock.patch.object(
                    cli.state,
                    "snapshot",
                    return_value={"slots": {"active-run": {"pid": 1234}}},
                ),
            ):
                result = cli._cmd_cleanup(mock.Mock(instances=True))

            self.assertEqual(result, 0)
            self.assertTrue(active.exists())
            self.assertFalse(orphan.exists())

    def test_parity_tasks_require_explicit_source(self) -> None:
        for command in ("parity", "benchmark"):
            with self.subTest(command=command), self.assertRaises(SystemExit) as raised:
                cli.main([command])
            self.assertEqual(raised.exception.code, 2)

    def test_refill_gas_uses_floor_above_keeper_budget(self) -> None:
        client_config = Path("client.yaml")
        balance = live.KEEPER_GAS_BUDGET
        with (
            mock.patch.object(live.localnet, "balance", return_value=balance),
            mock.patch.object(live.localnet, "fund") as fund,
        ):
            observed = live._refill_gas(client_config, 9123, "0xabc")

        self.assertGreater(live.GAS_REFILL_FLOOR, live.KEEPER_GAS_BUDGET)
        self.assertEqual(observed, balance)
        fund.assert_called_once_with(9123, "0xabc", times=1)

    def test_refill_gas_stops_at_shared_floor(self) -> None:
        client_config = Path("client.yaml")
        with (
            mock.patch.object(
                live.localnet,
                "balance",
                return_value=live.GAS_REFILL_FLOOR,
            ),
            mock.patch.object(live.localnet, "fund") as fund,
        ):
            observed = live._refill_gas(client_config, 9123, "0xabc")

        self.assertIsNone(observed)
        fund.assert_not_called()

    def test_initialized_localnet_unregisters_process_on_teardown(self) -> None:
        process = mock.Mock(pid=1234)

        def publish_localnet(run_id, _slot, instance_dir, _cancel_event=None):
            instance_dir.mkdir(parents=True)
            session._register_localnet(run_id, process)
            return {
                "run_id": run_id,
                "instance_dir": instance_dir,
                "process": process,
                "client_config": instance_dir / "client.yaml",
                "deployment": {
                    "meta": {
                        "chain_id": "local-chain",
                        "rpc_port": 9000,
                    },
                    "packages": {"predict": "0x123"},
                },
                "rpc_port": 9000,
                "faucet_port": 9123,
                "active": "0xabc",
            }

        with tempfile.TemporaryDirectory() as raw_tmp:
            with (
                mock.patch.object(session.config, "INSTANCES_DIR", Path(raw_tmp)),
                mock.patch.object(session, "make_run_id", return_value="session-test"),
                mock.patch.object(
                    session.state,
                    "reserve",
                    return_value={"offset": 0, "rpc_port": 9000, "faucet_port": 9123},
                ),
                mock.patch.object(
                    session,
                    "_start_published_localnet",
                    side_effect=publish_localnet,
                ),
                mock.patch.object(session.oracle_setup, "initialize"),
                mock.patch.object(session.localnet, "stop") as stop,
                mock.patch.object(session.state, "release") as release,
            ):
                with session.initialized_localnet("session", keep=True):
                    self.assertIn("session-test", session._ACTIVE_LOCALNETS)

        self.assertNotIn("session-test", session._ACTIVE_LOCALNETS)
        stop.assert_called_once_with(process)
        release.assert_called_once_with("session-test")

    def test_published_localnet_scrubs_runtime_secrets_when_retaining_evidence(self) -> None:
        process = mock.Mock(pid=1234)
        with tempfile.TemporaryDirectory() as raw_tmp:
            instance = Path(raw_tmp) / "session-test"
            context = {
                "run_id": "session-test",
                "instance_dir": instance,
                "process": process,
                "deployment": {"packages": {}},
            }
            with (
                mock.patch.object(session.config, "INSTANCES_DIR", Path(raw_tmp)),
                mock.patch.object(session, "make_run_id", return_value="session-test"),
                mock.patch.object(
                    session.state,
                    "reserve",
                    return_value={"offset": 0, "rpc_port": 9000, "faucet_port": 9123},
                ),
                mock.patch.object(
                    session,
                    "_start_published_localnet",
                    return_value=context,
                ),
                mock.patch.object(session.localnet, "stop"),
                mock.patch.object(session.state, "release"),
            ):
                with session.published_localnet("session", keep=True) as active:
                    instance.mkdir(parents=True)
                    (active["instance_dir"] / ".env.localnet").write_text("SECRET=x\n")

            self.assertTrue(instance.exists())
            self.assertFalse((instance / ".env.localnet").exists())

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
                ["cleanup-survivor"],
                timeout=0,
                strat_meta={
                    "cleanup-survivor": {
                        "maxOps": 0,
                        "requiresTimeout": False,
                    }
                },
                capacity=1,
            )
        )

    def test_campaign_rejects_unknown_and_duplicate_strategies(self) -> None:
        metadata = {"mint-only": {"maxOps": 10}}

        self.assertEqual(
            live._campaign_validation_error(
                ["missing"],
                timeout=10,
                strat_meta=metadata,
                capacity=1,
            ),
            "unknown strategies: missing",
        )
        self.assertEqual(
            live._campaign_validation_error(
                ["mint-only", "mint-only"],
                timeout=10,
                strat_meta=metadata,
                capacity=2,
            ),
            "duplicate strategies require ambiguous instance ownership: mint-only",
        )

    def test_campaign_rejects_more_localnets_than_capacity(self) -> None:
        error = live._campaign_validation_error(
            ["a", "b"],
            timeout=10,
            strat_meta={"a": {"maxOps": 1}, "b": {"maxOps": 1}},
            capacity=1,
        )

        self.assertIn("above the configured capacity 1", error)

    def test_strategy_metadata_is_environment_free_and_carries_capacity_budget(self) -> None:
        with mock.patch.dict(os.environ, {"INSTANCE_DIR": ""}, clear=False):
            metadata = live._read_meta()

        self.assertEqual(
            metadata["strategies"]["capacity-single"]["gasBudget"],
            50_000_000_000,
        )
        self.assertLess(
            metadata["strategies"]["capacity-single"]["gasBudget"],
            live.GAS_REFILL_FLOOR,
        )
        self.assertEqual(
            metadata["cadences"],
            [
                {"id": 0, "windowSize": 3, "periodMs": 60_000},
                {"id": 1, "windowSize": 3, "periodMs": 300_000},
                {"id": 2, "windowSize": 3, "periodMs": 3_600_000},
            ],
        )
        self.assertEqual(
            live._grid_spec(metadata),
            "60000:3,300000:3,3600000:3",
        )

    def test_campaign_timeout_fails_semantically_incomplete_strategy(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            case = self._run_campaign_case(
                Path(raw_tmp),
                case_name="incomplete",
                strategy="cleanup-survivor",
                strategy_metadata={
                    "maxOps": 0,
                    "requiresTimeout": False,
                    "fund": "1",
                    "gasBudget": 50_000_000_000,
                },
                timeout=1,
                retain_metrics=True,
                time_values=[0.0, 0.0, 2.0, 3.0],
            )

            manifest = case["manifest"]
            report = manifest["outcome"]
            self.assertEqual(case["result"], 1)
            self.assertEqual(manifest["status"], "failed")
            self.assertEqual(manifest["termination"]["reason"], "incomplete")
            self.assertEqual(report["strategies"][0]["result"], "incomplete")
            self.assertFalse((case["campaign_dir"] / "runtime").exists())
            self.assertEqual(manifest["localnets"][0]["role"], "cleanup-survivor")
            self.assertEqual(
                case["popen"].call_args_list[1].kwargs["env"]["SIM_GAS_BUDGET"],
                str(live.KEEPER_GAS_BUDGET),
            )
            self.assertEqual(
                case["popen"].call_args_list[3].kwargs["env"]["SIM_GAS_BUDGET"],
                "50000000000",
            )

    def test_campaign_timeout_fails_duration_strategy_without_progress(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            case = self._run_campaign_case(
                Path(raw_tmp),
                case_name="no-progress",
                strategy="fuzz",
                strategy_metadata={
                    "maxOps": 0,
                    "requiresTimeout": True,
                    "fund": "1",
                    "gasBudget": 2_000_000_000,
                },
                timeout=1,
                trace_lines={
                    "keeper": (
                        '{"schema":1,"type":"settle","market":"0x1",'
                        '"expiryMs":10,"ts":1}\n'
                    ),
                    "trader": (
                        '{"schema":1,"type":"fail","strategy":"fuzz",'
                        '"tag":"RPC timeout","ts":2}\n'
                    ),
                },
                retain_metrics=True,
                time_values=[0.0, 0.0, 2.0, 3.0],
            )

            manifest = case["manifest"]
            report = manifest["outcome"]
            self.assertEqual(case["result"], 1)
            self.assertEqual(manifest["status"], "failed")
            self.assertEqual(manifest["termination"]["reason"], "no_progress")
            self.assertEqual(report["strategies"][0]["result"], "no_progress")

    def test_campaign_timeout_accepts_duration_strategy_with_progress(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            case = self._run_campaign_case(
                Path(raw_tmp),
                case_name="bounded-stop",
                strategy="fuzz",
                strategy_metadata={
                    "maxOps": 0,
                    "requiresTimeout": True,
                    "fund": "1",
                    "gasBudget": 2_000_000_000,
                },
                timeout=1,
                trace_lines={
                    "trader": (
                        '{"schema":1,"type":"supply","strategy":"fuzz",'
                        '"amount":1,"gas":10,"ts":2}\n'
                    ),
                },
                retain_metrics=True,
                time_values=[0.0, 0.0, 2.0, 3.0],
            )

            manifest = case["manifest"]
            self.assertEqual(case["result"], 0)
            self.assertEqual(manifest["status"], "complete")
            self.assertEqual(manifest["termination"]["reason"], "timeout")
            self.assertEqual(
                manifest["outcome"]["strategies"][0]["result"],
                "bounded_stop",
            )

    def test_campaign_interrupt_finalizes_manifest_and_propagates(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            case = self._run_campaign_case(
                Path(raw_tmp),
                case_name="interrupted",
                strategy="fuzz",
                strategy_metadata={
                    "maxOps": 0,
                    "requiresTimeout": True,
                    "fund": "1",
                    "gasBudget": 2_000_000_000,
                },
                timeout=10,
                retain_metrics=True,
                time_values=[0.0, 0.0, KeyboardInterrupt(), 3.0],
                expect_interrupt=True,
            )

            manifest = case["manifest"]
            self.assertEqual(manifest["status"], "interrupted")
            self.assertEqual(
                manifest["termination"],
                {
                    "reason": "interrupted",
                    "error": "KeyboardInterrupt",
                    "exit_code": 130,
                },
            )

    def test_campaign_interrupt_during_timeout_teardown_finalizes_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            case = self._run_campaign_case(
                Path(raw_tmp),
                case_name="teardown-interrupted",
                strategy="fuzz",
                strategy_metadata={
                    "maxOps": 0,
                    "requiresTimeout": True,
                    "fund": "1",
                    "gasBudget": 2_000_000_000,
                },
                timeout=1,
                trace_lines={
                    "trader": (
                        '{"schema":1,"type":"supply","strategy":"fuzz",'
                        '"amount":1,"gas":10,"ts":2}\n'
                    ),
                },
                retain_metrics=True,
                time_values=[0.0, 0.0, 2.0, 3.0],
                expect_interrupt=True,
                teardown_interrupt=True,
            )

            manifest = case["manifest"]
            self.assertEqual(manifest["status"], "interrupted")
            self.assertEqual(manifest["termination"]["exit_code"], 130)
            self.assertEqual(
                manifest["outcome"]["strategies"][0],
                {
                    "strategy": "fuzz",
                    "trader_exit_code_before_teardown": None,
                    "progressed": True,
                    "result": "bounded_stop",
                },
            )

    def test_campaign_fails_when_support_exits_with_last_trader(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            case = self._run_campaign_case(
                Path(raw_tmp),
                case_name="support-race",
                strategy="mint-only",
                strategy_metadata={
                    "maxOps": 1,
                    "requiresTimeout": False,
                    "fund": "1",
                    "gasBudget": 2_000_000_000,
                },
                trader_exit_code=0,
                support_poll_values=[None, 9],
                retain_metrics=True,
            )

            manifest = case["manifest"]
            self.assertEqual(case["result"], 1)
            self.assertEqual(manifest["status"], "failed")
            self.assertEqual(
                manifest["termination"]["reason"],
                "support_failure",
            )
            self.assertEqual(
                manifest["outcome"]["support_exit_codes_before_teardown"]["hub"],
                9,
            )

    def test_hub_metrics_require_current_schema_and_positive_evidence(self) -> None:
        valid = self._valid_hub_metrics()
        self.assertEqual(live._validate_hub_metrics(valid), valid)
        with self.assertRaisesRegex(ValueError, "snapshots must be a positive"):
            live._validate_hub_metrics({**valid, "snapshots": 0})
        with self.assertRaisesRegex(ValueError, "unknown=unexpected"):
            live._validate_hub_metrics({**valid, "unexpected": True})
        with self.assertRaisesRegex(ValueError, "must be authenticated"):
            live._validate_hub_metrics(
                {
                    **valid,
                    "source": {**valid["source"], "authenticated": False},
                }
            )
        with self.assertRaisesRegex(ValueError, "invalid provider batches"):
            live._validate_hub_metrics(
                {
                    **valid,
                    "source": {**valid["source"], "invalid_batches": 7},
                }
            )
        with self.assertRaisesRegex(ValueError, "source failed: registry paused"):
            live._validate_hub_metrics(
                {
                    **valid,
                    "source": {**valid["source"], "fatal": "registry paused"},
                }
            )

    def test_campaign_manifest_completes_only_after_metrics_and_analysis(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            strategy_metadata = {
                "maxOps": 1,
                "requiresTimeout": False,
                "fund": "1",
                "gasBudget": 2_000_000_000,
            }
            missing = self._run_campaign_case(
                root,
                case_name="missing-metrics",
                strategy="mint-only",
                strategy_metadata=strategy_metadata,
                trader_exit_code=0,
                retain_metrics=False,
            )

            manifest = missing["manifest"]
            self.assertEqual(missing["result"], 1)
            self.assertEqual(manifest["status"], "failed")
            self.assertEqual(
                manifest["termination"]["reason"],
                "evidence_failure",
            )
            self.assertIn(
                "FileNotFoundError",
                manifest["outcome"]["hub_metrics_error"],
            )
            self.assertFalse((missing["campaign_dir"] / "runtime").exists())

            successful = self._run_campaign_case(
                root,
                case_name="successful",
                strategy="mint-only",
                strategy_metadata=strategy_metadata,
                trader_exit_code=0,
                retain_metrics=True,
            )

            successful_manifest = successful["manifest"]
            self.assertEqual(successful["result"], 0)
            self.assertEqual(successful_manifest["status"], "complete")
            self.assertEqual(
                successful_manifest["termination"],
                {
                    "reason": "completed",
                    "error": None,
                    "exit_code": 0,
                },
            )
            self.assertEqual(
                successful_manifest["outcome"]["analysis_exit_code"],
                0,
            )
            self.assertFalse((successful["campaign_dir"] / "runtime").exists())
            successful["analyze"].assert_called_once_with(
                successful["campaign_dir"] / "manifest.json",
                require_terminal=False,
            )

    def test_campaign_runtime_cleanup_failure_fails_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            case = self._run_campaign_case(
                Path(raw_tmp),
                case_name="cleanup-failure",
                strategy="mint-only",
                strategy_metadata={
                    "maxOps": 1,
                    "requiresTimeout": False,
                    "fund": "1",
                    "gasBudget": 2_000_000_000,
                },
                trader_exit_code=0,
                retain_metrics=True,
                cleanup_failure=OSError("runtime directory is busy"),
            )

            self.assertEqual(case["result"], 1)
            self.assertEqual(case["manifest"]["status"], "failed")
            self.assertEqual(
                case["manifest"]["termination"]["reason"],
                "cleanup_failure",
            )
            self.assertIn(
                "runtime directory is busy",
                case["manifest"]["outcome"]["runtime_cleanup_error"],
            )

    def test_campaign_manifest_write_failure_stops_started_actor(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            case = self._run_campaign_case(
                Path(raw_tmp),
                case_name="write-failure",
                strategy="mint-only",
                strategy_metadata={
                    "maxOps": 1,
                    "requiresTimeout": False,
                    "fund": "1",
                    "gasBudget": 2_000_000_000,
                },
                trader_exit_code=0,
                retain_metrics=False,
                fail_manifest_write_at=3,
            )

            manifest = case["manifest"]
            self.assertEqual(case["result"], 1)
            self.assertEqual(
                case["stopped"],
                [case["processes"][1], case["processes"][0]],
            )
            self.assertEqual(manifest["status"], "failed")
            self.assertEqual(
                manifest["termination"]["reason"],
                "setup_failure",
            )
            self.assertIn(
                "manifest disk full",
                manifest["termination"]["error"],
            )
            self.assertEqual(
                manifest["localnets"][0]["actors"],
                ["keeper"],
            )

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
                side_effect=lambda name, keep, cancel_event=None: Manager(name),
            ),
            mock.patch.object(live, "as_completed", side_effect=interrupt_after_workers),
            mock.patch.object(live, "stop_active_localnets"),
        ):
            with self.assertRaises(KeyboardInterrupt):
                live._setup_campaign_localnets(["a", "b"], stack, 2)

        self.assertCountEqual(exits, ["a", "b"])

    def test_campaign_setup_reports_each_localnet_when_ready(self) -> None:
        ready: list[tuple[str, str]] = []

        class Manager:
            def __init__(self, name: str):
                self.name = name

            def __enter__(self):
                return {
                    "run_id": f"{self.name}-run",
                    "instance_dir": Path(self.name),
                    "rpc_port": 9000,
                    "deployment": {
                        "meta": {"chain_id": self.name},
                        "packages": {},
                        "objects": {},
                    },
                }

            def __exit__(self, *_args):
                return None

        with (
            contextlib.ExitStack() as stack,
            mock.patch.object(
                live,
                "oracle_ready_localnet",
                side_effect=lambda name, keep, cancel_event=None: Manager(name),
            ),
        ):
            contexts = live._setup_campaign_localnets(
                ["a", "b"],
                stack,
                2,
                lambda strategy, context, _row: ready.append(
                    (strategy, context["run_id"])
                ),
            )

        self.assertEqual(set(contexts), {"a", "b"})
        self.assertCountEqual(ready, [("a", "a-run"), ("b", "b-run")])

    def test_campaign_interrupt_cancels_blocked_setup_worker(self) -> None:
        started = threading.Event()
        observed_cancel: list[threading.Event] = []

        class BlockedManager:
            def __init__(self, cancel_event: threading.Event):
                self.cancel_event = cancel_event

            def __enter__(self):
                started.set()
                self.cancel_event.wait(timeout=5)
                raise cancellation.RunCancelled("run cancelled")

            def __exit__(self, *_args):
                raise AssertionError("a context that never entered must not be closed")

        def manager(*, name, keep, cancel_event):
            self.assertEqual(name, "blocked")
            self.assertTrue(keep)
            observed_cancel.append(cancel_event)
            return BlockedManager(cancel_event)

        def interrupt_while_worker_blocked(_futures):
            self.assertTrue(started.wait(timeout=5))
            raise KeyboardInterrupt
            yield  # pragma: no cover - makes this a generator for the for-loop

        with (
            contextlib.ExitStack() as stack,
            mock.patch.object(
                live,
                "oracle_ready_localnet",
                side_effect=manager,
            ),
            mock.patch.object(
                live,
                "as_completed",
                side_effect=interrupt_while_worker_blocked,
            ),
            mock.patch.object(live, "stop_active_localnets") as stop,
        ):
            with self.assertRaises(KeyboardInterrupt):
                live._setup_campaign_localnets(["blocked"], stack, 1)

        self.assertEqual(len(observed_cancel), 1)
        self.assertTrue(observed_cancel[0].is_set())
        stop.assert_called_once_with()

    def test_cancellable_setup_command_kills_group_after_leader_exits(self) -> None:
        cancel_event = threading.Event()
        failures: list[BaseException] = []
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            leader_pid_path = root / "leader-pid"
            child_pid_path = root / "child-pid"
            child_script = (
                "import os, signal, sys, time\n"
                "from pathlib import Path\n"
                "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                "Path(sys.argv[1]).write_text(str(os.getpid()))\n"
                "time.sleep(30)\n"
            )
            leader_script = (
                "import os, subprocess, sys\n"
                "from pathlib import Path\n"
                "Path(sys.argv[1]).write_text(str(os.getpid()))\n"
                "subprocess.Popen([sys.executable, '-c', sys.argv[3], sys.argv[2]])\n"
            )

            def run_blocked_command() -> None:
                try:
                    cancellation.run(
                        [
                            sys.executable,
                            "-c",
                            leader_script,
                            str(leader_pid_path),
                            str(child_pid_path),
                            child_script,
                        ],
                        cancel_event=cancel_event,
                        check_result=True,
                        capture_output=True,
                        text=True,
                    )
                except BaseException as exc:
                    failures.append(exc)

            worker = threading.Thread(target=run_blocked_command)
            worker.start()
            deadline = time.time() + 5
            while (
                not leader_pid_path.exists() or not child_pid_path.exists()
            ) and time.time() < deadline:
                time.sleep(0.01)
            self.assertTrue(leader_pid_path.exists())
            self.assertTrue(child_pid_path.exists())
            leader_pid = int(leader_pid_path.read_text())
            child_pid = int(child_pid_path.read_text())

            cancel_event.set()
            worker.join(timeout=5)

            self.assertFalse(worker.is_alive())
            self.assertEqual(len(failures), 1)
            self.assertIsInstance(failures[0], cancellation.RunCancelled)
            for pid in (leader_pid, child_pid):
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    continue
                stat_path = Path("/proc") / str(pid) / "stat"
                if not Path("/proc").is_dir():
                    self.fail(f"setup process {pid} still exists after cancellation")
                try:
                    state = stat_path.read_text().split(") ", 1)[1][0]
                except (FileNotFoundError, ProcessLookupError):
                    # The pid passed `kill(pid, 0)` a moment ago but was reaped before the read.
                    # Linux raises ProcessLookupError (ESRCH) rather than FileNotFoundError for a
                    # vanished /proc entry, so catching only the latter makes this flake on CI.
                    continue
                # Linux containers may leave the orphaned grandchild as an
                # unreaped zombie briefly. A zombie is dead and holds no pipes.
                self.assertEqual(
                    state,
                    "Z",
                    f"setup process {pid} is still running with state {state}",
                )

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
                mock.patch.object(session.localnet, "genesis") as genesis,
                mock.patch.object(session.localnet, "stop") as stop,
            ):
                with self.assertRaisesRegex(RuntimeError, "staging failed"):
                    session._start_published_localnet(
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
                    session.localnet,
                    "genesis",
                    return_value=Path(tmp) / "client.yaml",
                ),
                mock.patch.object(session.localnet, "start", return_value=process),
                mock.patch.object(
                    session.localnet,
                    "wait_for_rpc",
                    side_effect=KeyboardInterrupt,
                ),
                mock.patch.object(session.localnet, "stop") as stop,
                mock.patch.object(session.state, "update"),
                mock.patch.object(session.os, "getpgid", return_value=1234),
            ):
                with self.assertRaises(KeyboardInterrupt):
                    session._start_published_localnet(
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
                    session.localnet,
                    "genesis",
                    return_value=Path(tmp) / "client.yaml",
                ),
                mock.patch.object(session.localnet, "start", side_effect=start),
                mock.patch.object(session.localnet, "stop") as stop,
                mock.patch.object(session.state, "update"),
                mock.patch.object(session.os, "getpgid", return_value=1234),
            ):
                with self.assertRaisesRegex(cancellation.RunCancelled, "run cancelled"):
                    session._start_published_localnet(
                        "test-run",
                        {"rpc_port": 9000, "faucet_port": 9123, "offset": 0},
                        Path(tmp),
                        cancel_event,
                    )

            stop.assert_called_once_with(process)

    def test_published_localnet_stops_process_when_cancellation_wins_return_race(self) -> None:
        process = mock.Mock(pid=1234)
        cancel_event = threading.Event()

        def publish_localnet(run_id, slot, inst, event):
            session._register_localnet(run_id, process)
            event.set()
            return {
                "run_id": run_id,
                "instance_dir": inst,
                "process": process,
                "deployment": {"packages": {}},
            }

        with (
            tempfile.TemporaryDirectory() as raw_tmp,
            mock.patch.object(session.config, "INSTANCES_DIR", Path(raw_tmp)),
            mock.patch.object(session, "make_run_id", return_value="test-run"),
            mock.patch.object(
                session.state,
                "reserve",
                return_value={"rpc_port": 9000, "faucet_port": 9123, "offset": 0},
            ),
            mock.patch.object(
                session,
                "_start_published_localnet",
                side_effect=publish_localnet,
            ),
            mock.patch.object(session.localnet, "stop") as stop,
            mock.patch.object(session.state, "release") as release,
        ):
            with self.assertRaisesRegex(cancellation.RunCancelled, "run cancelled"):
                with session.published_localnet(
                    "test",
                    keep=False,
                    cancel_event=cancel_event,
                ):
                    self.fail("cancelled localnet must not yield")

        stop.assert_called_once_with(process)
        release.assert_called_once_with("test-run")
        self.assertNotIn("test-run", session._ACTIVE_LOCALNETS)

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

        with mock.patch.object(cli.session, "stop_active_localnets") as stop:
            result = cli._run_with_sigterm_handler(interrupt)

        self.assertEqual(result, 130)
        stop.assert_called_once_with()


if __name__ == "__main__":
    unittest.main()
