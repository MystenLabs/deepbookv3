#!/usr/bin/env python3
"""Verify Predict's published dependency sources without signing or broadcasting.

Run after building sessions. Modern packages use Sui's source verifier; historical
packages use a reproduction compiler or lossless serialization of compiled modules.
Every path requires exact equality with the published module bytes.
Compiler input roots are disposable copies. Client configuration is only passed
to the selected CLI; this script never opens configuration or keystore files.
"""

import argparse
from dataclasses import dataclass
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import tomllib


CHAINS = {"mainnet": "35834a8a", "testnet": "4c78adac"}
NEW_PACKAGES = {
    "fixed_math", "account", "propbook", "deepbook_predict",
    "deepbook_core_account", "deepbook_sessions",
}
NEW_PATHS = {
    "fixed_math": "packages/fixed_math", "account": "packages/account",
    "propbook": "packages/propbook", "deepbook_predict": "packages/predict",
    "deepbook_core_account": "packages/deepbook_core_account",
    "deepbook_sessions": "packages/sessions",
}
SYSTEM = {"MoveStdlib": "0x1", "Sui": "0x2"}


class VerificationError(RuntimeError):
    pass


def run(arguments, *, binary=False):
    timeout = 60 if "client" in arguments and "verify-source" not in arguments else 120
    try:
        result = subprocess.run(arguments, capture_output=True, check=False, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        raise VerificationError(
            f"command timed out after {timeout}s: {' '.join(map(str, arguments))}"
        ) from error
    if result.returncode:
        raise VerificationError(
            f"command failed ({result.returncode}): {' '.join(map(str, arguments))}\n"
            + result.stderr.decode(errors="replace")
            + result.stdout.decode(errors="replace")
        )
    return result.stdout if binary else result.stdout.decode().strip()


def read_toml(path):
    with path.open("rb") as stream:
        return tomllib.load(stream)


def address(value):
    if not isinstance(value, str) or not re.fullmatch(r"0x[0-9a-fA-F]{1,64}", value):
        raise VerificationError(f"invalid package address: {value!r}")
    if int(value, 16) == 0:
        raise VerificationError("unpublished zero package address")
    return "0x" + value[2:].lower().zfill(64)


@dataclass(frozen=True)
class Publication:
    original: str
    latest: str
    version: int


def publication(directory, network):
    modern, legacy = directory / "Published.toml", directory / "Move.lock"
    entry = read_toml(modern).get("published", {}).get(network) if modern.exists() else None
    if entry is not None:
        fields = ("original-id", "published-at", "version")
    else:
        entry = read_toml(legacy).get("env", {}).get(network) if legacy.exists() else None
        fields = ("original-published-id", "latest-published-id", "published-version")
    if entry is not None:
        if entry.get("chain-id") != CHAINS[network]:
            raise VerificationError(f"{directory.name}: publication chain mismatch")
        result = Publication(address(entry[fields[0]]), address(entry[fields[1]]), int(entry[fields[2]]))
    else:
        manifest = read_toml(directory / "Move.toml")
        name = manifest["package"]["name"]
        latest = address(manifest["package"].get("published-at"))
        own_addresses = {
            address(value) for alias, value in manifest.get("addresses", {}).items()
            if alias.lower() == name.lower()
        }
        if own_addresses != {latest}:
            raise VerificationError(f"{name}: no unambiguous original publication record")
        # An original package is version 1. Upgrades require explicit records.
        result = Publication(latest, latest, 1)
    if result.version < 1:
        raise VerificationError(f"{directory.name}: invalid publication version")
    return result


def git_manifest(repository, rev, path):
    visited = set()
    while path not in visited:
        visited.add(path)
        entry = run(["git", "-C", str(repository), "ls-tree", rev, "--", path])
        if not entry:
            raise VerificationError(f"missing locked source manifest: {path}")
        content = run(["git", "-C", str(repository), "show", f"{rev}:{path}"])
        if entry.split()[0] != "120000":
            return tomllib.loads(content)
        if Path(content).is_absolute():
            raise VerificationError(f"absolute source manifest link: {path}")
        path = os.path.normpath(str(Path(path).parent / content))
        if path == ".." or path.startswith("../"):
            raise VerificationError("source manifest link escapes Git tree")
    raise VerificationError(f"cyclic source manifest link: {path}")


def stage_git(source, destination, cache):
    """Export the package and its relative dependencies from the locked commit."""
    rev, url = source["rev"], source["git"]
    if not re.fullmatch(r"[0-9a-f]{40}", rev):
        raise VerificationError(f"Git source is not an exact revision: {rev}")
    subdir = Path(source["subdir"])
    if subdir.is_absolute() or ".." in subdir.parts:
        raise VerificationError(f"invalid Git subdirectory: {subdir}")
    cache_name = re.sub(r"[^a-zA-Z0-9_-]", "_", url) + "_" + rev
    repository = cache / "git" / cache_name
    if not repository.exists():
        repository = cache / cache_name
    if not repository.exists():
        repository = destination / ".source.git"
        run(["git", "init", "--bare", str(repository)])
        run(["git", "-C", str(repository), "fetch", "--depth=1", url, rev])
    resolved = run(["git", "-C", str(repository), "rev-parse", f"{rev}^{{commit}}"])
    if resolved != rev:
        raise VerificationError("source revision did not resolve exactly")
    pending, subtrees = [str(subdir)], set()
    while pending:
        subtree = pending.pop()
        if subtree in subtrees:
            continue
        subtrees.add(subtree)
        manifest = git_manifest(repository, rev, f"{subtree}/Move.toml")
        tables = [manifest]
        while tables:
            table = tables.pop()
            for value in table.values():
                if not isinstance(value, dict):
                    continue
                tables.append(value)
                if "local" not in value:
                    continue
                relative = value["local"]
                if not isinstance(relative, str) or Path(relative).is_absolute():
                    raise VerificationError(f"invalid relative source dependency: {relative}")
                dependency = os.path.normpath(str(Path(subtree) / relative))
                if dependency == ".." or dependency.startswith("../"):
                    raise VerificationError(f"relative dependency escapes Git source: {relative}")
                pending.append(dependency)
    archive = run(["git", "-C", str(repository), "archive", rev, "--", *sorted(subtrees)], binary=True)
    with tarfile.open(fileobj=io.BytesIO(archive)) as bundle:
        for member in bundle.getmembers():
            target = (destination / member.name).resolve()
            if not target.is_relative_to(destination.resolve()) or member.islnk():
                raise VerificationError(f"unsafe source archive member: {member.name}")
            if member.issym():
                linked = (target.parent / member.linkname).resolve()
                if not linked.is_relative_to(destination.resolve()):
                    raise VerificationError(f"source archive link escapes stage: {member.name}")
        bundle.extractall(destination, filter="data")
    package = destination / subdir
    if not (package / "Move.toml").is_file():
        raise VerificationError(f"locked package missing: {subdir}")
    return package


def stage_local(repo, destination):
    for name in ("packages", "vendor"):
        if (repo / name).exists():
            shutil.copytree(repo / name, destination / name,
                            ignore=shutil.ignore_patterns("build", "target", "node_modules", ".git"))


def modules(directory):
    result = {path.stem: path.read_bytes() for path in directory.glob("*.mv")}
    if not result or any(not value for value in result.values()):
        raise VerificationError(f"missing or empty compiled modules: {directory}")
    return result


def compare_modules(name, compiled, onchain):
    if not compiled or not onchain:
        raise VerificationError(f"{name}: empty module map")
    missing, extra = set(onchain) - set(compiled), set(compiled) - set(onchain)
    changed = sorted(key for key in compiled.keys() & onchain.keys() if compiled[key] != onchain[key])
    if missing or extra or changed:
        raise VerificationError(
            f"{name}: bytecode mismatch; missing={sorted(missing)}, extra={sorted(extra)}, changed={changed}"
        )


def uleb(data, position):
    result = 0
    for shift in range(0, 35, 7):
        byte = data[position]
        position += 1
        result |= (byte & 127) << shift
        if byte < 128:
            return result, position
    raise VerificationError("invalid Move bytecode integer")


def module_address(data):
    """Read the self module handle from serialized Move bytecode, without rewriting it."""
    try:
        if data[:4] != bytes.fromhex("a11ceb0b"):
            raise VerificationError("invalid Move bytecode magic")
        count, position = uleb(data, 8)
        tables = {}
        for _ in range(count):
            kind = data[position]
            offset, position = uleb(data, position + 1)
            size, position = uleb(data, position)
            tables[kind] = (offset, size)
        end = position + max(offset + size for offset, size in tables.values())
        self_handle, _ = uleb(data, end)
        handle = position + tables[1][0]
        for _ in range(self_handle):
            _, handle = uleb(data, handle)
            _, handle = uleb(data, handle)
        index, _ = uleb(data, handle)
        start = position + tables[8][0] + index * 32
        if index * 32 + 32 > tables[8][1]:
            raise VerificationError("Move address index out of range")
        return address("0x" + data[start:start + 32].hex())
    except (IndexError, KeyError, ValueError) as error:
        raise VerificationError("malformed Move module identity") from error


def package_object(payload, record):
    data = payload.get("data", payload)
    if address(data.get("objectId", data.get("object_id"))) != record.latest:
        raise VerificationError("on-chain package ID mismatch")
    if record.version < 1 or int(data.get("version", 0)) != record.version:
        raise VerificationError("on-chain package version mismatch")
    content = data.get("content", {})
    package = content.get("Package", content.get("package", content))
    raw = package.get("module_map", package.get("moduleMap"))
    if not isinstance(raw, dict) or not raw:
        raise VerificationError("object has no serialized package modules")
    if any(not isinstance(value, list) or not value or
           any(type(byte) is not int or not 0 <= byte <= 255 for byte in value)
           for value in raw.values()):
        raise VerificationError("invalid serialized module bytes")
    result = {name: bytes(value) for name, value in raw.items()}
    if {module_address(value) for value in result.values()} != {record.original}:
        raise VerificationError("on-chain original package identity mismatch")
    linkage = package.get("linkage_table", package.get("linkageTable"))
    if not isinstance(linkage, dict):
        raise VerificationError("missing on-chain linkage table")
    return result, linkage


def compare_linkage(name, linkage, expected):
    system = {address(value) for value in SYSTEM.values()}
    actual = {}
    for original, info in linkage.items():
        original = address(original)
        latest = address(info.get("upgraded_id", info.get("upgradedId")))
        version = int(info.get("upgraded_version", info.get("upgradedVersion", 0)))
        if version < 1:
            raise VerificationError(f"{name}: invalid linked version")
        if original in system:
            if latest != original:
                raise VerificationError(f"{name}: framework identity mismatch")
            # Historical framework versions are valid linkage entries.
            continue
        actual[original] = (latest, version)
    wanted = {record.original: (record.latest, record.version) for record in expected}
    if actual != wanted:
        raise VerificationError(f"{name}: linkage mismatch: expected {wanted}, received {actual}")


def client_command(sui, config, network, *arguments):
    return [str(sui), "client", "--client.config", str(config), "--client.env", network, *arguments]


def validate_target(sui, config, network, legacy=None):
    if Path(config).name != "client.yaml":
        raise VerificationError(
            "--client-config must be named client.yaml: Sui source verification passes "
            "its parent directory to the compiler; copy the intended client configuration "
            "to an isolated directory as client.yaml and pass that path"
        )
    version = run([str(sui), "--version"])
    if not re.fullmatch(r"sui 1\.78\.1(?:-[A-Za-z0-9.-]+)?", version):
        raise VerificationError(f"expected Sui 1.78.1, received {version}")
    chain = run(client_command(sui, config, network, "chain-identifier", "--format", "hex"))
    if chain != CHAINS[network]:
        raise VerificationError(f"{network}: wrong chain {chain}")
    if legacy:
        version = run([str(legacy), "--version"])
        if version != "sui 1.32.2-a5eab1a75fa8":
            raise VerificationError(f"expected historical Sui 1.32.2-a5eab1a75fa8, received {version}")


def closure(lock, key):
    found = set()
    pending = list(lock[key].get("deps", {}).values())
    while pending:
        current = pending.pop()
        if current not in lock:
            raise VerificationError(f"unresolved dependency: {current}")
        if current not in found:
            found.add(current)
            pending.extend(lock[current].get("deps", {}).values())
    if key in found:
        raise VerificationError(f"dependency cycle: {key}")
    return found


def bind_legacy_addresses(packages, records):
    for key in packages:
        manifest = packages[key] / "Move.toml"
        lines = manifest.read_text().splitlines(keepends=True)
        section, replacements = "", 0
        for index, line in enumerate(lines):
            if line.strip().startswith("["):
                section = line.strip()
            if section == "[addresses]" and re.match(rf"\s*{key}\s*=", line):
                lines[index] = f'{key} = "{records[key].original}"\n'
                replacements += 1
        if replacements != 1:
            raise VerificationError(f"{key}: expected one publication address")
        manifest.write_text("".join(lines))


def verify_modern(sui, config, network, directory, record):
    result = json.loads(run(client_command(
        sui, config, network, "verify-source", str(directory),
        "--build-env", network, "--toolchain", str(sui), "--json")))
    if address(result.get("originalId")) != record.original or address(result.get("publishedAt")) != record.latest:
        raise VerificationError(f"{directory.name}: source verifier publication mismatch")


def stage_deepbook_token(directory, lock, packages, names, network="mainnet"):
    """Carry the resolved token override into the disposable DeepBook root."""
    candidates = {
        packages[key].resolve() for key in packages
        if names[key] == "token" and "local" in lock[key]["source"]
    }
    if len(candidates) != 1:
        raise VerificationError("DeepBook verification requires one resolved local token source")
    token = candidates.pop()
    manifest = directory / "Move.toml"
    text = manifest.read_text()
    parsed = tomllib.loads(text)
    if network in parsed.get("dep-replacements", {}):
        raise VerificationError(f"staged DeepBook already has {network} replacements; reconcile the locked token source")
    manifest.write_text(
        text.rstrip() + f"\n\n[dep-replacements.{network}]\n"
        + f"token = {{ local = {json.dumps(str(token))}, override = true }}\n"
    )


def resolve_token_override(lock, packages, names, records, staged_repo, network="mainnet"):
    """Resolve the explicit source override, checking identities before shadowing."""
    sessions = staged_repo / "packages/sessions"
    override = read_toml(sessions / "Move.toml").get("dep-replacements", {}).get(network, {}).get("token", {})
    relative = override.get("local")
    if override.get("override") is not True or not isinstance(relative, str) or Path(relative).is_absolute():
        raise VerificationError(f"{network} token requires an explicit local Sessions override")
    selected_path = (sessions / relative).resolve()
    if not selected_path.is_relative_to(staged_repo.resolve()):
        raise VerificationError("token override escapes staged repository")
    token_keys = {key for key in packages if names[key] == "token"}
    selected = [key for key in token_keys if "local" in lock[key]["source"]
                and (sessions / lock[key]["source"]["local"]).resolve() == selected_path
                and packages[key].resolve() == selected_path]
    if len(selected) != 1:
        raise VerificationError("token override must select exactly one resolved local token")
    key = selected[0]
    manifest = read_toml(selected_path / "Move.toml")
    if manifest["package"]["name"] != "token":
        raise VerificationError("token override package name mismatch")
    if key not in records or publication(selected_path, network) != records[key]:
        raise VerificationError("token override publication identity mismatch")
    named_address = manifest.get("addresses", {}).get("token")
    if named_address != "0x0" and address(named_address) != records[key].original:
        raise VerificationError("token override original identity mismatch")
    shadowed = token_keys - {key}
    for other in shadowed:
        if "git" not in lock[other]["source"]:
            raise VerificationError("ambiguous local token sources")
        if other not in records or records[other] != records[key]:
            raise VerificationError(f"shadowed token publication identity mismatch: {other}")
    # A shadowed source is excluded only after matching the explicitly selected
    # original ID, latest ID, and version. Consumers link to the selected record.
    resolved = {
        name: {**entry, "deps": {alias: key if target in shadowed else target
                                 for alias, target in entry.get("deps", {}).items()}}
        for name, entry in lock.items()
    }
    return resolved, shadowed, key


def build_legacy_token(legacy, directory, network="mainnet"):
    bind_legacy_addresses({"token": directory}, {"token": publication(directory, network)})
    run([str(legacy), "move", "build", "--path", str(directory), "--skip-fetch-latest-git-deps"])
    return modules(directory / "build/token/bytecode_modules")


def build_bytecode_verifier(repo):
    manifest = repo / "packages/predict/deployment/bytecode/Cargo.toml"
    run(["cargo", "build", "--locked", "--manifest-path", str(manifest),
         "--target-dir", str(manifest.parent / "target")])
    return manifest.parent / "target/debug/predict-dependency-bytecode"


def verify_historical_serialization(binary, compiled, published):
    payload = json.dumps({"compiled": {name: list(value) for name, value in compiled.items()},
                          "published": {name: list(value) for name, value in published.items()}})
    try:
        result = subprocess.run([str(binary)], input=payload, text=True, capture_output=True, timeout=30)
    except subprocess.TimeoutExpired as error:
        raise VerificationError("historical bytecode verification timed out after 30s") from error
    if result.returncode:
        raise VerificationError(f"historical bytecode verification failed: {result.stderr}")


def verify(repo, network, sui, config, legacy=None, reuse_testnet_usdc=False):
    if reuse_testnet_usdc and network != "testnet":
        raise VerificationError("--reuse-testnet-usdc requires Testnet")
    if legacy is None:
        raise VerificationError("verification requires --legacy-sui or SUI_LEGACY_BINARY")
    validate_target(sui, config, network, legacy)
    lock = read_toml(repo / "packages/sessions/Move.lock").get("pinned", {}).get(network)
    if not lock or "deepbook_sessions" not in lock:
        raise VerificationError("build sessions first: missing target dependency lock")
    reachable = closure(lock, "deepbook_sessions")
    cache = Path(os.environ.get("MOVE_HOME", str(Path.home() / ".move")))
    with tempfile.TemporaryDirectory(prefix="predict-verify-") as temp:
        temporary = Path(temp)
        local = temporary / "local"
        stage_local(repo, local)
        packages, names, records, source_stages = {}, {}, {}, {}
        for key in sorted(reachable):
            source = lock[key]["source"]
            if "local" in source:
                canonical = (repo / "packages/sessions" / source["local"]).resolve()
                if not canonical.is_relative_to(repo.resolve()):
                    raise VerificationError(f"local dependency escapes repository: {key}")
                package = local / canonical.relative_to(repo.resolve())
            elif "git" in source:
                identity = (source["git"], source["rev"], str(Path(source["subdir"]).parent))
                if identity not in source_stages:
                    destination = temporary / f"git-{len(source_stages)}"
                    destination.mkdir()
                    source_stages[identity] = destination
                package = source_stages[identity] / source["subdir"]
                if not (package / "Move.toml").is_file():
                    stage_git(source, source_stages[identity], cache)
            else:
                raise VerificationError(f"unknown dependency source: {key}")
            name = read_toml(package / "Move.toml")["package"]["name"]
            packages[key], names[key] = package, name
            if name in NEW_PACKAGES:
                if "local" not in source or package != local / NEW_PATHS[name]:
                    raise VerificationError(f"unexpected source for publication root: {name}")
                continue
            if network == "testnet" and not reuse_testnet_usdc and name == "usdc" and package == local / "packages/usdc":
                continue
            if name not in SYSTEM:
                records[key] = publication(package, network)

        lock, shadowed, token_key = resolve_token_override(lock, packages, names, records, local, network)
        for key in shadowed:
            del records[key]

        # These framework bytes come from the canonical, just-built closure.
        artifacts = repo / "packages/sessions/build/deepbook_sessions/bytecode_modules/dependencies"
        for name, package_id in SYSTEM.items():
            payload = json.loads(run(client_command(sui, config, network, "object", package_id, "--json")))
            data = payload.get("data", payload)
            record = Publication(address(package_id), address(package_id), int(data.get("version", 0)))
            live, _ = package_object(payload, record)
            compare_modules(name, modules(artifacts / name), live)
            print(f"verified {name}: {len(live)} modules at {package_id}", flush=True)

        legacy_modules = {token_key: build_legacy_token(legacy, packages[token_key], network)}
        bytecode_verifier = build_bytecode_verifier(repo) if network == "testnet" else None
        if network == "mainnet":
            circle = {name: next(key for key in records if names[key] == name)
                      for name in ("usdc", "stablecoin", "sui_extensions")}
            bind_legacy_addresses({name: packages[key] for name, key in circle.items()},
                                  {name: records[key] for name, key in circle.items()})
            usdc = packages[circle["usdc"]]
            run([str(legacy), "move", "build", "--path", str(usdc), "--skip-fetch-latest-git-deps"])
            output = usdc / "build/usdc/bytecode_modules"
            legacy_modules[circle["usdc"]] = modules(output)
            for name in ("stablecoin", "sui_extensions"):
                legacy_modules[circle[name]] = modules(output / "dependencies" / name)
            for key in records:
                if names[key] == "Wormhole":
                    run([str(legacy), "move", "build", "--path", str(packages[key]), "--skip-fetch-latest-git-deps"])
                    legacy_modules[key] = modules(packages[key] / "build/Wormhole/bytecode_modules")

        seen = {}
        for key, record in records.items():
            name = names[key]
            if record.latest in seen and seen[record.latest] != record:
                raise VerificationError(f"conflicting publication identity: {name}")
            payload = json.loads(run(client_command(sui, config, network, "object", record.latest, "--json")))
            live, linkage = package_object(payload, record)
            expected = [records[dependency] for dependency in closure(lock, key) if dependency in records]
            compare_linkage(name, linkage, expected)
            if key in legacy_modules:
                compare_modules(name, legacy_modules[key], live)
            elif network == "testnet" and name in {"pyth_lazer", "wormhole"}:
                run([str(sui), "move", "--client.config", str(config), "build", "--path", str(packages[key]),
                     "--build-env", network, "--force"])
                compiled = modules(packages[key] / "build" / name / "bytecode_modules")
                verify_historical_serialization(bytecode_verifier, compiled, live)
            else:
                if name == "deepbook" and "git" in lock[key]["source"]:
                    stage_deepbook_token(packages[key], lock, packages, names, network)
                verify_modern(sui, config, network, packages[key], record)
            seen[record.latest] = record
            print(f"verified {name}: {len(live)} modules, version {record.version}, {record.latest}", flush=True)
        print(f"verified {len(seen)} published external packages and both framework packages", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--network", required=True, choices=CHAINS)
    parser.add_argument("--sui", required=True, type=Path)
    parser.add_argument("--client-config", required=True, type=Path)
    parser.add_argument("--legacy-sui", type=Path, default=os.environ.get("SUI_LEGACY_BINARY"))
    parser.add_argument("--reuse-testnet-usdc", action="store_true")
    args = parser.parse_args()
    for binary in (args.sui, args.legacy_sui):
        if binary and (not binary.is_absolute() or not binary.is_file()):
            parser.error(f"Sui binary must be an existing absolute path: {binary}")
    try:
        verify(args.repo.resolve(), args.network, args.sui, args.client_config, args.legacy_sui, args.reuse_testnet_usdc)
    except (VerificationError, OSError, ValueError, KeyError, StopIteration) as error:
        print(f"dependency verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
