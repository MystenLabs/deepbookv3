"""Deterministic tests; no network, keystore, or Move compiler is used."""

import copy
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import verify_dependencies as verifier


ORIGINAL = "0x" + "00" * 31 + "03"
LATEST = "0x" + "00" * 31 + "04"
RECORD = verifier.Publication(ORIGINAL, LATEST, 2)
# Hand-encoded Move header: module handle table [address 0, name 0], address
# table containing 0x3, followed by self module handle 0. No compiler fixture.
MODULE = bytes.fromhex("a11ceb0b06000000020100020802200000" + "00" * 31 + "03" + "00")


def object_fixture():
    return {"data": {"objectId": LATEST, "version": "2", "content": {"Package": {
        "module_map": {"example": list(MODULE)}, "linkage_table": {},
    }}}}


class DependencyVerificationTests(unittest.TestCase):
    def test_testnet_deepbook_pin_preserves_mainnet_selection(self):
        root = Path(__file__).resolve().parents[3]
        for package in ("deepbook_core_account", "sessions"):
            manifest = verifier.read_toml(root / "packages" / package / "Move.toml")
            replacements = manifest["dep-replacements"]
            for network, revision in (
                ("testnet", "ce0e5cd052d7d1eb195bb486396730c550f8f92a"),
                ("mainnet", "2f83e49f21c3aaf96b779f24be0fd6951bc75b29"),
            ):
                self.assertEqual(replacements[network]["deepbook"], {
                    "git": "https://github.com/MystenLabs/deepbookv3.git",
                    "subdir": "packages/deepbook", "rev": revision,
                })
            self.assertEqual(replacements["testnet"]["token"], {"local": "../../vendor/deep", "override": True})
            self.assertEqual(replacements["mainnet"]["token"], {"local": "../../vendor/deep", "override": True})

    def test_reused_testnet_usdc_is_verified_instead_of_skipped(self):
        lock = {"deepbook_sessions": {"source": {"local": "."}, "deps": {"usdc": "usdc"}},
                "usdc": {"source": {"local": "../usdc"}, "deps": {}}}
        def read(path):
            if path.name == "Move.lock":
                return {"pinned": {"testnet": lock}}
            return {"package": {"name": "deepbook_sessions" if path.parent.name == "sessions" else "usdc"}}
        with patch.object(verifier, "validate_target"), patch.object(verifier, "read_toml", side_effect=read), \
                patch.object(verifier, "stage_local"), \
                patch.object(verifier, "publication", side_effect=verifier.VerificationError("USDC publication checked")) as check:
            with self.assertRaisesRegex(verifier.VerificationError, "USDC publication checked"):
                verifier.verify(Path("/unused"), "testnet", "sui", "config", legacy="legacy", reuse_testnet_usdc=True)
            self.assertEqual(check.call_args.args[0].name, "usdc")
            self.assertEqual(check.call_args.args[1], "testnet")
        with self.assertRaisesRegex(verifier.VerificationError, "requires Testnet"):
            verifier.verify(Path("/unused"), "mainnet", "sui", "config", reuse_testnet_usdc=True)

    def test_exact_modules_and_reject_all_mismatch_classes(self):
        self.assertIsNone(verifier.compare_modules("sample", {"a": b"123"}, {"a": b"123"}))
        for candidate in ({}, {"a": b"124"}, {"b": b"123"}, {"a": b"123", "b": b"x"}):
            with self.subTest(candidate=candidate), self.assertRaises(verifier.VerificationError):
                verifier.compare_modules("sample", candidate, {"a": b"123"})

    def test_serialized_identity_and_package_object(self):
        self.assertEqual(verifier.module_address(MODULE), ORIGINAL)
        self.assertEqual(verifier.package_object(object_fixture(), RECORD), ({"example": MODULE}, {}))
        for record in (
            verifier.Publication(ORIGINAL, ORIGINAL, 2),
            verifier.Publication(ORIGINAL, LATEST, 3),
            verifier.Publication(LATEST, LATEST, 2),
        ):
            with self.subTest(record=record), self.assertRaises(verifier.VerificationError):
                verifier.package_object(object_fixture(), record)

    def test_reject_absent_empty_or_malformed_package_data(self):
        for value in ({}, {"a": []}, {"a": [256]}, {"a": [True]}, {"a": "YWJj"}, {"a": [1]}):
            payload = object_fixture()
            payload["data"]["content"]["Package"]["module_map"] = value
            with self.subTest(value=value), self.assertRaises(verifier.VerificationError):
                verifier.package_object(payload, RECORD)
        payload = object_fixture()
        del payload["data"]["content"]["Package"]["linkage_table"]
        with self.assertRaisesRegex(verifier.VerificationError, "linkage"):
            verifier.package_object(payload, RECORD)

    def test_linkage_exact_identity_version_and_historical_framework(self):
        linkage = {ORIGINAL: {"upgraded_id": LATEST, "upgraded_version": 2},
                   "0x2": {"upgraded_id": "0x2", "upgraded_version": 3}}
        self.assertIsNone(verifier.compare_linkage("sample", linkage, [RECORD]))
        for field, value in (("upgraded_id", ORIGINAL), ("upgraded_version", 1)):
            candidate = copy.deepcopy(linkage)
            candidate[ORIGINAL][field] = value
            with self.subTest(field=field), self.assertRaisesRegex(verifier.VerificationError, "linkage"):
                verifier.compare_linkage("sample", candidate, [RECORD])
        with self.assertRaises(verifier.VerificationError):
            verifier.compare_linkage("sample", {}, [RECORD])
        with self.assertRaises(verifier.VerificationError):
            verifier.compare_linkage("sample", linkage, [])

    def test_modern_verification_targets_selected_environment_and_ids(self):
        response = json.dumps({"originalId": ORIGINAL, "publishedAt": LATEST})
        with patch.object(verifier, "run", return_value=response) as command:
            self.assertIsNone(verifier.verify_modern("/bin/sui", "/tmp/config", "mainnet", Path("/tmp/source"), RECORD))
            command.assert_called_once_with([
                "/bin/sui", "client", "--client.config", "/tmp/config", "--client.env", "mainnet",
                "verify-source", "/tmp/source", "--build-env", "mainnet", "--toolchain", "/bin/sui", "--json",
            ])
        with patch.object(verifier, "run", return_value=json.dumps({"originalId": ORIGINAL, "publishedAt": ORIGINAL})):
            with self.assertRaisesRegex(verifier.VerificationError, "publication"):
                verifier.verify_modern("sui", "config", "mainnet", Path("source"), RECORD)

    def test_wrong_chain_and_toolchain_fail_before_verification(self):
        for outputs in (("sui 1.77.1",), ("sui 1.78.1", "4c78adac"),
                        ("sui 1.78.1", "35834a8a", "sui 1.32.2-unknown")):
            with self.subTest(outputs=outputs), patch.object(verifier, "run", side_effect=outputs):
                with self.assertRaises(verifier.VerificationError):
                    verifier.validate_target("sui", "/tmp/client.yaml", "mainnet", "legacy")

    def test_nonstandard_config_filename_fails_before_any_command(self):
        with patch.object(verifier, "run") as command:
            with self.assertRaisesRegex(verifier.VerificationError, "must be named client.yaml"):
                verifier.validate_target("sui", "/tmp/custom.yaml", "mainnet")
            command.assert_not_called()

    def test_subprocess_timeouts_bound_chain_and_build_commands(self):
        cases = [(["sui", "client", "object", "0x2", "--json"], 60),
                 (["sui", "client", "verify-source", "package"], 120),
                 (["sui", "move", "build", "--path", "package"], 120),
                 (["git", "fetch", "origin", "revision"], 120)]
        for arguments, seconds in cases:
            with self.subTest(arguments=arguments), patch.object(
                verifier.subprocess, "run", side_effect=subprocess.TimeoutExpired(arguments, seconds)
            ) as command:
                with self.assertRaisesRegex(verifier.VerificationError, f"timed out after {seconds}s"):
                    verifier.run(arguments)
                self.assertEqual(command.call_args.kwargs["timeout"], seconds)

    def test_command_failure_propagates_with_diagnostics(self):
        failure = subprocess.CompletedProcess(["sui"], 1, stdout=b"verification failed", stderr=b"compiler error\n")
        with patch.object(verifier.subprocess, "run", return_value=failure):
            with self.assertRaisesRegex(verifier.VerificationError, "compiler error"):
                verifier.run(["sui"])

    def test_staged_local_changes_do_not_mutate_source(self):
        with tempfile.TemporaryDirectory() as temp:
            repo = Path(temp) / "repo"
            package = repo / "packages/token"
            package.mkdir(parents=True)
            (package / "Move.toml").write_text("original")
            (package / "build").mkdir()
            (package / "build/stale.mv").write_bytes(b"stale")
            stage = Path(temp) / "stage"
            verifier.stage_local(repo, stage)
            (stage / "packages/token/Move.toml").write_text("changed")
            self.assertEqual((package / "Move.toml").read_text(), "original")
            self.assertFalse((stage / "packages/token/build").exists())

    def test_git_archive_uses_exact_commit_not_cached_worktree(self):
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w") as archive:
            member = tarfile.TarInfo("packages/token/Move.toml")
            content = b'[package]\nname="token"\n'
            member.size = len(content)
            archive.addfile(member, io.BytesIO(content))
        revision = "a" * 40
        source = {"git": "https://github.com/example/repo-name.git", "rev": revision, "subdir": "packages/token"}
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cache_repo = root / "cache/git" / ("https___github_com_example_repo-name_git_" + revision)
            cache_repo.mkdir(parents=True)
            with patch.object(verifier, "run", side_effect=[revision, "100644 blob hash", content.decode(), buffer.getvalue()]) as command:
                staged = verifier.stage_git(source, root / "stage", root / "cache")
                self.assertEqual((staged / "Move.toml").read_bytes(), content)
                self.assertEqual(command.call_args_list[3].args[0],
                                 ["git", "-C", str(cache_repo), "archive", revision, "--", "packages/token"])
                self.assertFalse((cache_repo / "packages").exists())

    def test_failed_verification_removes_disposable_stage(self):
        captured = []
        lock = {"pinned": {"testnet": {"deepbook_sessions": {"deps": {"bad": "bad"}},
                                       "bad": {"source": {"unknown": True}}}}}
        with patch.object(verifier, "validate_target"), patch.object(verifier, "read_toml", return_value=lock), \
                patch.object(verifier, "stage_local", side_effect=lambda repo, dest: captured.append(dest.parent)):
            with self.assertRaisesRegex(verifier.VerificationError, "unknown dependency source"):
                verifier.verify(Path("/unused"), "testnet", "sui", "config", legacy="legacy")
        self.assertEqual(len(captured), 1)
        self.assertFalse(captured[0].exists())

    def test_unrelated_sibling_symlink_is_not_exported(self):
        revision = "b" * 40
        manifest = '[package]\nname="Wormhole"\n'

        def git_command(arguments, *, binary=False):
            if "rev-parse" in arguments:
                return revision
            if "show" in arguments:
                return manifest
            if "ls-tree" in arguments:
                return "100644 blob hash"
            self.assertIn("archive", arguments)
            exported = arguments[arguments.index("--") + 1:]
            buffer = io.BytesIO()
            with tarfile.open(fileobj=buffer, mode="w") as archive:
                member = tarfile.TarInfo("sui/wormhole/Move.toml")
                member.size = len(manifest)
                archive.addfile(member, io.BytesIO(manifest.encode()))
                if "sui" in exported:
                    sibling = tarfile.TarInfo("sui/token_bridge/Move.toml")
                    sibling.type = tarfile.SYMTYPE
                    sibling.linkname = "Move.mainnet.toml"
                    archive.addfile(sibling)
            return buffer.getvalue()

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cache = root / "cache"
            (cache / "git" / ("https___github_com_example_wormhole_git_" + revision)).mkdir(parents=True)
            source = {"git": "https://github.com/example/wormhole.git", "rev": revision, "subdir": "sui/wormhole"}
            with patch.object(verifier, "run", side_effect=git_command):
                result = verifier.stage_git(source, root / "stage", cache)
            self.assertEqual((result / "Move.toml").read_text(), manifest)
            self.assertFalse((root / "stage/sui/token_bridge").exists())

    def test_manifest_links_follow_exact_commit_and_reject_escapes(self):
        revision = "b" * 40
        with patch.object(verifier, "run", side_effect=[
            "120000 blob hash", "Move.mainnet.toml", "100644 blob hash", '[package]\nname="Wormhole"\n',
        ]) as command:
            self.assertEqual(verifier.git_manifest(Path("cache"), revision, "sui/wormhole/Move.toml"),
                             {"package": {"name": "Wormhole"}})
            self.assertEqual(command.call_args.args[0],
                             ["git", "-C", "cache", "show", revision + ":sui/wormhole/Move.mainnet.toml"])
        with patch.object(verifier, "run", side_effect=["120000 blob hash", "../../../outside"]):
            with self.assertRaisesRegex(verifier.VerificationError, "escapes"):
                verifier.git_manifest(Path("cache"), revision, "sui/wormhole/Move.toml")

    def test_publication_rejects_wrong_chain_and_zero_identity(self):
        with tempfile.TemporaryDirectory() as temp:
            package = Path(temp)
            record = '[published.mainnet]\nchain-id="4c78adac"\noriginal-id="0x3"\npublished-at="0x4"\nversion=2\n'
            (package / "Published.toml").write_text(record)
            with self.assertRaisesRegex(verifier.VerificationError, "chain"):
                verifier.publication(package, "mainnet")
            (package / "Published.toml").write_text(record.replace("4c78adac", "35834a8a").replace('"0x3"', '"0x0"'))
            with self.assertRaisesRegex(verifier.VerificationError, "zero"):
                verifier.publication(package, "mainnet")

    def test_deepbook_stage_uses_locked_local_token_without_changing_canonical_source(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            canonical = root / "canonical/deepbook"
            staged = root / "stage/deepbook"
            token = root / "stage/packages/token"
            for directory in (canonical, staged, token):
                directory.mkdir(parents=True)
            source = ('[package]\nname="deepbook"\n'
                      '[dependencies.token]\ngit="https://github.com/example/token.git"\nrev="main"\n')
            (canonical / "Move.toml").write_text(source)
            (staged / "Move.toml").write_text(source)
            lock = {"token": {"source": {"git": "https://github.com/example/token.git", "rev": "main"}},
                    "token_1": {"source": {"local": "../token"}}}
            packages = {"token": root / "stage/git-token", "token_1": token}
            verifier.stage_deepbook_token(staged, lock, packages, {"token": "token", "token_1": "token"})
            self.assertEqual((canonical / "Move.toml").read_text(), source)
            self.assertEqual((staged / "Move.toml").read_text(), source.rstrip() +
                             '\n\n[dep-replacements.mainnet]\ntoken = { local = ' +
                             json.dumps(str(token.resolve())) + ', override = true }\n')
            self.assertEqual(verifier.read_toml(staged / "Move.toml")["dep-replacements"]["mainnet"],
                             {"token": {"local": str(token.resolve()), "override": True}})

    def test_deepbook_stage_rejects_missing_local_token(self):
        with self.assertRaisesRegex(verifier.VerificationError, "one resolved local token"):
            verifier.stage_deepbook_token(Path("unused"), {}, {}, {})

    def token_override_fixture(self, temporary, network="mainnet"):
        root = Path(temporary)
        sessions = root / "packages/sessions"
        selected = root / "vendor/deep"
        sessions.mkdir(parents=True)
        selected.mkdir(parents=True)
        (sessions / "Move.toml").write_text(
            f'[package]\nname="deepbook_sessions"\n[dep-replacements.{network}]\n'
            'token = { local = "../../vendor/deep", override = true }\n')
        (selected / "Move.toml").write_text('[package]\nname="token"\n[addresses]\ntoken="0x3"\n')
        (selected / "Published.toml").write_text(
            f'[published.{network}]\nchain-id="{verifier.CHAINS[network]}"\noriginal-id="{ORIGINAL}"\npublished-at="{LATEST}"\nversion=2\n')
        lock = {
            "deepbook_sessions": {"deps": {"deepbook": "deepbook", "token": "token_1"}},
            "deepbook": {"deps": {"token": "token"}},
            "token": {"source": {"git": "https://github.com/example/token.git", "rev": "a" * 40}},
            "token_1": {"source": {"local": "../../vendor/deep"}},
        }
        packages = {"token": root / "git/token", "token_1": selected}
        names = {"token": "token", "token_1": "token"}
        records = {"token": RECORD, "token_1": RECORD}
        return root, lock, packages, names, records

    def test_explicit_token_override_redirects_consumers_after_identity_validation(self):
        with tempfile.TemporaryDirectory() as temp:
            root, lock, packages, names, records = self.token_override_fixture(temp)
            resolved, shadowed, selected = verifier.resolve_token_override(lock, packages, names, records, root)
            self.assertEqual(shadowed, {"token"})
            self.assertEqual(selected, "token_1")
            self.assertEqual(resolved["deepbook"]["deps"], {"token": "token_1"})
            self.assertEqual(verifier.closure(resolved, "deepbook_sessions"), {"deepbook", "token_1"})
            self.assertEqual(lock["deepbook"]["deps"], {"token": "token"})

    def test_testnet_override_binds_testnet_publication(self):
        with tempfile.TemporaryDirectory() as temp:
            root, lock, packages, names, records = self.token_override_fixture(temp, "testnet")
            resolved, shadowed, selected = verifier.resolve_token_override(lock, packages, names, records, root, "testnet")
            self.assertEqual(shadowed, {"token"})
            self.assertEqual(selected, "token_1")
            self.assertEqual(resolved["deepbook"]["deps"], {"token": "token_1"})
            with self.assertRaises(verifier.VerificationError):
                verifier.resolve_token_override(lock, packages, names, records, root, "mainnet")

    def test_historical_verifier_failure_is_not_accepted(self):
        with patch.object(verifier.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "changed constant")) as run:
            with self.assertRaisesRegex(verifier.VerificationError, "changed constant"):
                verifier.verify_historical_serialization("verifier", {"a": b"123"}, {"a": b"124"})
            self.assertEqual(json.loads(run.call_args.kwargs["input"]), {
                "compiled": {"a": [49, 50, 51]}, "published": {"a": [49, 50, 52]},
            })

    def test_source_stage_excludes_rust_build_outputs(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "source"
            (root / "packages/predict/deployment/bytecode/target").mkdir(parents=True)
            (root / "packages/predict/deployment/bytecode/target/large").write_bytes(b"build output")
            (root / "packages/predict/deployment/bytecode/Cargo.toml").write_text("[package]\n")
            staged = Path(temp) / "staged"
            verifier.stage_local(root, staged)
            self.assertFalse((staged / "packages/predict/deployment/bytecode/target").exists())
            self.assertTrue((staged / "packages/predict/deployment/bytecode/Cargo.toml").exists())

    def test_historical_verifier_timeout_fails_closed(self):
        with patch.object(verifier.subprocess, "run", side_effect=subprocess.TimeoutExpired("verifier", 30)):
            with self.assertRaisesRegex(verifier.VerificationError, "timed out"):
                verifier.verify_historical_serialization("verifier", {"a": b"123"}, {"a": b"123"})

    def test_token_override_rejects_shadowed_publication_identity_changes(self):
        candidates = [verifier.Publication(LATEST, LATEST, 2),
                      verifier.Publication(ORIGINAL, ORIGINAL, 2),
                      verifier.Publication(ORIGINAL, LATEST, 3)]
        for candidate in candidates:
            with self.subTest(candidate=candidate), tempfile.TemporaryDirectory() as temp:
                root, lock, packages, names, records = self.token_override_fixture(temp)
                records["token"] = candidate
                with self.assertRaisesRegex(verifier.VerificationError, "shadowed token publication"):
                    verifier.resolve_token_override(lock, packages, names, records, root)

    def test_token_override_rejects_missing_nonoverride_or_wrong_path(self):
        entries = ['', 'token = { local = "../../vendor/deep" }',
                   'token = { local = "../token", override = true }',
                   'token = { local = "/outside", override = true }',
                   'token = { local = "../../../outside", override = true }']
        for entry in entries:
            with self.subTest(entry=entry), tempfile.TemporaryDirectory() as temp:
                root, lock, packages, names, records = self.token_override_fixture(temp)
                (root / "packages/sessions/Move.toml").write_text('[dep-replacements.mainnet]\n' + entry + '\n')
                with self.assertRaises(verifier.VerificationError):
                    verifier.resolve_token_override(lock, packages, names, records, root)

    def test_token_override_rejects_ambiguous_selection_or_wrong_manifest_identity(self):
        for kind in ("duplicate", "different_local", "name", "address"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temp:
                root, lock, packages, names, records = self.token_override_fixture(temp)
                if kind in ("duplicate", "different_local"):
                    path = "../../vendor/deep" if kind == "duplicate" else "../token"
                    lock["token"]["source"] = {"local": path}
                    if kind == "duplicate":
                        packages["token"] = packages["token_1"]
                else:
                    manifest = '[package]\nname="other"\n[addresses]\ntoken="0x3"\n' if kind == "name" else \
                               '[package]\nname="token"\n[addresses]\ntoken="0x4"\n'
                    (packages["token_1"] / "Move.toml").write_text(manifest)
                with self.assertRaises(verifier.VerificationError):
                    verifier.resolve_token_override(lock, packages, names, records, root)

    def test_selected_token_legacy_build_reads_exact_output_and_propagates_failure(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / "vendor/deep"
            output = source / "build/token/bytecode_modules"
            output.mkdir(parents=True)
            (source / "Move.toml").write_text('[package]\nname="token"\n[addresses]\ntoken="0x0"\n')
            (source / "Published.toml").write_text(
                f'[published.mainnet]\nchain-id="35834a8a"\noriginal-id="{ORIGINAL}"\npublished-at="{LATEST}"\nversion=2\n')
            (output / "deep.mv").write_bytes(MODULE)
            with patch.object(verifier, "run") as command:
                compiled = verifier.build_legacy_token(Path("/tools/legacy-sui"), source)
                self.assertEqual(compiled, {"deep": MODULE})
                command.assert_called_once_with([
                    "/tools/legacy-sui", "move", "build", "--path", str(source), "--skip-fetch-latest-git-deps",
                ])
            with self.assertRaisesRegex(verifier.VerificationError, "bytecode mismatch"):
                verifier.compare_modules("token", compiled, {"deep": MODULE + b"changed"})
            with patch.object(verifier, "run", side_effect=verifier.VerificationError("compiler failed")):
                with self.assertRaisesRegex(verifier.VerificationError, "compiler failed"):
                    verifier.build_legacy_token(Path("/tools/legacy-sui"), source)


if __name__ == "__main__":
    unittest.main()
